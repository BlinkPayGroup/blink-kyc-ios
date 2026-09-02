//
//  ProtocolTests.swift
//  BlinkKycTests
//
//  Transport-level tests for the protocol client and the fluent flow, using a stubbed URLProtocol so
//  no network (and no camera) is needed. These run on any platform with Foundation + XCTest.
//

import XCTest
@testable import BlinkKyc

// MARK: - Stub transport

final class MockURLProtocol: URLProtocol {
    /// Maps a request to an HTTP status + JSON body.
    static var handler: ((URLRequest) -> (status: Int, json: String))?
    /// Records the requests seen, in order.
    static private(set) var seen: [URLRequest] = []

    static func reset() {
        handler = nil
        seen = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.seen.append(request)
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, json) = handler(request)
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests

final class ProtocolTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testDocumentChallengeDecodes() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"nonce":"abc","expiresInSeconds":120}"#) }
        let proto = BlinkProtocol(baseUrl: "https://api.example.test", sessionToken: "tok",
                                  urlSession: makeSession())
        let challenge = try await proto.documentChallenge()
        XCTAssertEqual(challenge.nonce, "abc")
        XCTAssertEqual(challenge.expiresInSeconds, 120)

        let request = try XCTUnwrap(MockURLProtocol.seen.first)
        XCTAssertEqual(request.url?.path, "/api/sdk/document/challenge")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testSubmitDocumentReturnsOutcome() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sdk/document")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            return (200, #"{"ok":true,"step":"DOCUMENT","code":"DOCUMENT_ACCEPTED","detail":"ok"}"#)
        }
        let proto = BlinkProtocol(baseUrl: "https://api.example.test", sessionToken: "tok",
                                  urlSession: makeSession())
        let outcome = try await proto.submitDocument(Data([0xFF, 0xD8, 0xFF]), nonce: "n1",
                                                     documentType: .passport, side: .front)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.step, .document)
        XCTAssertEqual(outcome.code, "DOCUMENT_ACCEPTED")
    }

    func testErrorBodyMapsToBlinkError() async throws {
        MockURLProtocol.handler = { _ in
            (401, #"{"code":"BLINK_SESSION_INVALID","message":"bad token"}"#)
        }
        let proto = BlinkProtocol(baseUrl: "https://api.example.test", sessionToken: "tok",
                                  urlSession: makeSession())
        do {
            _ = try await proto.finalize()
            XCTFail("expected an error")
        } catch let error as BlinkError {
            XCTAssertEqual(error.code, "BLINK_SESSION_INVALID")
            XCTAssertEqual(error.httpStatus, 401)
        }
    }

    func testFinalizeDecodesVerdict() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"result":"VERIFIED","detail":"All checks passed"}"#) }
        let proto = BlinkProtocol(baseUrl: "https://api.example.test", sessionToken: "tok",
                                  urlSession: makeSession())
        let result = try await proto.finalize()
        XCTAssertEqual(result.result, .verified)
        XCTAssertEqual(result.detail, "All checks passed")
    }

    func testHeadlessFlowRunsBothSteps() async throws {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/sdk/document/challenge":
                return (200, #"{"nonce":"d1","expiresInSeconds":120}"#)
            case "/api/sdk/document":
                return (200, #"{"ok":true,"step":"DOCUMENT","code":"DOCUMENT_ACCEPTED","detail":""}"#)
            case "/api/sdk/liveness/challenge":
                return (200, #"{"nonce":"l1","expiresInSeconds":120,"actions":["BLINK","SMILE"]}"#)
            case "/api/sdk/liveness":
                return (200, #"{"ok":true,"step":"LIVENESS","code":"LIVENESS_ACCEPTED","detail":""}"#)
            case "/api/sdk/finalize":
                return (200, #"{"result":"VERIFIED","detail":"ok"}"#)
            default:
                return (404, #"{"code":"BLINK_ERROR","message":"not found"}"#)
            }
        }

        var seenActions: [String] = []
        let result = try await BlinkKyc(baseUrl: "https://api.example.test",
                                        sessionToken: "tok",
                                        urlSession: makeSession())
            .document(type: .nationalID)
            .face()
            .capture(
                document: { Data([0xFF, 0xD8, 0xFF]) },
                liveness: { actions in
                    seenActions = actions
                    return actions.map { _ in Data([0xFF, 0xD8, 0xFF]) }
                }
            )
            .run()

        XCTAssertEqual(result.result, .verified)
        XCTAssertEqual(seenActions, ["BLINK", "SMILE"])
    }

    func testStepFailureThrowsBlinkStepError() async throws {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/sdk/document/challenge":
                return (200, #"{"nonce":"d1","expiresInSeconds":120}"#)
            case "/api/sdk/document":
                return (200, #"{"ok":false,"step":"DOCUMENT","code":"DOCUMENT_UNREADABLE","detail":"blurry"}"#)
            default:
                return (200, "{}")
            }
        }
        do {
            _ = try await BlinkKyc(baseUrl: "https://api.example.test",
                                   sessionToken: "tok",
                                   urlSession: makeSession())
                .document()
                .capture(document: { Data([0x00]) }, liveness: { _ in [] })
                .run()
            XCTFail("expected a step error")
        } catch let error as BlinkStepError {
            XCTAssertEqual(error.code, "DOCUMENT_UNREADABLE")
            XCTAssertEqual(error.step, .document)
        }
    }
}
