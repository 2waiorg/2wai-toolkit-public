/// Convenience helpers so consumer apps don't have to know the exact
/// wiring between `TwaiPlayerHandle` + `LiveKitChatSession` +
/// `LiveKitVideoSink`.
///
/// # Consumer shape
///
/// ```dart
/// final rest = TwaiApiRestClient(
///   baseUrl: Uri.parse('http://localhost:8787'),   // mint proxy
///   credentials: const AnonymousCredentials(),
/// );
///
/// final handle = createLiveKitHandle(
///   avatar: drAlman,
///   restClient: rest,
///   userId: 'my-signed-in-user-42',   // stable brain memory
/// );
///
/// TwaiPlayer(
///   controller: handle,
///   avatar: drAlman,
///   sinkFactory: liveKitSinkFactory(),
/// );
/// ```
///
/// The helpers are pure sugar over the primitives; passing
/// `sessionFactory` + `sinkFactory` directly to the underlying
/// widgets works identically.
library;

import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import 'livekit_chat_session.dart';
import 'livekit_video_sink.dart';

/// Build a [TwaiPlayerHandle] wired for LiveKit (Adapter 5).
///
/// Under the hood: `sessionFactory` returns a [LiveKitChatSession]
/// bound to [restClient]; `userId` is forwarded to the gateway as the
/// brain-scoped identity (null = per-session synthetic, no cross-turn
/// memory).
///
/// Penthouse-side auto-behaviors (gestures / frames / progress / XP /
/// state-block / record-reply) are all disabled — the twai-api gateway
/// doesn't expose them and hitting them per turn would log 404s. Same
/// discipline as [TwaiPlayerHandle.forApiSession].
/// !! Important: for LiveKit, the caller MUST pass a `config` with
/// `resumeRecovery` set to something long (>= 30 minutes). The
/// controller's watchdog fires at [PlayerConfig.resumeRecovery] when
/// no video BYTES arrive -- but LiveKit rides a WebRTC track, so
/// [LiveKitChatSession.videoBytes] is intentionally empty. Without
/// the bump the watchdog closes the session with "resume recovery
/// timeout" in 5s. See lab_shell.dart::_buildHandleFor for the
/// working pattern.
TwaiPlayerHandle createLiveKitHandle({
  required PlayerAvatar avatar,
  required TwaiApiRestClient restClient,
  String? userId,
  PlayerOutfit? outfit,
  PlayerConfig? config,
  bool autoConnect = true,
  TwaiEnvironment? env,
}) {
  return TwaiPlayerHandle(
    avatar: avatar,
    outfit: outfit,
    env: env,
    config: config,
    autoConnect: autoConnect,
    sessionFactory: () => LiveKitChatSession(
      restClient: restClient,
      userId: userId,
    ),
    // twai-api tenant model doesn't expose these paths -- same defaults
    // as forApiSession.
    autoFetchGestures: false,
    autoFetchFrames: false,
    autoFetchProgress: false,
    autoAwardXp: false,
    autoFetchStateBlock: false,
    autoRecordReply: false,
  );
}

/// Build a `sinkFactory` closure suitable for [TwaiPlayer.sinkFactory]
/// on a handle produced by [createLiveKitHandle]. The sink needs the
/// controller reference to read `currentSession` — TwaiPlayer wraps
/// the real ChatSession behind a private shim before calling
/// sink.attach(), which strips the WebRTC-specific videoTrackStream.
TwaiSinkFactory liveKitSinkFactory() =>
    (controller) => LiveKitVideoSink(controller: controller);
