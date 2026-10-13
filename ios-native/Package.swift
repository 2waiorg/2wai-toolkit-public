// swift-tools-version:5.9
import PackageDescription

// 2wai Avatar Toolkit — iOS native SDK (v0.1)
//
// SPM manifest for TwaiAvatarKit — 2wai avatars on iOS via Transport 0 (LiveKit).
//
// v0.1 scope: TwaiCore (REST + types + credentials + errors), TwaiLiveKit
// (Transport 0 engine port of the Dart engine.dart), TwaiPlayer (SwiftUI
// TwaiPlayerView + handle). Mic + full catalog hydrate are v0.2.
//
// Device-verified on physical iPhone (greeting, audio, Q&A, idle).

let package = Package(
    name: "TwaiAvatarKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // Consumers typically depend on TwaiPlayer; it transitively pulls Core + LiveKit.
        .library(name: "TwaiPlayer", targets: ["TwaiPlayer"]),
        .library(name: "TwaiLiveKit", targets: ["TwaiLiveKit"]),
        .library(name: "TwaiCore", targets: ["TwaiCore"]),
    ],
    dependencies: [
        // LiveKit Swift SDK — the Transport 0 wire. Pinned to 2.x minor to
        // match the Flutter toolkit's livekit_client ^2.9.0 pin. If PP's own
        // iOS build later pins to a different 2.x, align here.
        // PINNED, load-bearing — mirrors the Flutter toolkit's livekit_client 2.8.1 pin.
        // Later 2.x moved iOS audio onto LiveKit's own AVAudioEngine device module
        // ("engine-driven native lifecycle"), which only starts playout once a
        // track is PUBLISHED. A receive-only avatar publishes nothing, so the
        // decoded remote audio is never pulled and the client is silent while
        // every diagnostic (session category, route, volume, subscribed+unmuted
        // track) reads correct.
        .package(url: "https://github.com/livekit/client-sdk-swift", .upToNextMinor(from: "2.3.0")),
    ],
    targets: [
        // TwaiCore — pure Swift, no UI, no transport. Depends on nothing external.
        // Mint-proxy credentials, REST client (createSession + getAvatar), typed
        // error ladder, codable protocol types.
        .target(
            name: "TwaiCore",
            dependencies: [],
            path: "Sources/TwaiCore"
        ),

        // TwaiLiveKit — Transport 0 engine. Ports lib/src/transport0/engine.dart
        // from the Flutter toolkit. Depends on TwaiCore + livekit-client.
        .target(
            name: "TwaiLiveKit",
            dependencies: [
                "TwaiCore",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "Sources/TwaiLiveKit"
        ),

        // TwaiPlayer — the SwiftUI widget consumers actually mount. Owns the
        // engine lifecycle, exposes handle + events.
        .target(
            name: "TwaiPlayer",
            dependencies: ["TwaiCore", "TwaiLiveKit"],
            path: "Sources/TwaiPlayer"
        ),

        // Tests — v0.1 covers TwaiCore (types + REST shape). Engine +
        // Player tests are v0.2 (need the twai-protocol Swift conformance
        // vectors landed first).
        .testTarget(
            name: "TwaiCoreTests",
            dependencies: ["TwaiCore"],
            path: "Tests/TwaiCoreTests"
        ),
    ]
)
