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
import Vision

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

    /// What the frame stream should analyse for the auto-capture UX. A framing aid only — the server
    /// still judges the captured media. Nothing here encodes a verification threshold or model of ours
    /// (face detection is Apple's Vision framework, shipped with iOS).
    enum AnalysisMode { case none, document, face }

    /// Set by the capture screens to receive on-device framing signals on the main queue.
    var analysisMode: AnalysisMode = .none
    /// (documentPresent, tooFar) — a card fills the guide / is visible but small.
    var onDocSignal: ((Bool, Bool) -> Void)?
    /// (faceFits) — a single face is centred and large enough to fill the oval.
    var onFaceSignal: ((Bool) -> Void)?

    private var frameCounter = 0
    private var faceInFlight = false
    private let faceSequence = VNSequenceRequestHandler()

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

        // Throttle analysis to a few frames per second — enough for a responsive lock-on without
        // burning the CPU on every frame.
        frameCounter &+= 1
        switch analysisMode {
        case .none:
            return
        case .document:
            if frameCounter % 6 != 0 { return }
            let (present, tooFar) = Self.documentSignal(from: pixelBuffer)
            DispatchQueue.main.async { [weak self] in self?.onDocSignal?(present, tooFar) }
        case .face:
            if frameCounter % 6 != 0 || faceInFlight { return }
            faceInFlight = true
            detectFace(in: pixelBuffer)
        }
    }

    /// Apple's Vision face detector → does one face fill the oval? Vision ships with iOS; the SDK
    /// bundles no face model of its own.
    private func detectFace(in pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceRectanglesRequest { [weak self] request, _ in
            guard let self else { return }
            self.faceInFlight = false
            let faces = (request.results as? [VNFaceObservation]) ?? []
            var fit = false
            if let face = faces.first {
                // Vision boundingBox is normalised, origin bottom-left. Centre + fill test.
                let box = face.boundingBox
                let cx = box.midX
                let cy = box.midY
                let centred = abs(cx - 0.5) < 0.22 && abs(cy - 0.5) < 0.24
                let bigEnough = box.height > 0.34
                fit = faces.count == 1 && centred && bigEnough
            }
            DispatchQueue.main.async { self.onFaceSignal?(fit) }
        }
        do {
            try faceSequence.perform([request], on: pixelBuffer)
        } catch {
            faceInFlight = false
        }
    }

    /// Edge-density + contrast over a card-shaped ROI of the BGRA frame — the same shape of test the
    /// Web SDK runs. Returns (present, tooFar).
    private static func documentSignal(from pixelBuffer: CVPixelBuffer) -> (Bool, Bool) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return (false, false) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        if width < 16 || height < 16 { return (false, false) }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // BGRA: use the green channel as a cheap luma proxy.
        func lum(_ x: Int, _ y: Int) -> Int {
            let cx = min(max(x, 0), width - 1)
            let cy = min(max(y, 0), height - 1)
            return Int(ptr[cy * bytesPerRow + cx * 4 + 1])
        }

        let roiW = Int(Double(width) * 0.84)
        let roiH = min(Int(Double(roiW) / 1.586), Int(Double(height) * 0.84))
        let left = (width - roiW) / 2
        let top = (height - roiH) / 2
        let cols = 24
        let rows = 16
        let edgeStep = 18
        var interiorSum = 0
        var interiorN = 0
        var edgePx = 0
        for r in 0 ..< rows {
            let py = top + roiH * r / (rows - 1)
            var prev = -1
            for c in 0 ... cols {
                let px = left + roiW * c / cols
                let v = lum(px, py)
                interiorSum += v
                interiorN += 1
                if prev >= 0 && abs(v - prev) >= edgeStep { edgePx += 1 }
                prev = v
            }
        }
        let pad = max(6, roiW / 40)
        var ringSum = 0
        var ringN = 0
        for c in 0 ... cols {
            let px = left + roiW * c / cols
            ringSum += lum(px, top - pad)
            ringSum += lum(px, top + roiH + pad)
            ringN += 2
        }
        let edgeDensity = interiorN > 0 ? Double(edgePx) / Double(interiorN) : 0
        let interiorMean = interiorN > 0 ? Double(interiorSum) / Double(interiorN) : 0
        let ringMean = ringN > 0 ? Double(ringSum) / Double(ringN) : 0
        let contrast = abs(interiorMean - ringMean)
        let present = edgeDensity > 0.012 && contrast > 10
        let tooFar = !present && edgeDensity >= 0.006 && edgeDensity <= 0.012
        return (present, tooFar)
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
    /// Green "locked on" framing while a document/face is detected steady.
    var matched: Bool = false
    /// Auto-capture / fit countdown, 0...1 — drives the ring drawn along the guide.
    var progress: Double = 0

    private var lockGreen: Color { Color(red: 0.13, green: 0.77, blue: 0.37) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .reverseMask { GuideCutout(kind: kind) }
            GuideCutout(kind: kind)
                .stroke(matched ? lockGreen : accent,
                        style: StrokeStyle(lineWidth: matched ? 4 : 3, lineJoin: .round))
            if progress > 0 {
                GuideCutout(kind: kind)
                    .trim(from: 0, to: max(0, min(progress, 1)))
                    .stroke(lockGreen, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
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
