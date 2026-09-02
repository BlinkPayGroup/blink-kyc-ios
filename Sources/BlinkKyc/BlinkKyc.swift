//
//  BlinkKyc.swift
//  BlinkKyc
//
//  Drop-in identity verification for iOS. Your backend mints a session; the SDK runs the capture
//  (document + liveness) and returns a verdict. A black box: you get VERIFIED / REJECTED / REVIEW
//  and a neutral reason, never a score or any detail of how it was reached.
//
//  ```swift
//  // sessionToken came from YOUR backend (POST /api/blink/session/create).
//  let outcome = try await BlinkKyc(baseUrl: "https://kyc-api.blink-pay.net", sessionToken: token)
//      .document(type: .passport)
//      .face()
//      .present(on: self)                 // the SDK owns the camera UI
//      .onProgress { print($0.step) }
//      .run()
//  // Confirm outcome.result from YOUR backend via GET /api/blink/session/{id}/result.
//  ```
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The stage the SDK is at, delivered to `onProgress`.
public struct BlinkProgress: Sendable, Equatable {
    public let step: String
    public let detail: String?

    public init(step: String, detail: String? = nil) {
        self.step = step
        self.detail = detail
    }
}

/// Headless capture: supply the media yourself instead of using the built-in UI.
///
/// - `document` returns the captured document image as JPEG/PNG `Data`.
/// - `liveness` performs the requested actions and returns one or more frames.
public struct BlinkCaptureHooks {
    public var document: () async throws -> Data
    public var liveness: (_ actions: [String]) async throws -> [Data]

    public init(document: @escaping () async throws -> Data,
                liveness: @escaping (_ actions: [String]) async throws -> [Data]) {
        self.document = document
        self.liveness = liveness
    }
}

/// Supplies capture media for a flow — either the drop-in camera UI or your own headless hooks.
public protocol BlinkCaptureProvider {
    func captureDocument(documentType: DocumentType?, side: DocumentSide?) async throws -> Data
    func captureLiveness(actions: [String]) async throws -> [Data]
}

/// A `BlinkCaptureProvider` backed by caller-supplied ``BlinkCaptureHooks`` (headless mode).
struct HooksCaptureProvider: BlinkCaptureProvider {
    let hooks: BlinkCaptureHooks

    func captureDocument(documentType: DocumentType?, side: DocumentSide?) async throws -> Data {
        try await hooks.document()
    }

    func captureLiveness(actions: [String]) async throws -> [Data] {
        try await hooks.liveness(actions)
    }
}

/// Fluent entry point. Configure the steps, choose a capture mode, then `run()`.
public final class BlinkKyc {
    private let proto: BlinkProtocol
    private let theme: BlinkTheme?
    private let strings: BlinkStrings

    private var wantDocument = false
    private var documentType: DocumentType?
    private var documentSide: DocumentSide?
    private var wantFace = false
    private var hooks: BlinkCaptureHooks?
    private var listeners: [(BlinkProgress) -> Void] = []

    #if canImport(UIKit)
    private weak var uiPresenter: UIViewController?
    #endif

    /// - Parameters:
    ///   - baseUrl: Base URL of the Blink API, e.g. `https://kyc-api.blink-pay.net`.
    ///   - sessionToken: The token your backend obtained from `POST /api/blink/session/create`.
    ///   - timeout: Per-request timeout in seconds (default 30).
    ///   - theme: Optional theme for the built-in capture UI.
    ///   - strings: Optional string overrides / localization for the built-in capture UI.
    ///   - urlSession: Optional `URLSession` (for testing or custom transport).
    public init(baseUrl: String,
                sessionToken: String,
                timeout: TimeInterval = 30,
                theme: BlinkTheme? = nil,
                strings: BlinkStrings = .default,
                urlSession: URLSession = .shared) {
        self.proto = BlinkProtocol(baseUrl: baseUrl, sessionToken: sessionToken,
                                   timeout: timeout, urlSession: urlSession)
        self.theme = theme
        self.strings = strings
    }

    // MARK: Configuration

    /// Enable the document step. Omit `type` to let the server apply its default.
    @discardableResult
    public func document(type: DocumentType? = nil, side: DocumentSide? = nil) -> Self {
        wantDocument = true
        documentType = type
        documentSide = side
        return self
    }

    /// Enable the liveness + face step.
    @discardableResult
    public func face() -> Self {
        wantFace = true
        return self
    }

    /// Supply your own capture media instead of the built-in UI (headless mode).
    @discardableResult
    public func capture(_ hooks: BlinkCaptureHooks) -> Self {
        self.hooks = hooks
        return self
    }

    /// Supply your own capture media with two closures (headless mode).
    @discardableResult
    public func capture(document: @escaping () async throws -> Data,
                        liveness: @escaping (_ actions: [String]) async throws -> [Data]) -> Self {
        self.hooks = BlinkCaptureHooks(document: document, liveness: liveness)
        return self
    }

    /// Subscribe to progress events. Callbacks may run off the main thread.
    @discardableResult
    public func onProgress(_ callback: @escaping (BlinkProgress) -> Void) -> Self {
        listeners.append(callback)
        return self
    }

    #if canImport(UIKit)
    /// Present the built-in capture UI (document camera + liveness) modally from this view controller.
    @discardableResult
    public func present(on viewController: UIViewController) -> Self {
        uiPresenter = viewController
        return self
    }
    #endif

    // MARK: Access

    /// The low-level protocol client, if you want to drive steps yourself.
    public var session: BlinkProtocol { proto }

    /// Read-only session progress from the server.
    public func status() async throws -> StatusView {
        try await proto.status()
    }

    // MARK: Run

    /// Run the configured flow and resolve with the verdict.
    ///
    /// If neither step was enabled, both run (the default full capture). Throws ``BlinkStepError`` on
    /// a business failure, ``BlinkError`` on transport, configuration, camera, or cancellation.
    @discardableResult
    public func run() async throws -> SessionResult {
        let runDocument = wantDocument || (!wantDocument && !wantFace)
        let runFace = wantFace || (!wantDocument && !wantFace)

        let provider = try await makeProvider()

        if runDocument {
            emit("document:challenge")
            let challenge = try await proto.documentChallenge()
            emit("document:capture")
            let image = try await provider.captureDocument(documentType: documentType, side: documentSide)
            emit("document:submit")
            let outcome = try await proto.submitDocument(image, nonce: challenge.nonce,
                                                         documentType: documentType, side: documentSide)
            try check(outcome)
        }

        if runFace {
            emit("liveness:challenge")
            let challenge = try await proto.livenessChallenge()
            emit("liveness:capture", challenge.actions.joined(separator: ","))
            let frames = try await provider.captureLiveness(actions: challenge.actions)
            emit("liveness:submit")
            let outcome = try await proto.submitLiveness(frames, nonce: challenge.nonce)
            try check(outcome)
        }

        emit("finalize")
        let result = try await proto.finalize()
        emit("done", result.result.rawValue)
        return result
    }

    // MARK: Internals

    // `@MainActor` so the built-in UI provider (which retains a UIViewController) is created on the
    // main thread. Awaited from `run()`, it hops to the main actor and hops back with the provider.
    @MainActor
    private func makeProvider() throws -> BlinkCaptureProvider {
        if let hooks {
            return HooksCaptureProvider(hooks: hooks)
        }
        #if canImport(UIKit)
        if let presenter = uiPresenter {
            return BlinkUICaptureProvider(presenter: presenter, theme: theme ?? .default, strings: strings)
        }
        #endif
        throw BlinkError.client(
            "BLINK_CONFIG",
            "Call present(on:) for the built-in UI, or capture(_:) to supply media yourself"
        )
    }

    private func check(_ outcome: StepOutcome) throws {
        if !outcome.ok { throw BlinkStepError(outcome: outcome) }
    }

    private func emit(_ step: String, _ detail: String? = nil) {
        let progress = BlinkProgress(step: step, detail: detail)
        for listener in listeners {
            listener(progress)
        }
    }
}
