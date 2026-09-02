//
//  Theme.swift
//  BlinkKyc
//
//  Look-and-feel for the drop-in capture UI. Colours only affect presentation; nothing here reveals
//  how verification works.
//

#if canImport(SwiftUI)
import SwiftUI

/// Themeable colours for the built-in capture screens. Any unset colour falls back to a sensible
/// default so a bare `BlinkTheme()` still looks finished.
public struct BlinkTheme {
    /// Accent colour for controls and the framing guide.
    public var accent: Color?
    /// Background behind the camera stage and screen chrome.
    public var background: Color?
    /// Primary text colour.
    public var text: Color?
    /// Foreground colour drawn on top of the accent (e.g. button labels).
    public var onAccent: Color?

    public init(accent: Color? = nil,
                background: Color? = nil,
                text: Color? = nil,
                onAccent: Color? = nil) {
        self.accent = accent
        self.background = background
        self.text = text
        self.onAccent = onAccent
    }

    /// The default theme (Blink green on deep navy).
    public static let `default` = BlinkTheme()

    // Resolved colours used by the capture UI.
    var resolvedAccent: Color { accent ?? Color(red: 0.13, green: 0.77, blue: 0.37) }        // #22c55e
    var resolvedBackground: Color { background ?? Color(red: 0.059, green: 0.09, blue: 0.16) } // #0f1729
    var resolvedText: Color { text ?? Color(red: 0.957, green: 0.965, blue: 0.984) }          // #f4f6fb
    var resolvedOnAccent: Color { onAccent ?? Color(red: 0.031, green: 0.075, blue: 0.122) }   // #08131f
}
#endif

/// User-facing copy for the drop-in capture UI. Override any field to localize or rebrand.
public struct BlinkStrings {
    public var documentTitle: String
    public var documentHint: String
    public var captureButton: String
    public var retake: String
    public var use: String
    public var livenessTitle: String
    public var livenessHint: String
    public var startButton: String
    public var granting: String
    public var cameraDenied: String
    public var openSettings: String
    public var cancel: String

    public init(documentTitle: String = "Scan your document",
                documentHint: String = "Fit the document inside the frame, then capture.",
                captureButton: String = "Capture",
                retake: String = "Retake",
                use: String = "Use photo",
                livenessTitle: String = "Liveness check",
                livenessHint: String = "Follow the prompts. Keep your face inside the circle.",
                startButton: String = "Start",
                granting: String = "Requesting camera…",
                cameraDenied: String = "Camera access is required to continue.",
                openSettings: String = "Open Settings",
                cancel: String = "Cancel") {
        self.documentTitle = documentTitle
        self.documentHint = documentHint
        self.captureButton = captureButton
        self.retake = retake
        self.use = use
        self.livenessTitle = livenessTitle
        self.livenessHint = livenessHint
        self.startButton = startButton
        self.granting = granting
        self.cameraDenied = cameraDenied
        self.openSettings = openSettings
        self.cancel = cancel
    }

    /// The default English strings.
    public static let `default` = BlinkStrings()
}
