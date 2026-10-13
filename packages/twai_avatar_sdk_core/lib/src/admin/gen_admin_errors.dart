/// Base type for every gen-2wai client failure. Callers catching a
/// broad "anything went wrong with gen" can `catch (e) if (e is
/// GenApiException) …`; more specific handling should catch the
/// subtypes below.
sealed class GenApiException implements Exception {
  const GenApiException({required this.message, this.detail});

  final String message;

  /// FastAPI's `{"detail": "..."}` field if the server returned one.
  /// Preferred over raw `body` for user-facing messages.
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message — $detail';
}

/// The server accepted the call but returned non-2xx that this SDK
/// doesn't have a more specific subclass for.
class GenApiHttpException extends GenApiException {
  const GenApiHttpException({
    required this.statusCode,
    required this.body,
    String? detail,
  }) : super(
          message: 'gen-2wai HTTP $statusCode',
          detail: detail,
        );

  final int statusCode;
  final String body;
}

/// 401 — missing/invalid/expired bearer token. Prompt the user to
/// verify a fresh OTP.
class GenApiUnauthorizedException extends GenApiException {
  const GenApiUnauthorizedException({required this.body, String? detail})
      : super(message: 'gen-2wai 401 unauthorized', detail: detail);
  final String body;
}

/// 402 — the account doesn't have enough credits to create another
/// avatar. Surfaces on `POST /api/gen/submissions`.
class GenApiInsufficientCreditsException extends GenApiException {
  const GenApiInsufficientCreditsException(
      {required this.body, String? detail})
      : super(
          message: 'gen-2wai 402 insufficient credits',
          detail: detail,
        );
  final String body;
}

/// 403 — the caller is authenticated but not authorized (e.g. asking
/// for a view token to someone else's avatar).
class GenApiForbiddenException extends GenApiException {
  const GenApiForbiddenException({required this.body, String? detail})
      : super(message: 'gen-2wai 403 forbidden', detail: detail);
  final String body;
}

/// 404 — resource missing or not owned by the caller. gen-2wai
/// deliberately conflates these to avoid probing.
class GenApiNotFoundException extends GenApiException {
  const GenApiNotFoundException({required this.body, String? detail})
      : super(message: 'gen-2wai 404 not found', detail: detail);
  final String body;
}

/// 422 — request validation failed (bad name, missing consent,
/// missing required persona fields, etc.).
class GenApiValidationException extends GenApiException {
  const GenApiValidationException({required this.body, String? detail})
      : super(message: 'gen-2wai 422 validation error', detail: detail);
  final String body;
}

/// 429 — rate limited. Backoff and retry.
class GenApiRateLimitedException extends GenApiException {
  const GenApiRateLimitedException({required this.body, String? detail})
      : super(message: 'gen-2wai 429 rate limited', detail: detail);
  final String body;
}

/// Network / parse failure that never produced a usable HTTP
/// response — DNS error, connection reset, malformed JSON, etc.
class GenApiTransportException extends GenApiException {
  const GenApiTransportException({required this.cause, required String message})
      : super(message: message);
  final Object cause;
}
