//
//  CameraSession.swift
//  BlinkKyc
//
//  The native camera plumbing behind the drop-in capture UI: an AVCaptureSession that produces
//  high-quality stills (for the document step) and a stream of frames (for the liveness step),
//  plus the SwiftUI preview view and the framing overlay. Nothing here reveals how verification works.
//

#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// Owns one `AVCaptureSession` for a single camera position. Produces JPEG stills on demand and keeps
/// the latest video frame available for liveness capture.
final class BlinkCameraSession: NSObject {
    let captureSession = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "net.blink.kyc.camera.session")
    private let videoQueue = DispatchQueue(label: "net.blink.kyc.camera.video")
    private let ciContext = CIContext(options: nil)
    private let stateLock = NSLock()

    private let position: AVCaptureDevice.Position
    private var configured = false
    private var latestBuffer: CVPixelBuffer?
    private var photoContinuation: CheckedContinuation<Data, Error>?

    init(position: AVCaptureDevice.Position) {
        self.position = position
        super.init()
    }

    // MARK: Authorization

    /// Ensure camera access, prompting once if the user hasn't decided yet.
    static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: Lifecycle

    func start() {
        sessionQueue.async {
            self.configureIfNeeded()
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    // MARK: Capture

    /// Capture a single high-quality still (used for the document step).
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            sessionQueue.async {
                self.configureIfNeeded()
                self.stateLock.lock()
                if self.photoContinuation != nil {
                    self.stateLock.unlock()
                    continuation.resume(throwing: BlinkError.client("BLINK_CAMERA_BUSY",
                                                                    "A capture is already in progress"))
                    return
                }
                self.photoContinuation = continuation
                self.stateLock.unlock()

                // Force JPEG so the encoded still matches the multipart part's declared type.
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    /// Encode the most recent video frame as JPEG (used for the liveness step). Nil until frames flow.
    func grabFrameJPEG() -> Data? {
        stateLock.lock()
        let buffer = latestBuffer
        stateLock.unlock()
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return ciContext.jpegRepresentation(of: image,
                                            colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [:])
    }

    // MARK: Configuration

    private func configureIfNeeded() {
        guard !configured else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        if let device = Self.device(for: position),
           let input = try? AVCaptureDeviceInput(device: device),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        // Upright frames; mirror the front camera so the preview and captured frames match.
        for output in [photoOutput as AVCaptureOutput, videoOutput as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if position == .front, connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        configured = true
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}

// MARK: - Photo delegate

extension BlinkCameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        stateLock.lock()
        let continuation = photoContinuation
        photoContinuation = nil
        stateLock.unlock()

        if let error {
            continuation?.resume(throwing: BlinkError.client("BLINK_CAPTURE_FAILED", error.localizedDescription))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation?.resume(throwing: BlinkError.client("BLINK_CAPTURE_FAILED", "Capture produced no image"))
            return
        }
        continuation?.resume(returning: data)
    }
}

// MARK: - Video frame delegate

extension BlinkCameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        stateLock.lock()
        latestBuffer = pixelBuffer
        stateLock.unlock()
    }
}

// MARK: - SwiftUI preview

/// A live camera preview backed by `AVCaptureVideoPreviewLayer`.
struct BlinkCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> BlinkPreviewView {
        let view = BlinkPreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: BlinkPreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

/// A `UIView` whose backing layer is an `AVCaptureVideoPreviewLayer`.
final class BlinkPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Framing overlay

/// A dimmed overlay with a cut-out framing guide the user aligns their document or face to.
struct BlinkGuideOverlay: View {
    enum Kind { case card, circle }

    let kind: Kind
    let accent: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .reverseMask { GuideCutout(kind: kind) }
            GuideCutout(kind: kind)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// The guide shape — a rounded card rectangle or a circle — sized relative to the stage.
private struct GuideCutout: Shape {
    let kind: BlinkGuideOverlay.Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .card:
            let width = rect.width * 0.86
            let height = min(width * 2.0 / 3.0, rect.height * 0.7) // ~ID-1 aspect
            let frame = CGRect(x: (rect.width - width) / 2,
                               y: (rect.height - height) / 2,
                               width: width, height: height)
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: 16, height: 16))
        case .circle:
            let diameter = min(rect.width, rect.height) * 0.72
            let frame = CGRect(x: (rect.width - diameter) / 2,
                               y: (rect.height - diameter) / 2,
                               width: diameter, height: diameter)
            path.addEllipse(in: frame)
        }
        return path
    }
}

private extension View {
    /// Punch a transparent hole through `self` in the shape of `mask`.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
#endif
