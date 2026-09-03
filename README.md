# BlinkKyc (iOS)

Drop-in identity verification for iOS. Your backend mints a session; the SDK runs the capture
(document + liveness) and returns a verdict. **A black box** — you get `VERIFIED` / `REJECTED` /
`REVIEW` and a neutral reason, never a score or any detail of how it was reached.

Zero third-party dependencies · Swift Package or CocoaPods · SwiftUI drop-in UI · iOS 14+.

## The trust boundary — read this first

```
Your backend                         Device (this SDK)                  Blink
────────────                         ─────────────────                  ─────
client_key + client_secret ── POST /api/blink/session/create ─────────▶  (never sees the secret)
        │  ◀── { sessionId, sessionToken } ─────────┐
        └── hands sessionToken to the app ──────────▶ BlinkKyc(baseUrl:sessionToken:).run()
Your backend ◀── GET /api/blink/session/{id}/result ── the AUTHORITATIVE verdict (never trust the device)
```

- The **client secret never reaches the device** — your backend mints the session server-to-server.
- Every step is **replay-resistant** (a fresh single-use nonce per step).
- **Act on the verdict your backend fetches**, not the copy the app reports.

## Install

### Swift Package Manager

In Xcode: *File ▸ Add Package Dependencies…* and point at this repository, or add to `Package.swift`:

```swift
.package(url: "https://github.com/BlinkPayGroup/blink-kyc-ios.git", from: "1.3.0")
```

### CocoaPods

```ruby
pod 'BlinkKyc', '~> 1.0'
```

### Info.plist

The drop-in UI opens the camera, so add a usage description:

```xml
<key>NSCameraUsageDescription</key>
<string>We use the camera to scan your document and confirm your identity.</string>
```

## Quick start (drop-in UI)

```swift
import BlinkKyc

// `sessionToken` came from YOUR backend (POST /api/blink/session/create).
func verify(from presenter: UIViewController, sessionToken: String) async {
    do {
        let outcome = try await BlinkKyc(baseUrl: "https://kyc-api.blink-pay.net", sessionToken: sessionToken)
            .document(type: .passport)   // .passport | .nationalID | .idCard | .drivingLicence
            .face()                      // liveness + face
            .present(on: presenter)      // the SDK owns the camera UI
            .onProgress { print($0.step) }
            .run()

        // outcome: SessionResult { result: .verified | .rejected | .review, detail: String }
        // Confirm outcome.result from YOUR backend before trusting it.
        print(outcome.result)
    } catch let error as BlinkStepError {
        print("step \(error.step) failed: \(error.code)")   // e.g. DOCUMENT_UNREADABLE
    } catch let error as BlinkError {
        print("transport: \(error.code) [\(error.httpStatus)]") // e.g. BLINK_SESSION_INVALID
    } catch {
        print(error)
    }
}
```

## Headless mode (bring your own camera)

Supply the media yourself; the SDK owns only the protocol.

```swift
try await BlinkKyc(baseUrl: baseUrl, sessionToken: sessionToken)
    .document(type: .nationalID)
    .face()
    .capture(
        document: { try await grabDocumentJPEG() },        // return image Data
        liveness: { actions in try await recordFrames(actions) } // perform actions, return [Data]
    )
    .run()
```

## Theming

```swift
BlinkKyc(
    baseUrl: baseUrl,
    sessionToken: sessionToken,
    theme: BlinkTheme(accent: .green, background: Color(red: 0.06, green: 0.09, blue: 0.16)),
    strings: BlinkStrings(documentTitle: "Scan your ID")
)
```

## API

| | |
|---|---|
| `BlinkKyc(baseUrl:sessionToken:timeout:theme:strings:urlSession:)` | create a flow |
| `.document(type:side:)` | enable the document step |
| `.face()` | enable liveness + face |
| `.present(on:)` | render the built-in capture UI, presented from a `UIViewController` |
| `.capture(_:)` / `.capture(document:liveness:)` | headless: supply the media yourself |
| `.onProgress(_:)` | step progress callbacks |
| `.run()` | `async throws -> SessionResult` |
| `.session` | the low-level `BlinkProtocol` if you want to drive steps yourself |
| `.status()` | read-only session progress |

If neither `.document()` nor `.face()` is called, `run()` performs both (the default full capture).

## Low-level protocol

`BlinkProtocol` mirrors the `/api/sdk/**` device surface one call at a time:

```swift
let proto = BlinkProtocol(baseUrl: baseUrl, sessionToken: sessionToken)
let challenge = try await proto.documentChallenge()
let outcome   = try await proto.submitDocument(imageData, nonce: challenge.nonce, documentType: .passport)
// livenessChallenge() / submitLiveness(_:nonce:) / finalize() / status()
```

## Errors

- **`BlinkError`** — transport / HTTP / configuration failure. `.code` (e.g. `BLINK_SESSION_INVALID`,
  `BLINK_CHALLENGE_INVALID`, `BLINK_TIMEOUT`, `BLINK_CANCELLED`), `.httpStatus`. Switch on `.code`.
- **`BlinkStepError`** — a business failure at a step (e.g. `DOCUMENT_UNREADABLE`, `LIVENESS_FAILED`).
  `.code`, `.step`.

The final decision is always one of `VERIFIED`, `REJECTED`, `REVIEW`. Full error + outcome catalog
and the raw HTTP contract: `docs/blink-client-openapi.yaml`.

## Develop

```bash
swift test        # protocol + flow tests (stubbed transport, no camera needed)
```

The capture UI compiles for iOS (UIKit / AVFoundation / SwiftUI); the protocol layer is pure
Foundation and is what the tests exercise.
