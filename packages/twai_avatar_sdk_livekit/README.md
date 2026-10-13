# twai_avatar_sdk_livekit

Transport 0 (LiveKit) engine + widget for the 2wai Avatar Toolkit. This is where the T0 wire lives.

The engine is a Dart port of Penthouse Pets' production `PenthouseLiveKitTransport` — same lifecycle, same disconnect classification, same "engine never reconnects on its own" incident fix. Wraps [`livekit_client`](https://pub.dev/packages/livekit_client) (pinned to `2.8.1` in the workspace root for iOS receive-only audio support).

## Usage

Typical consumer pattern (see [`apps/enlighten/lib/main.dart`](../../apps/enlighten/lib/main.dart) for the reference implementation):

```dart
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

// Mint closure — called by the widget on connect + reconnect.
Future<t0.MintResult> mint() async {
  try {
    final r = await rest.createLiveKitSession(
      TwaiApiLiveKitSessionRequest(avatarId: 'avt_...'),
    );
    return t0.MintResultEnabled(
      url: r.livekitUrl.toString(),
      token: r.participantToken,
      room: r.roomName,
    );
  } on TwaiApiRateLimitedException catch (e) {
    throw t0.MintRateLimited(e.retryAfterSeconds ?? 60);
  } catch (e) {
    throw t0.MintUnavailable('gateway mint failed: $e', cause: e);
  }
}

// Drop the widget in.
t0.TwaiTransport0Player(
  mint: mint,
  idleBuilder: (ctx) =>
      NetworkVideoIdle(Uri.parse('https://.../idle.mp4')).build(ctx),
  onEngine: (e) => setState(() => _engine = e),
  onState: (s) => setState(() => _engineState = s),
  onSpeaking: (e) => setState(() => _speaking = e.active),
  onReplyText: (e) => print('avatar: ${e.text}'),
);
```

## What's in here

- **`LiveKitEngine`** — the port of PP's transport. Public entry via factory `createAvatarSession(options)`. Six seams from the JS source: injected mint closure, event streams (not callbacks), engine-side envelope building, observable `state`, one additive `transcript` event, `AvatarSessionMedia.audio` optional (single-element mode).
- **`TwaiTransport0Player`** — Flutter widget wrapping the engine lifecycle. Consumer passes a mint closure + idle builder + typed callbacks; widget handles the idle → speaking crossfade and lifecycle events.
- **`LiveKitEngineMedia`, `LiveKitEngineOptions`, `MintResult`, `EngineState`, `EngineEvents`** — the engine's public surface.
- **`LiveKitRoomLifecycle`** — host-side reconnect policy helper (port of PP's `roomLifecycle`). The engine deliberately does NOT reconnect on its own; hosts pick their policy.
- **`ReplyStreamReducer`** — port of the shared `2wai.reply` reducer. Assembles start / delta / end frames into displayable text; strips expression tags.
- **`stripExpressionTags`** — the direction-tag strip. Kept mechanically parallel to `twai-web-sdk/packages/core/src/replyStream.ts` and `avatar-brain/src/core/expression.py`.

## Load-bearing behaviors

- **Engine never reconnects on its own.** It classifies the ending (`agentEnded` vs `transportEnded`), emits `ended`, and stops. Host policy owns what happens next. This is the incident-fix from PP — an auto-reconnecting client once opened 864 sessions in 48 hours.
- **`adaptiveStream: false, dynacast: false`.** A surface that fades the video element to opacity 0 between replies would otherwise have its subscription paused by adaptiveStream, stalling exactly when the next reply arrives.
- **`_closeRoom` sets `_closed = true` BEFORE `room.disconnect()`.** The room's own `Disconnected` handler must find the session already closed and not re-enter.
- **Reply protocol supersedes fallback transcription.** `sawProtocol` latch prevents double-publishing when both channels fire.

## iOS pin

`livekit_client 2.8.1` + `flutter_webrtc 1.4.0` are load-bearing on iOS. Newer versions ship an "engine-driven native lifecycle" `AudioManager` that only activates the iOS `AVAudioSession` when a microphone track is published — since our avatars are receive-only, the engine never starts and remote audio decodes to silence. Full diagnosis: [`docs/livekit_ios_receive_only_audio.md`](../../docs/livekit_ios_receive_only_audio.md).

Consumers using this package outside the toolkit workspace must add the same pins in their own `pubspec.yaml`.

## Conformance

Cross-language wire conformance runs against the shared vectors in [`2waiorg/twai-protocol`](https://github.com/2waiorg/twai-protocol). The Dart runner lives at [`test/livekit_conformance_test.dart`](test/livekit_conformance_test.dart) — 7 vector files, 123 scenarios total. Runs on every CI build.

## Related

- [`twai_avatar_sdk`](../twai_avatar_sdk/) — the Flutter UI surface (widgets + Transcriber). Depends on this package.
- [`twai_avatar_sdk_core`](../twai_avatar_sdk_core/) — pure-Dart nucleus.
- [Toolkit architecture](../../docs/architecture.md).
- [Wire protocol spec](https://wiki.2wai.ai/avatar-toolkit/protocol/livekit/).
