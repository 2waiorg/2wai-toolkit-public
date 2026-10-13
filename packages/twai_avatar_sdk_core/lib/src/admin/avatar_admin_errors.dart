/// Base exception for all `AvatarAdminClient` failures.
sealed class AvatarAdminException implements Exception {
  final String message;
  const AvatarAdminException(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

/// Server returned HTTP 200 but with `code != 0`.
///
/// Known codes per `protocol.md` §4:
/// - `1` not found (delete)
/// - `2` already exists (add) / currently adding (delete)
/// - `3` currently adding (add) / currently deleting (delete)
/// - `4` currently deleting (add)
/// - `999999` exception
class AvatarAdminProtocolException extends AvatarAdminException {
  final int code;
  final String? data;
  const AvatarAdminProtocolException({
    required this.code,
    required this.data,
    required String message,
  }) : super(message);
}

/// HTTP request returned a non-2xx status code. For known auth/quota
/// statuses ([statusCode] 401, 403, 429) callers usually want to catch
/// the typed subclass below; everything else surfaces as the base type.
class AvatarAdminHttpException extends AvatarAdminException {
  final int statusCode;
  final String body;
  const AvatarAdminHttpException({
    required this.statusCode,
    required this.body,
  }) : super('HTTP $statusCode');
}

/// HTTP 401 — missing or invalid `secretKey`. Customer should rotate the
/// key or verify the value matches the environment they're targeting.
class AvatarAdminUnauthorizedException extends AvatarAdminHttpException {
  const AvatarAdminUnauthorizedException({required String body})
      : super(statusCode: 401, body: body);
}

/// HTTP 403 — the key is valid but lacks scope for this operation
/// (e.g. a publishable key sent to an admin endpoint, or a per-tenant
/// key trying to touch a different tenant's avatars).
class AvatarAdminForbiddenException extends AvatarAdminHttpException {
  const AvatarAdminForbiddenException({required String body})
      : super(statusCode: 403, body: body);
}

/// HTTP 429 — the key is over its quota. The customer should back off
/// or upgrade their plan; retries inside the same window will fail.
class AvatarAdminRateLimitedException extends AvatarAdminHttpException {
  const AvatarAdminRateLimitedException({required String body})
      : super(statusCode: 429, body: body);
}

/// Transport-level failure (network, parse, malformed response).
class AvatarAdminTransportException extends AvatarAdminException {
  final Object cause;
  const AvatarAdminTransportException({
    required this.cause,
    required String message,
  }) : super(message);
}
