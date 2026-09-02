//
//  LivenessCaptureScreen.swift
//  BlinkKyc
//
//  The liveness step of the drop-in UI: a circular face frame that shows the requested actions one
//  at a time and records a frame for each. Resolves with the recorded frames.
//

#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class LivenessCaptureModel: ObservableObject {
    enum Phase: Equatable {
        case granting
        case denied
        case ready
        case running
        case done
    }

    @Published var phase: Phase = .granting
    @Published var prompt: String = ""
    @Published var actionIndex: Int = 0

    let camera = BlinkCameraSession(position: .front)
    let actions: [String]
    private let onFinish: (Result<[Data], Error>) -> Void
    private var frames: [Data] = []
    private var finished = false

    /// The server may send an empty action list; fall back to a single "look straight" prompt.
    private var effectiveActions: [String] {
        actions.isEmpty ? ["LOOK_STRAIGHT"] : actions
    }

    var actionCount: Int { effectiveActions.count }

    init(actions: [String], onFinish: @escaping (Result<[Data], Error>) -> Void) {
        self.actions = actions
        self.onFinish = onFinish
    }

    func onAppear() {
        Task {
            let authorized = await BlinkCameraSession.ensureAuthorized()
            if authorized {
                camera.start()
                phase = .ready
            } else {
                phase = .denied
            }
        }
    }

    func onDisappear() {
        camera.stop()
    }

    func start() {
        guard phase == .ready else { return }
        phase = .running
        Task { await runSequence() }
    }

    func cancel() {
        finish(.failure(BlinkError.client("BLINK_CANCELLED", "Verification was cancelled")))
    }

    private func runSequence() async {
        let list = effectiveActions

        // 1) Primary frontal frame — a settled "look straight" still, grabbed BEFORE any gesture so
        //    it is sharp and front-facing rather than a mid-motion blur. This is the frame scored for
        //    quality; grab a few candidates and keep the sharpest.
        prompt = Self.humanAction("LOOK_STRAIGHT")
        try? await Task.sleep(nanoseconds: 900_000_000)
        if let frame = await grabSharpest(candidates: 3, gapNanos: 220_000_000) {
            frames.append(frame)
        }

        // 2) A short two-frame burst per requested action supplies the inter-frame motion a live
        //    capture must show. Budget the per-action count so the total stays within the wire limit.
        let perAction = max(1, min(2, (11 - frames.count) / max(list.count, 1)))
        for (index, action) in list.enumerated() {
            if frames.count >= 12 { break }
            actionIndex = index
            prompt = Self.humanAction(action)
            // Give the user a moment to perform the action, then grab a frame.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if let frame = await awaitFrame() {
                frames.append(frame)
            }
            if perAction > 1 && frames.count < 12 {
                try? await Task.sleep(nanoseconds: 420_000_000)
                if let frame = await awaitFrame() {
                    frames.append(frame)
                }
            }
        }

        // 3) Guarantee at least 3 frames with motion even for a degenerate single-action challenge.
        while frames.count < 3 {
            prompt = Self.humanAction("MOVE_CLOSER")
            try? await Task.sleep(nanoseconds: 450_000_000)
            if let frame = await awaitFrame() {
                frames.append(frame)
            } else {
                break
            }
        }

        prompt = "✓"
        phase = .done

        guard !frames.isEmpty else {
            finish(.failure(BlinkError.client("BLINK_CAPTURE_FAILED", "No frames were captured")))
            return
        }
        // Cap to the wire limit (max 12 frames).
        finish(.success(Array(frames.prefix(12))))
    }

    /// Grab several settled frames and keep the sharpest — the primary frame the verifier scores.
    /// Falls back to a single grab if sharpness metrics are unavailable on this platform.
    private func grabSharpest(candidates: Int, gapNanos: UInt64) async -> Data? {
        var best: Data?
        var bestSharp = -Double.greatestFiniteMagnitude
        for i in 0 ..< max(candidates, 1) {
            guard let frame = await awaitFrame() else { continue }
            let sharp = Self.sharpness(of: frame)
            if sharp > bestSharp {
                bestSharp = sharp
                best = frame
            }
            if i < candidates - 1 {
                try? await Task.sleep(nanoseconds: gapNanos)
            }
        }
        return best
    }

    /// Cheap focus proxy (higher = sharper): variance of a downscaled luma Laplacian. On-device
    /// capture guidance only — an SDK-local heuristic that mirrors no server measurement.
    private static func sharpness(of jpeg: Data) -> Double {
        guard let image = UIImage(data: jpeg), let cg = image.cgImage else { return 0 }
        let w = 48
        let h = 48
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0
        for y in 1 ..< (h - 1) {
            for x in 1 ..< (w - 1) {
                let i = y * w + x
                let lap = 4.0 * Double(pixels[i])
                    - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - w]) - Double(pixels[i + w])
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumSq / count - mean * mean
    }

    /// Wait briefly for a frame to be available (frames flow shortly after the session starts).
    private func awaitFrame(timeout: TimeInterval = 1.5) async -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = camera.grabFrameJPEG() { return frame }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return camera.grabFrameJPEG()
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard !finished else { return }
        finished = true
        camera.stop()
        onFinish(result)
    }

    /// Human-readable prompt for a challenge action. Presentation-only; adds no meaning to the verdict.
    static func humanAction(_ action: String) -> String {
        switch action {
        case "BLINK": return "Blink"
        case "TURN_HEAD_LEFT": return "Turn your head left"
        case "TURN_HEAD_RIGHT": return "Turn your head right"
        case "LOOK_STRAIGHT": return "Look straight ahead"
        case "SMILE": return "Smile"
        case "NOD": return "Nod"
        case "MOVE_CLOSER": return "Move a little closer"
        default:
            return action.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }
}

struct LivenessCaptureScreen: View {
    let theme: BlinkTheme
    let strings: BlinkStrings

    @StateObject private var model: LivenessCaptureModel

    init(theme: BlinkTheme,
         strings: BlinkStrings,
         actions: [String],
         onFinish: @escaping (Result<[Data], Error>) -> Void) {
        self.theme = theme
        self.strings = strings
        _model = StateObject(wrappedValue: LivenessCaptureModel(actions: actions, onFinish: onFinish))
    }

    var body: some View {
        ZStack {
            theme.resolvedBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                header
                stage
                controls
                progressDots
            }
            .padding(20)

            closeButton
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(strings.livenessTitle)
                .font(.headline)
                .foregroundColor(theme.resolvedText)
            Text(strings.livenessHint)
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
                case .denied:
                    Text(strings.cameraDenied)
                        .font(.subheadline)
                        .foregroundColor(theme.resolvedText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                default:
                    BlinkCameraPreview(session: model.camera.captureSession)
                    BlinkGuideOverlay(kind: .circle, accent: theme.resolvedAccent)
                    if !model.prompt.isEmpty {
                        VStack {
                            Text(model.prompt)
                                .font(.system(size: 16, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(theme.resolvedText)
                                .clipShape(Capsule())
                                .padding(.top, 14)
                            Spacer()
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .ready:
            BlinkPrimaryButton(title: strings.startButton, theme: theme) { model.start() }
        case .denied:
            Button(strings.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .foregroundColor(theme.resolvedAccent)
        default:
            Color.clear.frame(height: 52)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< max(model.actionCount, 1), id: \.self) { index in
                Circle()
                    .fill(index <= model.actionIndex && model.phase != .ready
                          ? theme.resolvedAccent
                          : Color.white.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
        }
        .opacity(model.phase == .running || model.phase == .done ? 1 : 0)
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
#endif
