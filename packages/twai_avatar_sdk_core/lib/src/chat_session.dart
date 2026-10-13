import 'dart:async';
import 'dart:typed_data';

import 'adapters/mse_stream/mse_stream_config.dart' show SpeakingEvent;
import 'errors.dart';

/// A talking-head avatar a session can connect to. Both transports map
/// `id` to their backend's avatar slug and `voiceId` to their voice
/// reference (when supplied).
class Avatar {
  /// Backend avatar id / slug — e.g. `'RedJesusTalk2'` (MSE) or
  /// `'sophi'` (v1.3).
  final String id;

  /// Optional voice override. UUID for Adapter 1; ElevenLabs id /
  /// voice slug for Adapter 2. When `null`, the backend default is used.
  final String? voiceId;

  const Avatar({required this.id, this.voiceId});
}

/// User-facing chat session interface. Wraps a backend transport behind
/// one shape so app code is transport-agnostic.
///
/// Concrete implementations:
/// - [MseStreamChatSession] — Adapter 1 (penthouse MSE-over-WS)
/// - [PipelineV13ChatSession] — Adapter 2 (v1.3 `POST /chat` → MP4)
abstract class ChatSession {
  /// Open the session and bind to [avatar].
  ///
  /// For Adapter 1 this opens the WS and sends the handshake. For
  /// Adapter 2 this is a local-only configuration step (no network).
  ///
  /// Throws [ChatSessionAlreadyConnectedException] on second call.
  /// Throws [ChatSessionConnectException] on transport failure.
  Future<void> connect(Avatar avatar);

  /// Send a chat turn.
  ///
  /// On success: the reply text arrives on [replyText]; video bytes
  /// arrive on [videoBytes]; speaking-state transitions arrive on
  /// [speakingEvents] (Adapter 1 only); the brain-inferred mood for
  /// this turn (if any) arrives on `moodEvents` on the concrete
  /// [MseStreamChatSession] (Adapter 1 only — Adapter 2 has no mood path).
  ///
  /// Optional per-turn brain-context fields, both surfaced through the
  /// Adapter 1 `POST /ext-api/human` body (Patch #70, r14). Adapter 2
  /// ignores them (server doesn't accept). `null` = field omitted from
  /// the request, brain defaults apply (Trust Stage 1, no extra context).
  /// - [gamificationLevel] — numeric per-(user, avatar) level.
  /// - [avatarStateBlock] — opaque mood / pose / outfit context forwarded
  ///   to the brain unchanged.
  ///
  /// Throws [ChatSessionNotConnectedException] if [connect] hasn't run.
  /// Throws [ChatSessionSendException] on transport / protocol failure.
  /// A failed send does **not** end the session — retry-after-failure
  /// is supported.
  Future<void> sendMessage(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  });

  /// LLM reply text — one emit per [sendMessage] turn.
  Stream<String> get replyText;

  /// Speaking-state transitions with playback timestamps.
  ///
  /// **Adapter 1:** real-time server events with `pts` matching the WS
  /// video timeline. UI must gate transitions on `playbackTime >= pts`,
  /// not event receipt.
  ///
  /// **Adapter 2:** empty stream — the consumer's video player drives
  /// the state directly.
  Stream<SpeakingEvent> get speakingEvents;

  /// Raw video bytes.
  ///
  /// **Adapter 1:** fragmented MP4 (init segment first, then media
  /// segments). Feed into MediaSource / equivalent.
  ///
  /// **Adapter 2:** one complete MP4 per [sendMessage] turn. Play via
  /// `package:video_player`.
  Stream<Uint8List> get videoBytes;

  /// Emitted after each internally-initiated `/speak` call to the
  /// gateway completes. Semantics:
  ///
  /// - Single-shot brain / echo mode: one emit per [sendMessage] turn.
  /// - Streaming brain (Adapter 4 with per-sentence `speak` closure):
  ///   one emit per clause the brain spoke.
  /// - Adapter 1 (server-owned brain) / Adapter 2 (POST /chat → MP4):
  ///   empty stream — those adapters have no SDK-driven `/speak`.
  ///
  /// Purpose: native "accumulate-then-play" sinks
  /// ([VideoPlayerMseStreamSink], [MediaKitMseStreamSink]) use this as
  /// a "hurry the tail-window seal" hint. When a boundary arrives with
  /// a pending post-`speaking:stop` tail timer, the sink fires the
  /// timer immediately — the next clause's bytes are about to start,
  /// so there's no reason to wait the full silence budget. On web,
  /// [WebMseStreamSink] tail-follows into a live `SourceBuffer` and
  /// ignores this stream (nothing to seal).
  ///
  /// Consumers of the [ChatSession] surface at the app layer typically
  /// don't need this — it's an SDK-internal timing signal for sinks.
  Stream<void> get speakBoundaries;

  /// Resolves when the session ends — by [close], by server-initiated
  /// close, or by transport failure.
  Future<ChatSessionEndReason> get done;

  /// Close the session and release transport resources.
  Future<void> close();
}

/// Why the session ended.
sealed class ChatSessionEndReason {
  final String message;
  const ChatSessionEndReason(this.message);

  /// Should the consumer attempt to reconnect? `false` for permanent
  /// failures (server-side bugs, config errors); `true` for clean
  /// closes and transient transport issues.
  bool get canReconnect;

  @override
  String toString() => '$runtimeType($message)';
}

/// Clean close — either initiated by the app via [ChatSession.close] or
/// by the server with a normal close code.
class ChatSessionClosed extends ChatSessionEndReason {
  const ChatSessionClosed([super.message = 'closed']);
  @override
  bool get canReconnect => true;
}

/// Session ended due to a failure.
///
/// [isPermanent] = true means the same configuration / server state
/// would fail again (e.g. WS close code 1002 / 1011); false means a
/// retry might succeed (network glitch, etc).
class ChatSessionFailed extends ChatSessionEndReason {
  final bool isPermanent;
  final Object? cause;
  const ChatSessionFailed(super.message, {this.isPermanent = false, this.cause});
  @override
  bool get canReconnect => !isPermanent;
}

/// Base exception type for all `ChatSession`-level call failures.
///
/// Implements [TwaiError] so consumers can switch on [kind] uniformly
/// across every SDK exception hierarchy (Chat, Gateway, Admin, Gen)
/// without importing each package's specific types. Subclasses
/// override [kind] to categorize themselves.
sealed class ChatSessionException implements Exception, TwaiError {
  @override
  final String message;
  @override
  final Object? cause;
  const ChatSessionException(this.message, [this.cause]);

  @override
  TwaiErrorKind get kind => TwaiErrorKind.unknown;

  @override
  String toString() =>
      cause == null ? '$runtimeType: $message' : '$runtimeType: $message (cause: $cause)';
}

/// Caller invoked [ChatSession.sendMessage] before [ChatSession.connect],
/// or after the session ended.
class ChatSessionNotConnectedException extends ChatSessionException {
  const ChatSessionNotConnectedException()
      : super('Session is not connected — call connect() first');
  // Caller misuse — no wire-level failure. Kind stays `unknown`.
}

/// Caller invoked [ChatSession.connect] twice on the same instance.
class ChatSessionAlreadyConnectedException extends ChatSessionException {
  const ChatSessionAlreadyConnectedException()
      : super('Session is already connected');
}

/// Transport-level failure during [ChatSession.connect].
class ChatSessionConnectException extends ChatSessionException {
  const ChatSessionConnectException(super.message, [super.cause]);
  @override
  TwaiErrorKind get kind => TwaiErrorKind.connect;
}

/// Transport / protocol failure during [ChatSession.sendMessage].
/// The session remains open — the caller may retry.
class ChatSessionSendException extends ChatSessionException {
  const ChatSessionSendException(super.message, [super.cause]);
  @override
  TwaiErrorKind get kind => TwaiErrorKind.chat;
}

/// HTTP 401 surfaced from sendMessage — missing or invalid publishable
/// key. Retrying with the same key won't help; the customer must rotate
/// or correct it.
class ChatSessionUnauthorizedException extends ChatSessionSendException {
  const ChatSessionUnauthorizedException([
    super.message = 'Unauthorized: missing or invalid publishable key',
    super.cause,
  ]);
  @override
  TwaiErrorKind get kind => TwaiErrorKind.unauthorized;
}

/// HTTP 403 surfaced from sendMessage — key valid but lacks scope (e.g.
/// avatar belongs to a different tenant, or key is admin-only).
class ChatSessionForbiddenException extends ChatSessionSendException {
  const ChatSessionForbiddenException([
    super.message = 'Forbidden: key lacks scope for this avatar',
    super.cause,
  ]);
  @override
  TwaiErrorKind get kind => TwaiErrorKind.unauthorized;
}

/// HTTP 429 surfaced from sendMessage — quota exhausted. Distinct from
/// Unauthorized because retries after the rate-limit window succeed.
class ChatSessionRateLimitedException extends ChatSessionSendException {
  const ChatSessionRateLimitedException([
    super.message = 'Rate limited: publishable key over quota',
    super.cause,
  ]);
  // Rate-limit is a chat/backend-level rejection, not an auth failure.
  // Kind stays `chat` from the parent.
}
