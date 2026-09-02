//
//  UICaptureProvider.swift
//  BlinkKyc
//
//  Bridges the drop-in SwiftUI capture screens into the ``BlinkCaptureProvider`` the flow drives.
//  Presents each step full-screen from the caller's view controller and resolves with its media.
//

#if canImport(UIKit)
import SwiftUI
import UIKit

/// A ``BlinkCaptureProvider`` that owns the native camera and presents the built-in capture screens.
@MainActor
final class BlinkUICaptureProvider: BlinkCaptureProvider {
    private weak var presenter: UIViewController?
    private let theme: BlinkTheme
    private let strings: BlinkStrings

    init(presenter: UIViewController, theme: BlinkTheme, strings: BlinkStrings) {
        self.presenter = presenter
        self.theme = theme
        self.strings = strings
    }

    func captureDocument(documentType: DocumentType?, side: DocumentSide?) async throws -> Data {
        try await present { onFinish in
            DocumentCaptureScreen(theme: self.theme,
                                  strings: self.strings,
                                  documentType: documentType,
                                  side: side,
                                  onFinish: onFinish)
        }
    }

    func captureLiveness(actions: [String]) async throws -> [Data] {
        try await present { onFinish in
            LivenessCaptureScreen(theme: self.theme,
                                  strings: self.strings,
                                  actions: actions,
                                  onFinish: onFinish)
        }
    }

    /// Present a capture screen full-screen and await its single result, then dismiss.
    private func present<T, Content: View>(
        _ make: (@escaping (Result<T, Error>) -> Void) -> Content
    ) async throws -> T {
        guard let presenter else {
            throw BlinkError.client("BLINK_CONFIG", "The presenting view controller was released")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            var host: UIViewController?
            var resumed = false

            let onFinish: (Result<T, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                if let host {
                    host.dismiss(animated: true) { continuation.resume(with: result) }
                } else {
                    continuation.resume(with: result)
                }
            }

            let controller = UIHostingController(rootView: make(onFinish))
            controller.modalPresentationStyle = .fullScreen
            host = controller
            presenter.present(controller, animated: true)
        }
    }
}
#endif
