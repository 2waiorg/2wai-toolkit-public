/// The engine contract surface — spec §6, Dart port of
/// `packages/core/src/engineTypes.ts` on twai-web-sdk
/// `feat/livekit-engine`.
///
/// Pure types plus the mint + send error hierarchy: no transport, no
/// widget code, no runtime behaviour beyond the [Error] subclasses. The
/// engine, its hosts, and the conformance vectors all name these
/// shapes, so changing one is a contract change rather than a refactor.
///
/// Provenance: event payloads are the callback set PP's lean
/// `livekit_transport.ts` already hands its controller;
/// [MintRateLimited] is that file's `LiveKitTokenRateLimitError`
/// promoted into the shared taxonomy. `transcript` is additive — no PP
/// callback counterpart.
library;

// Reuse the reducer's terminal-kind enum from the existing (soon to be
// orphaned) LiveKit code — same protocol, same values, same 26
// conformance scenarios that guard it.
import '../reply_stream.dart' show ReplyTerminalKind;
export '../reply_stream.dart' show ReplyTerminalKind;

/// Result of a successful mint call — either the room to join, or an
/// explicit "chat is off here" verdict.
sealed class MintResult {
  const MintResult();
}

class MintResultEnabled extends MintResult {
  final String url;
  final String token;
  final String room;

  const MintResultEnabled({
    required this.url,
    required this.token,
    required this.room,
  });
}

class MintResultDisabled extends MintResult {
  const MintResultDisabled();
}

/// The engine's observable state.
///
/// - `idle`: pre-connect, or after a failed / disabled mint.
/// - `minting`: host's mint closure in flight.
/// - `joining`: from `warming` event fire until the agent is seen.
/// - `warming`: agent here, renderer has not painted yet.
/// - `ready`: settle window elapsed with the room still live.
/// - `ended`: teardown has begun; the session is not reusable.
enum EngineState { idle, minting, joining, warming, ready, ended }

// ─── Event payloads ────────────────────────────────────────────

class WarmingEvent {
  final String room;
  const WarmingEvent({required this.room});
}

class ReadyEvent {
  final String room;
  const ReadyEvent({required this.room});
}

class SpeakingActiveEvent {
  final bool active;
  const SpeakingActiveEvent({required this.active});
}

class ReplyStartEvent {
  final String replyId;
  const ReplyStartEvent({required this.replyId});
}

class ReplyTextEvent {
  final String replyId;
  final String text;
  const ReplyTextEvent({required this.replyId, required this.text});
}

class ReplyCompleteEvent {
  final String replyId;
  final String text;
  final ReplyTerminalKind kind;
  const ReplyCompleteEvent({
    required this.replyId,
    required this.text,
    required this.kind,
  });
}

class ControlEvent {
  final Map<String, Object?> event;
  const ControlEvent({required this.event});
}

class TranscriptEvent {
  final String participant;
  final String text;
  final bool finalChunk;
  const TranscriptEvent({
    required this.participant,
    required this.text,
    required this.finalChunk,
  });
}

enum EndedCause { agentEnded, transportEnded }

class EndedEvent {
  final EndedCause cause;
  const EndedEvent({required this.cause});
}

enum NoticeKind { sessionsBusy, rendererTimeout }

class NoticeEvent {
  final NoticeKind kind;
  const NoticeEvent({required this.kind});
}

// ─── Error hierarchy ───────────────────────────────────────────

/// Narrowing discriminant for the mint errors. Prefer this over
/// `is`/`runtimeType`, which are ambiguous across duplicate copies of
/// the package.
enum MintErrorKind { mintRateLimited, mintUnavailable }

/// 429 from mint. **Terminal**: hosts show the wait and MUST NOT
/// auto-retry (the server-side silent-session guard depends on this —
/// spec §6.2).
class MintRateLimited implements Exception {
  final MintErrorKind kind = MintErrorKind.mintRateLimited;
  final int retryAfterSeconds;

  MintRateLimited(int retryAfterSecondsInput)
      // Retry-After arrives off a header, so absent / garbage is the
      // normal case. Clamp here rather than at each call site so a
      // host can render this directly and never show "retry after
      // NaNs"; a zero or negative wait can never be read as "retry
      // immediately".
      : retryAfterSeconds = (retryAfterSecondsInput > 0 &&
                retryAfterSecondsInput.isFinite)
            ? retryAfterSecondsInput
            : 60;

  @override
  String toString() =>
      'MintRateLimited: mint rate limited; retry after ${retryAfterSeconds}s';
}

/// `send()` on a session whose renderer has not painted yet.
///
/// Typed for the same reason the mint errors are: hosts branch on kind
/// to tell "too early, the room is still warming" apart from "the send
/// failed" without matching on an English message.
///
/// **Not a mint error**: no `retryAfterSeconds`, no `detail` — the
/// remedy is neither a wait nor an explanation, it is the `ready`
/// event, which is already on its way.
class SessionNotReady implements Exception {
  final String message;
  const SessionNotReady([this.message = 'LiveKit session is not ready']);

  @override
  String toString() => 'SessionNotReady: $message';
}

/// 503 / network / malformed mint payload.
class MintUnavailable implements Exception {
  final MintErrorKind kind = MintErrorKind.mintUnavailable;
  /// The reason, unprefixed — the [toString] is this wrapped for display.
  final String detail;
  final Object? cause;

  MintUnavailable(this.detail, {this.cause});

  @override
  String toString() => 'MintUnavailable: mint unavailable: $detail';
}
