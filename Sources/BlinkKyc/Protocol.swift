//
//  Protocol.swift
//  BlinkKyc
//
//  Low-level Blink session protocol — the exact `/api/sdk/**` surface, typed.
//
//  The client secret never reaches this layer: your backend mints a session with
//  `POST /api/blink/session/create` and hands the device only the short-lived `sessionToken`.
//  Every step fetches a fresh single-use nonce and submits echoing it; a replay is refused by the
//  server. The verdict you act on is the one your backend fetches server-to-server — never trust the
//  copy the device sees.
//
//  This is a black box by design: you get a verdict and a neutral reason, never a score or method.
//

import Foundation

// MARK: - Wire model

/// The final decision. Always one of these three — never a score or a reason of how it was reached.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    case verified = "VERIFIED"
    case rejected = "REJECTED"
    case review   = "REVIEW"
}

/// Neutral, region-agnostic document type. The SDK never exposes which one an image actually was.
public enum DocumentType: String, Codable, Sendable, CaseIterable {
    case passport       = "PASSPORT"
    case nationalID     = "NATIONAL_ID"
    case idCard         = "ID_CARD"
    case drivingLicence = "DRIVING_LICENCE"
}

/// Which face of a two-sided document is being submitted.
public enum DocumentSide: String, Codable, Sendable, CaseIterable {
    case front = "FRONT"
    case back  = "BACK"
}

/// The capture step a `StepOutcome` refers to.
public enum StepName: String, Codable, Sendable {
    case document = "DOCUMENT"
    case liveness = "LIVENESS"
}

/// A server-issued, single-use challenge. Echo `nonce` on the matching submit.
public struct Challenge: Codable, Sendable, Equatable {
    public let nonce: String
    public let expiresInSeconds: Int

    public init(nonce: String, expiresInSeconds: Int) {
        self.nonce = nonce
        self.expiresInSeconds = expiresInSeconds
    }
}

/// A liveness challenge — a `Challenge` plus the actions the user must perform.
public struct LivenessChallenge: Codable, Sendable, Equatable {
    public let nonce: String
    public let expiresInSeconds: Int
    /// Actions the user must perform (e.g. `BLINK`, `TURN_HEAD_LEFT`). Presentation-only strings.
    public let actions: [String]

    public init(nonce: String, expiresInSeconds: Int, actions: [String]) {
        self.nonce = nonce
        self.expiresInSeconds = expiresInSeconds
        self.actions = actions
    }
}

/// The result of submitting one capture step.
///
/// A business failure (e.g. the document was unreadable) is `ok == false` with HTTP 200 — check
/// this flag, not the status code. The `code` is a neutral outcome code from the catalog.
public struct StepOutcome: Codable, Sendable, Equatable {
    public let ok: Bool
    public let step: StepName
    public let code: String
    public let detail: String

    public init(ok: Bool, step: StepName, code: String, detail: String) {
        self.ok = ok
        self.step = step
        self.code = code
        self.detail = detail
    }
}

/// The verdict as returned to the device by `finalize` — a non-authoritative convenience copy.
/// Always confirm the real verdict from your backend's result endpoint.
public struct SessionResult: Codable, Sendable, Equatable {
    public let result: Verdict
    /// A neutral, human-readable reason. Never a score or method.
    public let detail: String

    public init(result: Verdict, detail: String) {
        self.result = result
        self.detail = detail
    }
}

/// Read-only session progress from the server.
public struct StatusView: Codable, Sendable, Equatable {
    public let status: String
    public let currentStep: String?
    public let stepsCompleted: [String]
    public let resultStatus: Verdict?

    public init(status: String, currentStep: String?, stepsCompleted: [String], resultStatus: Verdict?) {
        self.status = status
        self.currentStep = currentStep
        self.stepsCompleted = stepsCompleted
        self.resultStatus = resultStatus
    }
}

// MARK: - Errors

/// A typed transport / HTTP error carrying the stable server `code`.
///
/// Switch on `code`, not on `localizedDescription`. Codes raised locally by the SDK (configuration,
/// timeout, camera, cancellation) use `httpStatus == 0`; codes from the server carry its status.
public struct BlinkError: Error, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public let httpStatus: Int

    public init(code: String, message: String, httpStatus: Int) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
    }

    public var errorDescription: String? { message }

    /// A client-side (non-HTTP) error, e.g. configuration, timeout, or cancellation.
    static func client(_ code: String, _ message: String) -> BlinkError {
        BlinkError(code: code, message: message, httpStatus: 0)
    }
}

/// A business step failure surfaced from a `StepOutcome` with `ok == false`
/// (e.g. `DOCUMENT_UNREADABLE`, `LIVENESS_FAILED`). Switch on `code`.
public struct BlinkStepError: Error, LocalizedError, Equatable {
    public let code: String
    public let step: StepName
    public let detail: String

    public init(outcome: StepOutcome) {
        self.code = outcome.code
        self.step = outcome.step
        self.detail = outcome.detail
    }

    public var errorDescription: String? { detail.isEmpty ? code : detail }
}

/// The standard error envelope every 4xx/5xx carries (including at the auth-filter level).
private struct BlinkErrorBody: Decodable {
    let code: String?
    let message: String?
}

// MARK: - Protocol client

/// The low-level `/api/sdk/**` client. Drive the steps yourself, or let ``BlinkKyc`` orchestrate them.
public final class BlinkProtocol {
    private let base: String
    private let token: String
    private let timeout: TimeInterval
    private let urlSession: URLSession
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - baseUrl: Base URL of the Blink API, e.g. `https://kyc-api.blink-pay.net`.
    ///   - sessionToken: The session token your backend obtained from `POST /api/blink/session/create`.
    ///   - timeout: Per-request timeout in seconds (default 30).
    ///   - urlSession: Optional `URLSession` (for testing or custom transport).
    public init(baseUrl: String,
                sessionToken: String,
                timeout: TimeInterval = 30,
                urlSession: URLSession = .shared) {
        // Strip trailing slashes so `base + path` never double-slashes.
        var b = baseUrl
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.token = sessionToken
        self.timeout = timeout
        self.urlSession = urlSession
    }

    // ── Steps ────────────────────────────────────────────────────────────────

    /// Start the document step and receive a fresh single-use challenge.
    public func documentChallenge() async throws -> Challenge {
        try await send(path: "/api/sdk/document/challenge", method: "POST", body: nil, contentType: nil)
    }

    /// Submit the captured document image, echoing the challenge `nonce`.
    public func submitDocument(_ image: Data,
                               nonce: String,
                               documentType: DocumentType? = nil,
                               side: DocumentSide? = nil) async throws -> StepOutcome {
        var fields: [(String, String)] = [("nonce", nonce)]
        if let documentType { fields.append(("documentType", documentType.rawValue)) }
        if let side { fields.append(("side", side.rawValue)) }
        let (body, boundary) = Self.multipart(
            fields: fields,
            files: [(name: "image", filename: "document", mime: "image/jpeg", data: image)]
        )
        return try await send(path: "/api/sdk/document", method: "POST", body: body,
                              contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// Start the liveness step and receive a challenge plus the actions to perform.
    public func livenessChallenge() async throws -> LivenessChallenge {
        try await send(path: "/api/sdk/liveness/challenge", method: "POST", body: nil, contentType: nil)
    }

    /// Submit the recorded liveness frames, echoing the challenge `nonce`.
    public func submitLiveness(_ frames: [Data], nonce: String) async throws -> StepOutcome {
        let files = frames.enumerated().map { index, data in
            (name: "frames", filename: "frame-\(index)", mime: "image/jpeg", data: data)
        }
        let (body, boundary) = Self.multipart(fields: [("nonce", nonce)], files: files)
        return try await send(path: "/api/sdk/liveness", method: "POST", body: body,
                              contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// Finalize the flow and return the (non-authoritative) verdict copy. Confirm from your backend.
    public func finalize() async throws -> SessionResult {
        try await send(path: "/api/sdk/finalize", method: "POST", body: nil, contentType: nil)
    }

    /// Read-only session progress.
    public func status() async throws -> StatusView {
        try await send(path: "/api/sdk/status", method: "GET", body: nil, contentType: nil)
    }

    // ── Transport ────────────────────────────────────────────────────────────

    private func send<T: Decodable>(path: String,
                                    method: String,
                                    body: Data?,
                                    contentType: String?) async throws -> T {
        guard !base.isEmpty else { throw BlinkError.client("BLINK_CONFIG", "baseUrl is required") }
        guard !token.isEmpty else { throw BlinkError.client("BLINK_CONFIG", "sessionToken is required") }
        guard let url = URL(string: base + path) else {
            throw BlinkError.client("BLINK_CONFIG", "baseUrl is invalid")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        let (data, http) = try await perform(request)

        guard (200 ..< 300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(BlinkErrorBody.self, from: data)
            let code = envelope?.code ?? "BLINK_ERROR"
            let message = envelope?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw BlinkError(code: code, message: message, httpStatus: http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BlinkError.client("BLINK_DECODE", "Malformed response from Blink")
        }
    }

    /// A `URLSession.data(for:)` equivalent that also works on iOS 14, mapping transport errors to
    /// stable `BlinkError` codes.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = urlSession.dataTask(with: request) { data, response, error in
                if let error = error {
                    let urlError = error as? URLError
                    switch urlError?.code {
                    case .some(.timedOut):
                        continuation.resume(throwing: BlinkError.client("BLINK_TIMEOUT", "The request timed out"))
                    case .some(.cancelled):
                        continuation.resume(throwing: BlinkError.client("BLINK_CANCELLED", "The request was cancelled"))
                    default:
                        continuation.resume(throwing: BlinkError.client("BLINK_NETWORK", "Network error reaching Blink"))
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: BlinkError.client("BLINK_NETWORK", "No HTTP response from Blink"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    /// Build a `multipart/form-data` body. Returns the encoded body and the boundary used.
    static func multipart(fields: [(String, String)],
                          files: [(name: String, filename: String, mime: String, data: Data)]) -> (Data, String) {
        let boundary = "BlinkBoundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        for file in files {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mime)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return (body, boundary)
    }
}
