# TwaiAvatarKit — iOS native SDK (v0.1)

Native Swift SDK for the 2wai Avatar Toolkit. Transport 0 (LiveKit), mint-proxy pattern, SwiftUI-first. Ships as a Swift Package.

**Status: v0.1 shipped and device-verified** on physical iPhone (greeting plays, audio plays, Q&A loop works, idle video works). Open in Xcode, build + run `Samples/HelloAvatar/` against a running mint proxy.

v0.1 scope: `TwaiCore` + `TwaiLiveKit` + `TwaiPlayer` + one sample. Mic + full catalog hydrate wiring deferred to v0.2.

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    // While the SDK lives inside 2wai-toolkit:
    .package(url: "https://github.com/2waiorg/2wai-toolkit-public", branch: "main"),
    // Or a tagged release once we cut one.
]
```

Then depend on the product you need:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "TwaiPlayer", package: "2wai-toolkit"),
])
```

> **Note.** The sibling SPM package lives at `ios-native/Package.swift` inside `2wai-toolkit`. SPM supports consuming a nested package via `path:` or sibling checkout; the plan is to extract this to a sibling repo (`2waiorg/twai-ios-sdk`) once the shape is iPhone-verified.

Requires: **iOS 15+**, **Swift 5.9+**, Xcode 15+.

## Quickstart (Flow 1 — mint and play)

```swift
import SwiftUI
import TwaiCore
import TwaiLiveKit
import TwaiPlayer

struct AvatarScreen: View {
    @State private var handle: TwaiPlayerHandle?

    private let api = TwaiAPIClient(
        credentials: .mintProxy(url: URL(string: "https://my-app.com/mint-proxy/v1/sessions")!)
    )

    var body: some View {
        TwaiPlayerView(mint: mint)
            .onReady { handle = $0 }
            .task {
                try? await handle?.send("Hi — tell me what you can do.")
            }
    }

    private func mint() async -> TwaiMintResult {
        do {
            let session = try await api.createSession(.init(
                avatarId: "avt_...",
                voiceId: "vc_...",
                mode: .video
            ))
            return .enabled(url: session.livekitUrl, token: session.participantToken, room: session.roomName)
        } catch {
            return .unavailable(message: "\(error)", cause: error)
        }
    }
}
```

Point `mint-proxy` at a running mint proxy. The toolkit ships a Node reference at [`apps/mint_proxy_examples/node/`](../apps/mint_proxy_examples/node/) — bring up with your `sk_` and point `MINT_PROXY_URL` at it.

Full working sample: [`Samples/HelloAvatar/`](Samples/HelloAvatar/).

## Package layout

```
ios-native/
├── Package.swift                     SPM manifest, 3 library products
├── Sources/
│   ├── TwaiCore/                     Pure Swift — types, REST, credentials, errors
│   │   ├── TwaiAPI.swift             TwaiAPI.Avatar / AvatarResult / GreetingPayload / SessionRequest / SessionResponse
│   │   ├── TwaiAPIClient.swift       actor TwaiAPIClient — createSession + getAvatar
│   │   ├── TwaiCredentials.swift     enum — .mintProxy(url:) + ._rawSecretKey
│   │   └── TwaiError.swift           typed error ladder (missingKey, invalidKey, noSuchAvatar, rateLimited, ...)
│   ├── TwaiLiveKit/                  Transport 0 — port of Dart engine.dart
│   │   ├── TwaiEngine.swift          @MainActor class — owns Room, mint flow, event stream
│   │   ├── TwaiMint.swift            TwaiMintResult + TwaiMintClosure typealias
│   │   ├── TwaiEnvelope.swift        TwaiChatEnvelope + TwaiReplyFrame (byte-parallel to Dart)
│   │   └── TwaiEngineEvent.swift     TwaiEngineEvent + TwaiEngineState
│   └── TwaiPlayer/                   SwiftUI — the widget consumers mount
│       ├── TwaiPlayerView.swift      SwiftUI View — ZStack of agent VideoView + overlays
│       └── TwaiPlayerHandle.swift    Imperative control surface (send, disconnect, state)
├── Tests/
│   └── TwaiCoreTests/
│       └── TwaiAPITests.swift        Codable round-trips + error ladder + credentials shape
└── Samples/
    └── HelloAvatar/                  Minimum-possible SwiftUI sample (~70 LOC)
        ├── Package.swift
        └── HelloAvatar/HelloAvatarApp.swift
```

## v0.1 scope

In:
- `TwaiCore`: REST client (`createSession`, `getAvatar`), typed errors, mint-proxy credentials.
- `TwaiLiveKit`: Transport 0 engine with mint-closure pattern, LiveKit room lifecycle, chat envelope encode/decode, speaking + reply events.
- `TwaiPlayer`: `TwaiPlayerView` SwiftUI widget + `TwaiPlayerHandle` imperative API.
- One sample app proving mint-and-play.

Deferred to v0.2:
- `TwaiMic` + `TwaiTranscriber` — mic lifecycle gets its own iPhone-verified pass (see memory `reference_qai_mic_pattern` + `project_jesus_ios_outstanding_issues` for the iOS mic gotchas).
- UIKit `UIViewRepresentable` wrapper (SwiftUI only in v0.1).
- `TwaiProtocol` conformance against `2waiorg/twai-protocol` golden vectors — needs Swift codegen added to that repo first (currently Dart + TS only).
- Full catalog-hydrate UI wiring (greeting playback, intro-vs-return consumption).
- XCFramework distribution (SPM only in v0.1).
- Call mode (deferred until Mason's web SDK PR #4 lands + the Dart port stabilizes).

## Known caveats

- **Mint-proxy GET route for catalog hydrate is a convention.** `TwaiAPIClient.getAvatar` derives the hydrate URL by stripping `/v1/sessions` from the mint-proxy URL and appending `/v1/avatars/{owner}/{name}`. If your mint proxy's path layout differs, override the gateway base URL or extend the client to accept a per-route URL template.
- **Catalog hydrate returns a gen RID that today's mint path doesn't accept.** Use the per-tenant `avt_...` from your account for `createSession` and treat `getAvatar()` output as metadata only. See [the dev docs tenancy explainer](https://developers.2wai.ai/concepts/#avatar-ids-are-per-tenant).

## Related

- [Flutter SDK](../packages/) — the sibling implementation. Transport 0 engine source: [`packages/twai_avatar_sdk_livekit/lib/src/transport0/`](../packages/twai_avatar_sdk_livekit/lib/src/transport0/).
- [TypeScript SDK](https://github.com/2waiorg/twai-web-sdk) — the web sibling.
- [Dev docs](https://developers.2wai.ai/sdks/ios-native/) — iOS native SDK page with the public quickstart.
