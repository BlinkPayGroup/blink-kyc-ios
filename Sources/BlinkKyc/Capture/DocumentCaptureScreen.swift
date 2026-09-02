//
//  DocumentCaptureScreen.swift
//  BlinkKyc
//
//  The document step of the drop-in UI: a framed camera with a capture control, then a
//  retake / confirm review. Resolves with the confirmed image.
//

#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class DocumentCaptureModel: ObservableObject {
    enum Phase: Equatable {
        case granting
        case denied
        case live
        case review(Data)
    }

    @Published var phase: Phase = .granting

    let camera = BlinkCameraSession(position: .back)
    private let onFinish: (Result<Data, Error>) -> Void
    private var finished = false

    init(onFinish: @escaping (Result<Data, Error>) -> Void) {
        self.onFinish = onFinish
    }

    func onAppear() {
        Task {
            let authorized = await BlinkCameraSession.ensureAuthorized()
            if authorized {
                camera.start()
                phase = .live
            } else {
                phase = .denied
            }
        }
    }

    func onDisappear() {
        camera.stop()
    }

    func capture() {
        Task {
            do {
                let data = try await camera.capturePhoto()
                phase = .review(data)
            } catch {
                finish(.failure(error))
            }
        }
    }

    func retake() {
        phase = .live
    }

    func use(_ data: Data) {
        finish(.success(data))
    }

    func cancel() {
        finish(.failure(BlinkError.client("BLINK_CANCELLED", "Verification was cancelled")))
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        camera.stop()
        onFinish(result)
    }
}

struct DocumentCaptureScreen: View {
    let theme: BlinkTheme
    let strings: BlinkStrings
    let documentType: DocumentType?
    let side: DocumentSide?

    @StateObject private var model: DocumentCaptureModel

    init(theme: BlinkTheme,
         strings: BlinkStrings,
         documentType: DocumentType?,
         side: DocumentSide?,
         onFinish: @escaping (Result<Data, Error>) -> Void) {
        self.theme = theme
        self.strings = strings
        self.documentType = documentType
        self.side = side
        _model = StateObject(wrappedValue: DocumentCaptureModel(onFinish: onFinish))
    }

    var body: some View {
        ZStack {
            theme.resolvedBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                header
                stage
                controls
            }
            .padding(20)

            closeButton
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(strings.documentTitle)
                .font(.headline)
                .foregroundColor(theme.resolvedText)
            Text(strings.documentHint)
                .font(.subheadline)
                .foregroundColor(theme.resolvedText.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 28)
    }

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                switch model.phase {
                case .granting:
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: theme.resolvedAccent))
                    Text(strings.granting)
                        .font(.footnote)
                        .foregroundColor(theme.resolvedText.opacity(0.8))
                        .offset(y: 34)
                case .denied:
                    deniedView
                case .live:
                    BlinkCameraPreview(session: model.camera.captureSession)
                    BlinkGuideOverlay(kind: .card, accent: theme.resolvedAccent)
                case .review(let data):
                    if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Text(strings.cameraDenied)
                .font(.subheadline)
                .foregroundColor(theme.resolvedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(strings.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .foregroundColor(theme.resolvedAccent)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .live:
            BlinkPrimaryButton(title: strings.captureButton, theme: theme) { model.capture() }
        case .review(let data):
            HStack(spacing: 12) {
                BlinkGhostButton(title: strings.retake, theme: theme) { model.retake() }
                BlinkPrimaryButton(title: strings.use, theme: theme) { model.use(data) }
            }
        default:
            // Keep the layout height stable while granting / denied.
            Color.clear.frame(height: 52)
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Button(action: { model.cancel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.resolvedText)
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .accessibilityLabel(strings.cancel)
                Spacer()
            }
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Buttons

struct BlinkPrimaryButton: View {
    let title: String
    let theme: BlinkTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundColor(theme.resolvedOnAccent)
                .background(theme.resolvedAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct BlinkGhostButton: View {
    let title: String
    let theme: BlinkTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundColor(theme.resolvedText)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
#endif
