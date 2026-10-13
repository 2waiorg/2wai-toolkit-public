/// Typed exceptions and close-code reasons for the twai-api (`/v1/*`)
/// adapter. Mirrors the pattern used by `pipeline_v13_errors.dart` +
/// `mse_stream_errors.dart` so the three adapters expose the same shape
/// to callers.
library;

import '../../errors.dart';

/// Base class for every twai-api (`/v1/*`) exception the SDK raises.
class TwaiApiException implements Exception, TwaiError {
  const TwaiApiException({required this.message, this.cause});

  @override
  final String message;
  @override
  final Object? cause;

  @override
  TwaiErrorKind get kind => TwaiErrorKind.unknown;

  @override
  String toString() =>
      cause == null ? '$runtimeType: $message' : '$runtimeType: $message ($cause)';
}

/// Generic HTTP >= 400 from the gateway that isn't 401 / 403 / 429.
class TwaiApiHttpException extends TwaiApiException {
  const TwaiApiHttpException({
    required this.statusCode,
    required this.body,
    String? message,
    super.cause,
  }) : super(message: message ?? 'HTTP $statusCode');

  final int statusCode;
  final String body;

  @override
  TwaiErrorKind get kind => TwaiErrorKind.transport;
}

/// HTTP 401 — the server key (sk_) is missing, invalid, or revoked.
class TwaiApiUnauthorizedException extends TwaiApiException {
  const TwaiApiUnauthorizedException({required this.body, super.cause})
      : super(message: 'twai-api unauthorized (401)');

  final String body;

  @override
  TwaiErrorKind get kind => TwaiErrorKind.unauthorized;
}

/// HTTP 403 — key valid but lacks scope (avatar belongs to another
/// tenant, or the key is admin-only, etc.).
class TwaiApiForbiddenException extends TwaiApiException {
  const TwaiApiForbiddenException({required this.body, super.cause})
      : super(message: 'twai-api forbidden (403)');

  final String body;

  @override
  TwaiErrorKind get kind => TwaiErrorKind.unauthorized;
}

/// HTTP 429 — per-key or platform-wide concurrency cap hit. `retryAfter`
/// is populated from the `Retry-After` response header when present.
class TwaiApiRateLimitedException extends TwaiApiException {
  const TwaiApiRateLimitedException({
    required this.body,
    this.retryAfterSeconds,
    super.cause,
  }) : super(message: 'twai-api rate-limited (429)');

  final String body;
  final int? retryAfterSeconds;

  @override
  TwaiErrorKind get kind => TwaiErrorKind.transport;
}

/// Network / parse failure — server didn't respond, or response wasn't
/// the expected shape. Never carries a status code.
class TwaiApiTransportException extends TwaiApiException {
  const TwaiApiTransportException({required super.message, super.cause});

  @override
  TwaiErrorKind get kind => TwaiErrorKind.transport;
}

/// HTTP 404 from `GET /v1/avatars/{owner}/{name}` — either the avatar
/// does not exist, or it is private and the authenticating `sk_` tenant
/// does not own it (the gateway deliberately returns 404 rather than
/// 403 for the latter case, so it does not leak the existence of
/// avatars outside the tenant). Carries the offending `(owner, name)`
/// pair so the caller can surface a useful message.
class TwaiApiAvatarNotFoundException extends TwaiApiException {
  const TwaiApiAvatarNotFoundException({
    required this.owner,
    required this.name,
    this.detail,
    super.cause,
  }) : super(message: 'avatar not found: $owner/$name');

  final String owner;
  final String name;

  /// Named detail string from the gateway response body (e.g.
  /// `"no_such_avatar"`). Present only when the response carried a
  /// `{"detail": "..."}` JSON body.
  final String? detail;
}

// ── WebSocket close-code reasons ───────────────────────────────────────

/// Why the twai-api WS `/v1/stream` closed. Sealed hierarchy so callers
/// can `switch` exhaustively. Mirrors `MseStreamCloseReason`'s design.
sealed class TwaiApiCloseReason {
  const TwaiApiCloseReason();
}

/// Clean close (code 1000) — either the SDK closed the socket or the
/// server shut it down normally (e.g. session DELETE).
class TwaiApiNormalClose extends TwaiApiCloseReason {
  const TwaiApiNormalClose();
}

/// The `client_token` was rejected — expired past its 3600s TTL, or the
/// gateway couldn't verify the signature. WS close code 4401.
class TwaiApiTokenRejected extends TwaiApiCloseReason {
  const TwaiApiTokenRejected(this.reason);
  final String reason;
}

/// The session config the WS tried to attach to no longer matches the
/// active session state — avatar deleted, voice deleted, session already
/// DELETEd on the REST side, etc. WS close code 4403.
class TwaiApiConfigMismatch extends TwaiApiCloseReason {
  const TwaiApiConfigMismatch(this.reason);
  final String reason;
}

/// Any other close — logged with the raw code + reason.
class TwaiApiOtherClose extends TwaiApiCloseReason {
  const TwaiApiOtherClose(this.code, this.reason);
  final int code;
  final String reason;
}

/// Map an observed close code + reason to the typed enum. Handles the
/// codes documented on `gateway/app/services/relay.py`.
TwaiApiCloseReason twaiApiCloseFor(int? code, String? reason) {
  final r = reason ?? '';
  switch (code) {
    case 1000:
      return const TwaiApiNormalClose();
    case 4401:
      return TwaiApiTokenRejected(r);
    case 4403:
      return TwaiApiConfigMismatch(r);
    default:
      return TwaiApiOtherClose(code ?? -1, r);
  }
}
