# twai_avatar_sdk

The Flutter UI surface for the 2wai Avatar Toolkit — widgets, `Transcriber` interface + implementations, idle sources, layout primitives, and the `TwaiMicButton` mic control. Pure Flutter; consumes the pure-Dart nucleus at [`twai_avatar_sdk_core`](../twai_avatar_sdk_core/) and the Transport 0 engine at [`twai_avatar_sdk_livekit`](../twai_avatar_sdk_livekit/).

This is the umbrella package customers import in a Transport 0 app.

## Usage

```dart
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

t0.TwaiTransport0Player(
  mint: myMintClosure,
  idleBuilder: (ctx) =>
      NetworkVideoIdle(Uri.parse('https://.../idle.mp4')).build(ctx),
  onSpeaking: (e) => setState(() => _speaking = e.active),
  // ... other callbacks
);

TwaiMicButton(
  transcriber: DefaultTranscriber(),
  enabled: ready && !_speaking,
  onTranscript: (text) => _engine.send(text),
);
```

Full working reference: [`apps/enlighten/lib/main.dart`](../../apps/enlighten/lib/main.dart) — verified on iPhone 15 / iOS 26.6.2.

## What ships in this package

**Widgets**
- `TwaiMicButton` — mic control (tap-to-toggle default, push-to-talk optional)
- `TwaiThemedChatPanel`, `TwaiTextureOverlay`, `TwaiVignette`, `TwaiGildedRule` — themed chat surface primitives
- `TwaiSideBySideLayout`, `TwaiStackedLayout`, `TwaiImmersiveLayout` — layout primitives
- `TwaiSceneStage`, `TwaiSceneNavigator`, scene stitching primitives — for immersive multi-scene experiences
- `TwaiConnectionOverlay`, `TwaiCinematicPlayer` — connection status + full-viewport cinematic clips
- `TwaiChatAutoScroller`, `TwaiKeyboardShortcutsOverlay` — chat UX primitives
- `TwaiDebugOverlay` — Flutter port of Mason's `?diag=1` diagnostic HUD
- `TwaiWireRecorder` — port of Mason's `?review=1` fMP4 recorder

**Transcribers**
- `Transcriber` — the interface. Consumer swaps in their own for backend STT
- `DefaultTranscriber()` — conditional cross-platform factory (browser SpeechRecognition on web, `speech_to_text` on native)
- `BrowserSpeechTranscriber` — direct `dart:js_interop` wrap of browser `SpeechRecognition`
- `SpeechToTextTranscriber` — wraps `speech_to_text` plugin (native STT)
- `HttpSttTranscriber` — POSTs recorded audio to a Whisper-shaped endpoint (web-only V1)

**Idle sources**
- `NetworkVideoIdle`, `AssetVideoIdle`, `NetworkPosterIdle`, `AssetPosterIdle`, `SolidColorIdle`, `NoIdle`, `TransparentVideoIdle`

**Per-avatar theming**
- `PlayerAvatarTheme` value type + `PlayerAvatarThemeScope` inherited widget

**Legacy MSE-era widgets** (kept alive for existing consumers; new apps should use Transport 0)
- `TwaiPlayer` — the pre-T0 player widget wrapping `TwaiPlayerHandle` + `TwaiAvatarPlayerStage`
- `TwaiAvatarStage`, `TwaiAvatarPlayerStage`

## Mic + iOS + LiveKit

The `SpeechToTextTranscriber` on iOS depends on the workspace's vendored `speech_to_text` patch at [`packages/twai_speech_to_text_patched`](../twai_speech_to_text_patched/) — the root `pubspec.yaml` `dependency_overrides` swaps it in. Without that override, the avatar goes silent after the first mic turn (upstream `speech_to_text` calls `AVAudioSession.setActive(false)` on stop, which tears down LiveKit's playout unit).

Full story: [`docs/mic_lifecycle_ios_livekit.md`](../../docs/mic_lifecycle_ios_livekit.md).

**Android mic** verified working 2026-10-01 on physical Pixel 5a with the zero-config `DefaultTranscriber()` path. A historical silent-drop symptom in LiveKit-active contexts is documented in [`docs/mic_android_pending.md`](../../docs/mic_android_pending.md) with a diagnostic recipe for consumers who hit it.

## Related

- [`twai_avatar_sdk_core`](../twai_avatar_sdk_core/) — pure-Dart protocol nucleus
- [`twai_avatar_sdk_livekit`](../twai_avatar_sdk_livekit/) — Transport 0 engine + widget
- [Toolkit README](../../README.md) + [architecture](../../docs/architecture.md)
