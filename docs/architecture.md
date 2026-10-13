# Architecture

Internal architecture of the 2wai Toolkit's Flutter SDK, JS/TS packages, and reference apps. If you're integrating as a customer, start with the top-level [`README.md`](../README.md) and pick a sample; this doc explains the layers underneath.

> **Status (2026-09-21):** Transport 0 (LiveKit) is the sole production live-chat wire per [ADR-045 / ADR-049 (2026-08-22)](https://wiki.2wai.ai/avatar-toolkit/decisions/). SDK verified end-to-end on iPhone 15 / iOS 26.6.2 + web + Android. Historical MSE-over-WS transport is archived — `twai_avatar_sdk_web_mse` still ships for advanced consumers but is not on the main integration path. Mic (push-to-talk / tap-to-toggle) is a first-class SDK feature on iOS + web; Android has a [documented gap](mic_android_pending.md) with a proven production answer waiting for 1.0 industrialization.

---

## Two foundational principles

### 1. Content creation is central; runtime is portable

The 2wai stack has two separable layers:

| Layer | What it does | Who provides it |
|---|---|---|
| **Content creation** | The multi-stage content pipeline in [`gen-2wai`](https://github.com/2waiorg/gen-2wai) (Avatar Studio). Mints avatar assets (MuseTalk plates, source frames, voice clones, look descriptions). | **2wai central.** This is the product moat — the assets live in the pipeline and the catalog. |
| **Runtime serving** | LLM → TTS → Render → Stream. Consumes assets, produces the talking video for each turn. | **2wai (default)** — Transport 0 rooms served by the `livealman` broker profile family on box2. Customer-hosted / on-device is a future shape. |

The toolkit shipping today assumes 2wai-hosted runtime. On-device / offline runtimes are outside the current scope; the pure-Dart core stays runtime-agnostic to keep that door open.

### 2. Dual audience, single SDK

Two audiences using the same codebase:

- **2wai's own product surfaces** — Talk2Jesus, gen-2wai's Viewer, the admin tool, forthcoming internal apps.
- **Customer integrations** — Lumara (Dr. Alman in a care-team app; iOS TestFlight), Candy.ai (in progress), Jonathan's on-device build, future licensees.

**Design test:** *"does jesus / enlighten use this the same way a customer would?"* If yes, it belongs in the SDK. If it's a 2wai-internal hook, it stays in the app. Prevents drift.

---

## Package layout

Dart workspace with a single root pubspec listing all packages. Internal deps use bare package names — workspace resolution finds the local sources. No Melos.

```
2wai-toolkit/
├── pubspec.yaml                             # workspace root + dependency_overrides
├── packages/
│   ├── twai_avatar_sdk_core/                # Pure-Dart nucleus, no Flutter dep
│   ├── twai_avatar_sdk/                     # Flutter UI: widgets, Transcriber, layouts
│   ├── twai_avatar_sdk_livekit/             # Transport 0 engine (Dart port of PP's transport)
│   ├── twai_avatar_sdk_player/              # PlayerAvatar + controller + handle
│   ├── twai_avatar_sdk_video_player/        # video_player-backed sinks (native)
│   ├── twai_avatar_sdk_web_mse/             # Historical: MSE-over-WS web sink
│   ├── twai_avatar_sdk_local/               # On-device / offline chat shape
│   ├── twai_speech_to_text_patched/         # Vendored speech_to_text 7.4.0 + iOS patch
│   └── twai_web_component_t0/               # JS/TS <twai-avatar-t0> element
```

**Dependency-order narrative:**

- **`twai_avatar_sdk_core`** is pure Dart. No Flutter dep. Ships the wire types, error taxonomy, environment / credentials, `TwaiApiRestClient` (REST client for the twai-api gateway), etc. Server-side tools + CLIs pull this directly.
- **`twai_avatar_sdk_livekit`** adds Transport 0. `LiveKitEngine` is a Dart port of Penthouse Pets' production `PenthouseLiveKitTransport` — same lifecycle, same disconnect-classification, same "engine never reconnects on its own" incident-fix. Wraps `livekit_client` (pinned to 2.8.1 — see [`livekit_ios_receive_only_audio.md`](livekit_ios_receive_only_audio.md)).
- **`twai_avatar_sdk`** is the Flutter widget surface: `TwaiTransport0Player` (the drop-in widget), `TwaiMicButton`, `Transcriber` interface + impls, idle sources (`NetworkVideoIdle` / `AssetVideoIdle` / `AssetPosterIdle`), layout primitives (`TwaiSideBySideLayout` / `TwaiStackedLayout` / `TwaiImmersiveLayout`).
- **`twai_avatar_sdk_video_player`** + **`twai_avatar_sdk_web_mse`** — MSE-era sinks. Kept live but not on the main integration path. `avatar_player_lab` still uses them as a reference harness.
- **`twai_avatar_sdk_player`** — controller + handle for the layered player pattern (used by MSE-era `TwaiPlayer` widget and future T0 handle work).
- **`twai_avatar_sdk_local`** — pure-Dart on-device chat shape. Not currently wired into any T0 app.
- **`twai_speech_to_text_patched`** — vendored `speech_to_text` 7.4.0 with a Darwin-only patch that preserves an existing playback session across recognition. See [`packages/twai_speech_to_text_patched/LUMARA_PATCH.md`](../packages/twai_speech_to_text_patched/LUMARA_PATCH.md) for the exact change and [`mic_lifecycle_ios_livekit.md`](mic_lifecycle_ios_livekit.md) for the diagnosis. Referenced via `dependency_overrides` in the workspace root.
- **`twai_web_component_t0`** — JS/TS drop-in `<twai-avatar-t0>` custom element. Byte-parallel to the twai-web-sdk PR [#3](https://github.com/2waiorg/twai-web-sdk/pull/3); ships in the toolkit ahead of Mason's upstream landing.

---

## Transport 0 (LiveKit)

The wire is [documented in the wiki](https://wiki.2wai.ai/avatar-toolkit/protocol/livekit/). What the SDK provides:

### Engine layer — `twai_avatar_sdk_livekit`

Public entry: `LiveKitEngine` + factory `createAvatarSession(options)`. Six seams vs. the PP source it was ported from:

1. `createAvatarSession(options)` replaces the four-positional-argument constructor.
2. Minting is injected. The engine never fetches — hosts pass a zero-arg closure.
3. Callbacks became broadcast streams (`onSpeaking`, `onReady`, `onReplyText`, etc). Plus one additive `onTranscript` stream on the fallback path.
4. `send(text, {extra})` builds the `lk.chat` envelope engine-side.
5. Audio pathway is delegated to `livekit_client`'s own remote-audio auto-attach — the Flutter engine has no HTMLAudio element, so there is no two-sink mode.
6. Observable `state` via `ValueListenable<EngineState>`.

**Load-bearing behaviors that must NOT be "cleaned up":**

- `_closeRoom` sets `_closed = true` BEFORE `room.disconnect()`, so the room's own `Disconnected` handler finds the session already closed and does not re-enter.
- **The engine NEVER reconnects on its own.** It classifies the ending (`agentEnded` vs `transportEnded`), emits `ended`, and stops. What happens next is host policy — see the Lumara reconnect discipline pattern in `apps/mmm_demo/lib/product_chat_screen.dart` for the reference shape.
- `adaptiveStream: false, dynacast: false`. A surface that fades the video element to opacity 0 between replies would otherwise have its subscription paused by adaptiveStream, stalling exactly when the next reply arrives.
- The reply protocol (`2wai.reply` topic) supersedes fallback transcription (`sawProtocol` latch); expression tags are stripped on both paths.

### Widget layer — `twai_avatar_sdk`

Public entry: `TwaiTransport0Player`. Consumer passes a mint closure + an idle builder; the widget wraps the engine lifecycle, exposes typed callbacks (`onEngine`, `onState`, `onSpeaking`, `onReplyText`, `onReplyComplete`, `onEnded`, `onError`, ...), and handles the idle → speaking crossfade.

Two idle behaviors ship out of the box:
- Video-loop idles (`NetworkVideoIdle`, `AssetVideoIdle`) — one clip, looped continuously via `setLooping(true)`.
- Poster idles (`NetworkPosterIdle`, `AssetPosterIdle`) — a static image when no idle video is available.

Multi-clip idle rotation (per-turn) is a documented [future feature](two_element_audio_design_pass.md), not shipped.

### Mint proxy pattern (split-plane)

The toolkit does not ship an SDK-level `sk_` gateway client. Instead, mint proxies are reference shapes under `apps/mint_proxy_examples/` (Node, Python/FastAPI, Cloudflare Worker). Customer runs the proxy server-side (holds `sk_` in `.env`); browser / mobile client uses `AnonymousCredentials` and hits the proxy for short-lived LiveKit tokens.

---

## Mic surface

`TwaiMicButton` widget + `Transcriber` interface. The button handles the gesture (tap-to-toggle by default, push-to-talk optional) and drives an injected `Transcriber`; consumers wire the transcript to `engine.send()`.

```dart
TwaiMicButton(
  transcriber: DefaultTranscriber(),  // conditional cross-platform factory
  enabled: ready && !_speaking,       // mic-feedback mitigation (see below)
  onTranscript: (text) => _engine.send(text),
  gesture: TwaiMicGesture.tapToToggle, // default; pushToTalk also available
)
```

### Transcribers

| Impl | Platform | Backend |
|---|---|---|
| `BrowserSpeechTranscriber` | Web | `dart:js_interop` wrap of the browser `SpeechRecognition` API |
| `SpeechToTextTranscriber` | Android / iOS / macOS / Windows | `speech_to_text` plugin (patched, see below) |
| `DefaultTranscriber()` | All | Conditional factory — resolves to the two above per build target. **Zero-config, no server dep.** The default across all shipped demos |
| `HttpSttTranscriber` | Web (V1); native stub | Blob-per-turn POST to a Whisper-shaped endpoint; the `STT_URL`-set path when a consumer has a server-hosted Whisper endpoint |
| Customer-implemented | Anywhere | Implement `Transcriber` interface; plug in |

### iOS + LiveKit coexistence

The load-bearing detail: `AVAudioSession` is process-wide on iOS. Upstream `speech_to_text` calls `setActive(false)` on stop, which tears down LiveKit's playout unit. Symptom: avatar goes silent after the first mic turn.

Fix: workspace ships a vendored `speech_to_text` 7.4.0 with a Darwin patch (`packages/twai_speech_to_text_patched/`) that preserves the audio session when the pre-recognition category indicates a media session was already active. Category-based check runs implicitly — no Dart-side API change; standalone `speech_to_text` apps retain original behavior. Full diagnosis: [`mic_lifecycle_ios_livekit.md`](mic_lifecycle_ios_livekit.md).

Also open: [upstream PR #681](https://github.com/csdcorp/speech_to_text/pull/681) proposing the same fix as an opt-in `SpeechListenOptions.preserveExistingAudioSession` flag. When merged and released, the vendored copy can be removed.

### Android status

**Cross-platform mic verified 2026-10-01** on web (Chrome), Android (Pixel 5a), and iOS (iPhone 15) with the zero-config `DefaultTranscriber()` path. Enlighten (Dr. Alman) is the simplest reference.

Historical note: `SpeechToTextTranscriber` on Android in LiveKit-active contexts has been reported to intermittently drop transcripts — mic capture visually engages but transcripts miss. Root-cause theory (documented in [`mic_android_pending.md`](mic_android_pending.md)): `AudioManager.mode` gets flipped to `MODE_IN_COMMUNICATION` by something in the LiveKit init path, and `SpeechRecognizer` silently drops results in that mode. The diagnostic recipe there stands for consumers who hit it. Jim's physical-device testing on Pixel 5a (2026-10-01) did not reproduce it with tap-to-toggle gesture + ambient-quiet-room conditions.

The actual Android regression most consumers encountered — and the one that was documented as "idle doesn't return between turns" — was a Flutter platform-view compositor issue in `TwaiTransport0Player`, not a mic issue. Fixed by wrapping the speaking layer in `Visibility(maintainState: true)` outside the existing `AnimatedOpacity`, with a delayed hide via `Timer(fadeDuration)` after `onSpeaking(active: false)` fires. The `VideoTrackRenderer` platform view keeps a paintable surface under `AnimatedOpacity(0)` on Android; `Visibility` is what actually stops the compositor from painting it. Web + iOS composite correctly through opacity alone, so the fix is a no-op there.

### Mic-feedback mitigation

`TwaiMicButton.enabled` should be gated on `!_speaking` (avatar-speaking state) so the mic isn't hot while the avatar's audio is playing. Consumer tracks this via `onSpeaking` callback on `TwaiTransport0Player`. Combined with push-to-talk (or tap-to-toggle in a scrollable composer), this covers the hot-mic feedback loop the wiki flagged.

---

## Pinned dependencies (workspace-wide)

Two pins are load-bearing on iOS + one for cross-cutting mic behavior. All configured in the workspace root `pubspec.yaml`:

```yaml
dependency_overrides:
  livekit_client: 2.8.1          # newer versions kill iOS receive-only audio
  flutter_webrtc: 1.4.0          # needs WebRTC-SDK pod 144.7559.09
  speech_to_text:                # LiveKit iOS coexistence patch
    path: packages/twai_speech_to_text_patched
```

### Why `livekit_client 2.8.1`

`livekit_client 2.9.0` introduced "engine-driven native lifecycle" `AudioManager` that activates the iOS `AVAudioSession` from the audio-engine lifecycle — engine only starts when a mic track is published. Our avatars are receive-only, so the engine never starts, the session never activates, decoded remote audio has an active track but no active output → silence. Reverted to 2.8.1 (Lumara-verified shape) after a false-start `AudioManager.setAudioSessionOptions(mediaPlayback())` attempt didn't work. Full story: [`livekit_ios_receive_only_audio.md`](livekit_ios_receive_only_audio.md).

### Why `flutter_webrtc 1.4.0`

Companion to `livekit_client 2.8.1` — needs WebRTC-SDK pod `144.7559.09` which the older flutter_webrtc supplies. Newer flutter_webrtc versions pull in incompatible pod versions.

### Why vendored `speech_to_text`

See [Mic surface](#mic-surface) above.

---

## Platform notes

### Web

Full support. Uses `BrowserSpeechTranscriber` for mic (free, browser API); `livekit_client`'s web path for audio; Flutter Web's canvas rendering for video via `VideoTrackRenderer`. `HttpSttTranscriber` also available for consumers who want server-side Whisper transparency across Chrome/Brave (Brave silently strips SpeechRecognition keys).

### iOS

Full support, verified iPhone 15 / iOS 26.6.2 on 2026-09-17. All Info.plist entries required — `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSCameraUsageDescription` (`flutter_webrtc` links the camera API even receive-only; iOS TCC hard-kills the app without a usage string). Dev-only apps also need `NSAppTransportSecurity` `NSAllowsArbitraryLoads` for LAN mint proxies over plain HTTP.

Standard refresh after dep changes:

```bash
flutter clean && flutter pub get
cd ios && rm -rf Pods Podfile.lock && pod install --repo-update
```

### Android

Video + engine + speaker route: working. **Mic + STT: unresolved gap in LiveKit-active contexts** — see [`mic_android_pending.md`](mic_android_pending.md).

`AndroidManifest.xml` needs:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

### Windows / macOS / Linux

Not the main integration target today. Historical MSE-era `MediaKitMseStreamSink` was removed in Phase E (2026-09-18). If a customer needs desktop, the T0 engine works cross-platform; test on the specific target and file gaps.

---

## Reference apps — where to lift patterns from

| App | Lift for |
|---|---|
| [`apps/enlighten/lib/main.dart`](../apps/enlighten/lib/main.dart) | Canonical customer-shape T0 app — iPhone-verified reference |
| [`apps/mmm_demo/lib/product_chat_screen.dart`](../apps/mmm_demo/lib/product_chat_screen.dart) | Lumara-shape reconnect discipline (`_reconnectToken`, `_pendingUserText`, `_engineReady` tracked separately from `_engine != null`, `_reconnect()` remount) |
| [`apps/candy_demo/lib/main.dart`](../apps/candy_demo/lib/main.dart) | BYO-brain mint-proxy pattern (Option β) |
| [`apps/hello_avatar/lib/main.dart`](../apps/hello_avatar/lib/main.dart) | Minimum-viable T0 embed — one screen, one player, one send |
| [`apps/twai_api_demo/lib/main.dart`](../apps/twai_api_demo/lib/main.dart) | Raw wire, ZERO SDK deps — for understanding what the SDK abstracts |
| [`apps/embed/lib/main.dart`](../apps/embed/lib/main.dart) | Flutter → `<twai-avatar>` web-component; imperative JS bridge |

---

## Conformance

Cross-language wire conformance is enforced via `2waiorg/twai-protocol` — JSON Schemas + golden vectors + a runner. The Dart implementation of the runner lives at [`packages/twai_avatar_sdk_livekit/test/livekit_conformance_test.dart`](../packages/twai_avatar_sdk_livekit/test/livekit_conformance_test.dart) and covers the seven LiveKit vector files (123 scenarios total: mint-cases, reply-stream, lifecycle-cases, speaking-timeline, retry-policy, session-data, envelope). CI runs these on every PR — non-bypassable.

The Dart runner shares the exact vector shape with the JS runner in `twai-web-sdk/conformance/`, so bugs found in either language surface a wire-level fault that both need to fix.

---

## Out of scope (recorded so we don't drift)

- **Native iOS / Android SDKs (Swift / Kotlin).** Flutter is the multi-platform answer; Swift / Kotlin only if a customer explicitly asks and Flutter can't satisfy.
- **Gamification, paywall, outfit / gesture systems.** Penthouse-specific; live in customer apps.
- **End-user account management.** Host app provides a `userId` and passes it through. The SDK has no notion of user identity beyond what the host hands it. Developer auth (your `sk_` and tenant provisioning) is handled through [2wai.ai/developers](https://2wai.ai/developers) — separate from consumer auth.
- **Server-side inference or content pipeline access.** The runtime is 2wai-central today; customer-hosted / on-device runtimes are a separate scope.

---

## Related

- [Top-level `README.md`](../README.md) — quickstart + package tree + sample chooser
- [`livekit_ios_receive_only_audio.md`](livekit_ios_receive_only_audio.md) — iOS `livekit_client 2.8.1` pin story
- [`mic_lifecycle_ios_livekit.md`](mic_lifecycle_ios_livekit.md) — vendored `speech_to_text` patch
- [`mic_android_pending.md`](mic_android_pending.md) — Android mic gap + production answer
- [`two_element_audio_design_pass.md`](two_element_audio_design_pass.md) — Mason's `53d840d` review (no port needed)
- Wiki: [`wiki.2wai.ai/avatar-toolkit/`](https://wiki.2wai.ai/avatar-toolkit/) — full architecture, integration shapes, decisions
