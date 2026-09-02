// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlinkKyc",
    platforms: [
        .iOS(.v14),
        // macOS is supported for the pure-Foundation protocol layer and the test suite only; the
        // drop-in camera UI is iOS-only (compiled out where UIKit is unavailable).
        .macOS(.v11),
    ],
    products: [
        // Drop-in identity verification for iOS: mint a session on your backend, run the
        // capture on device, act on the verdict your backend fetches server-to-server.
        .library(name: "BlinkKyc", targets: ["BlinkKyc"]),
    ],
    targets: [
        .target(
            name: "BlinkKyc",
            path: "Sources/BlinkKyc"
        ),
        .testTarget(
            name: "BlinkKycTests",
            dependencies: ["BlinkKyc"],
            path: "Tests/BlinkKycTests"
        ),
    ]
)
