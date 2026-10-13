# 2wai Avatar Toolkit

Developer kit for embedding talking, lip-synced AI avatars into your app. Flutter SDK + iOS native (Swift) SDK + mint-proxy references + wire-protocol docs + working samples. If you want an avatar on your screen that talks over LiveKit against 2wai's render pipeline, this repo is the on-ramp.

**Dev docs + quickstarts:** [https://developers.2wai.ai/](https://developers.2wai.ai/)
**Sign up for an sk_ key:** [https://2wai.ai/developers](https://2wai.ai/developers)

**Live-chat transport: Transport 0 (LiveKit) only.** The older MSE and POST/chat paths are retired on the production gateway. Every sample in [`apps/`](apps/) is T0.

---

## 5 minutes to a talking avatar

```bash
# 1. Pull Dart deps
flutter pub get

# 2. Start the Node mint proxy (holds your sk_, mints short-lived tokens for the client)
#    Add your sk_ to apps/mint_proxy_examples/node/.env — see that README.
cd apps/mint_proxy_examples/node && npm install && node server.js &

# 3. Run the smallest possible talking-avatar app in a browser
cd apps/hello_avatar && flutter run -d chrome
```

Need a key? Sign up at [2wai.ai/developers](https://2wai.ai/developers). The mint proxy exists so the `sk_` never reaches the client — enforced across every SDK, non-negotiable.

---

## What's in this repo

| Folder | What |
|---|---|
| [`packages/`](packages/) | The Flutter SDK — four shipped packages (`twai_avatar_sdk`, `_core`, `_livekit`, `_speech_to_text_patched`), plus internal platform shims and a transitional JS Custom Element (`twai_web_component_t0`). |
| [`ios-native/`](ios-native/) | Swift SDK (SwiftUI, SPM) — `TwaiCore`, `TwaiLiveKit`, `TwaiPlayer` library products + `HelloAvatar` sample. iOS 15+. |
| [`apps/`](apps/) | Flutter reference samples (T0 only). See [`apps/README.md`](apps/README.md) for the map. |
| [`samples/`](samples/) | Web sample track (vanilla JS / React / Next.js) — pairs with the TypeScript SDK ([`twai-web-sdk`](https://github.com/2waiorg/twai-web-sdk)). |
| [`docs/`](docs/) | Toolkit-orientation docs — protocol, SDK overview, architecture, mint-proxy, integration gotchas. [`docs/README.md`](docs/README.md) is the map. |
| [`openapi/`](openapi/), [`postman/`](postman/) | API contract + Postman collection — hit the gateway from anything that speaks HTTP. |

---

## Pick a starting sample

| Sample | What it shows | Start here if you want to… |
|---|---|---|
| [`hello_avatar/`](apps/hello_avatar/) | Smallest working T0 avatar — ~70 LOC of load-bearing code | See the minimum shape, then grow from there |
| [`twai_api_starter/`](apps/twai_api_starter/) | Echo-mode starter with every parameter heavily commented | Copy-paste starting point for your own app |
| [`avatar_only_flutter/`](apps/avatar_only_flutter/) | Avatar-only pattern: 2wai avatar + your own LLM over mint-proxy | Integrate your existing brain with a 2wai avatar |
| [`twai_api_demo/`](apps/twai_api_demo/) | Zero-SDK harness — hand-rolled REST + WebSocket in Dart | Understand the raw wire before adopting the SDK |
| [`embed/`](apps/embed/) | `<twai-avatar>` / `<twai-chat>` Custom Elements | Drop an avatar into a plain HTML page, no framework |
| [`mint_proxy_examples/`](apps/mint_proxy_examples/) | Node / Python / CF Worker mint-proxy templates | Build the server-side piece every integration needs |
| [`avatar_player_lab/`](apps/avatar_player_lab/) | Diagnostic lab exercising the full player surface | Dig into player internals or debug a pipeline issue |

Full index: [`apps/README.md`](apps/README.md). Flutter-iOS complete walkthrough: [https://developers.2wai.ai/guides/flutter-ios-quickstart/](https://developers.2wai.ai/guides/flutter-ios-quickstart/).

---

## Transport 0 code shape

```dart
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

// 1. Point at your mint proxy. Your server holds the sk_;
//    the client only ever sees the short-lived JWT the proxy returns.
final rest = TwaiApiRestClient(
  baseUrl: Uri.parse('https://your-mint-proxy.example.com'),
  credentials: const AnonymousCredentials(),
);

// 2. Mint closure. Called by the player on connect + reconnect.
Future<t0.MintResult> mint() async {
  final r = await rest.createLiveKitSession(
    TwaiApiLiveKitSessionRequest(avatarId: 'avt_...'),
  );
  return t0.MintResultEnabled(
    url: r.livekitUrl.toString(),
    token: r.participantToken,
    room: r.roomName,
  );
}

// 3. Drop the player widget in.
t0.TwaiTransport0Player(
  mint: mint,
  idleBuilder: (ctx) =>
      NetworkVideoIdle(Uri.parse('https://.../idle.mp4')).build(ctx),
  onSpeaking: (e) => setState(() => _speaking = e.active),
  onReplyText: (e) => print('avatar: ${e.text}'),
);

// 4. Push-to-talk mic — opt-in, zero-config default.
TwaiMicButton(
  transcriber: DefaultTranscriber(),
  enabled: ready && !_speaking,
  onTranscript: (text) => _engine.send(text),
);
```

Full working reference: [`apps/twai_api_starter/`](apps/twai_api_starter/).

---

## Avatar ids are per-tenant

An `avatar_id` is scoped to your account — the sample `avt_...` in a snippet won't mint on YOUR `sk_`. You get your own `avt_...` ids provisioned when you sign up. Full explanation + the three canonical 404 shapes: [https://developers.2wai.ai/concepts/#avatar-ids-are-per-tenant](https://developers.2wai.ai/concepts/#avatar-ids-are-per-tenant).

To resolve an avatar's metadata by human handle (display name, idle video, greeting):

```dart
final result = await rest.getAvatar(owner: 'brian-alman', name: 'brian');
print(result.avatar.displayName); // "Brian"
print(result.avatar.idleUrl);     // signed MP4 URL
// result.avatar.greeting carries intro video + text when available
```

Note: catalog hydrate returns rich metadata but the mint path still needs the per-tenant `avt_...` from your account today. See [the guide](https://developers.2wai.ai/guides/catalog-hydrate/) for the current shape.

---

## Pinned iOS dependencies (load-bearing)

Three pins carried as `dependency_overrides` in the root [`pubspec.yaml`](pubspec.yaml):

```yaml
dependency_overrides:
  livekit_client: 2.8.1                            # newer versions break iOS receive-only audio
  flutter_webrtc: 1.4.0                            # pins to WebRTC-SDK pod 144.7559.09
  speech_to_text:                                  # LiveKit iOS coexistence patch
    path: packages/twai_speech_to_text_patched
```

External consumers must mirror the `speech_to_text` override in their own `pubspec.yaml` — otherwise the avatar goes silent after the first mic turn on iOS. See [`docs/mic_lifecycle_ios_livekit.md`](docs/mic_lifecycle_ios_livekit.md).

---

## Mic — three transcribers ship

| Transcriber | Where it runs | Backend |
|---|---|---|
| `DefaultTranscriber()` | All targets | Browser `SpeechRecognition` on web, platform STT on native. Zero-config. |
| `BrowserSpeechTranscriber` | Web | Chrome / Edge / Safari 14.5+. Free, zero-config. |
| `SpeechToTextTranscriber` | Native | Android `SpeechRecognizer`, iOS `SFSpeechRecognizer`. |
| `HttpSttTranscriber` | Web | POSTs recorded audio to a Whisper-shaped endpoint. For teams running their own STT server. |

Verified cross-platform on web (Chrome), Android (Pixel 5a), iOS (iPhone 15).

---

## Companion repos + SDKs in other languages

- **Web / TypeScript SDK:** [`2waiorg/twai-web-sdk`](https://github.com/2waiorg/twai-web-sdk) — `@twai/core`, `@twai/player`, `@twai/mic`, `@twai/react`, `@twai/web-component`.
- **iOS native SDK (Swift):** this repo under [`ios-native/`](ios-native/). SwiftUI, SPM, iOS 15+. Device-verified on iPhone.
- **Android native SDK (Kotlin):** upon request — Flutter covers Android today from the same codebase as iOS/Web/desktop.
- **Wire protocol spec:** [`2waiorg/twai-protocol`](https://github.com/2waiorg/twai-protocol) — cross-SDK JSON Schemas + conformance vectors.

---

## Where to go next

- **Dev docs site:** [https://developers.2wai.ai/](https://developers.2wai.ai/) — authentication, quickstart, SDKs, guides, API reference, LLM prompts for Claude Code / Cursor.
- **Full code reference:** [`docs/README.md`](docs/README.md) — toolkit-orientation docs. Protocol, SDK overview, mint-proxy, integration gotchas.
- **Pick a sample:** [`apps/README.md`](apps/README.md) — pick one close to your use case and read its code end-to-end.

---

## Issues / feedback

GitHub issues on this repo reach the 2wai team. For enrollment / API-key / account questions, use the Developer Console at [2wai.ai/developers](https://2wai.ai/developers).
