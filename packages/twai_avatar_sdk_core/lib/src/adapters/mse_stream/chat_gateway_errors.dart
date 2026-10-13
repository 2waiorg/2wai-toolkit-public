/// Successful chat response. The `replyText` populates the chat-bubble
/// UI immediately; the audio+video for this reply arrives separately on
/// the open MSE WebSocket. See `docs/protocol.md` §2.
class ChatResponse {
  /// The LLM's reply text (server's `res` field).
  final String replyText;

  /// Server status string; usually `'ok'`.
  final String data;

  /// Brain-inferred mood slug for this turn, read from the `X-Mood`
  /// response header (penthouse Patch #62 r14). `null` when the server
  /// didn't emit one (mood system off, no mood event for this turn, or
  /// pre-Patch-#62 server). Raw wire string — see [Mood] for the typed
  /// enum that wraps this in [MoodEvent].
  final String? mood;

  /// Per-avatar humanized mood tooltip from the `X-Mood-Humanized`
  /// response header (e.g. `"Sophi is feeling good"`). Per-avatar
  /// vocabulary lives in the brain's `<AVATAR>_TOOLTIP_NAMES` dict
  /// (see `avatar-brain/src/core/mood/roster.py`). `null` when absent.
  final String? moodHumanized;

  const ChatResponse({
    required this.replyText,
    required this.data,
    this.mood,
    this.moodHumanized,
  });

  /// Parse a decoded JSON envelope. The header-derived [mood] +
  /// [moodHumanized] are left `null` by default because headers aren't
  /// visible here; the gateway populates them when constructing the
  /// response.
  factory ChatResponse.fromJson(
    Map<String, dynamic> json, {
    String? mood,
    String? moodHumanized,
  }) {
    final res = json['res'];
    if (res is! String) {
      throw FormatException('Missing or non-string "res": $res');
    }
    return ChatResponse(
      replyText: res,
      data: json['data'] as String? ?? '',
      mood: mood,
      moodHumanized: moodHumanized,
    );
  }

  @override
  String toString() =>
      'ChatResponse(replyText: ${replyText.length} chars, data: "$data"'
      '${mood == null ? "" : ", mood: $mood"}'
      '${moodHumanized == null ? "" : ", humanized: $moodHumanized"})';
}

/// Base exception type for all `ChatGateway` failures.
sealed class ChatGatewayException implements Exception {
  final String message;
  const ChatGatewayException(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

/// Server replied with HTTP 200 but `code != 0` — application-level
/// failure (e.g. invalid session id, avatar unknown, brain failure).
class ChatProtocolException extends ChatGatewayException {
  /// The server's `code` field. -1 if non-numeric / missing.
  final int code;

  /// The server's `data` field (status string or error description).
  final String? data;

  const ChatProtocolException({
    required this.code,
    required this.data,
    required String message,
  }) : super(message);
}

/// HTTP request returned a non-2xx status code. For known auth/quota
/// statuses (401, 403, 429) callers usually want to catch the typed
/// subclass below.
class ChatHttpException extends ChatGatewayException {
  final int statusCode;
  final String body;

  const ChatHttpException({
    required this.statusCode,
    required this.body,
  }) : super('HTTP $statusCode');
}

/// HTTP 401 — missing or invalid `publishableKey`. The embed should
/// surface this clearly so the page developer can verify the key in
/// their HTML.
class ChatUnauthorizedException extends ChatHttpException {
  const ChatUnauthorizedException({required String body})
      : super(statusCode: 401, body: body);
}

/// HTTP 403 — key valid but not scoped for chat (e.g. accidentally
/// using a secret/admin-only key, or a tenant key targeting another
/// tenant's avatar).
class ChatForbiddenException extends ChatHttpException {
  const ChatForbiddenException({required String body})
      : super(statusCode: 403, body: body);
}

/// HTTP 429 — quota exhausted. Distinct from ChatUnauthorizedException
/// because retries against an unauthorized key never succeed, while
/// retries after a quota reset can.
class ChatRateLimitedException extends ChatHttpException {
  const ChatRateLimitedException({required String body})
      : super(statusCode: 429, body: body);
}

/// Transport-level failure (network unreachable, DNS, TLS) or response
/// could not be parsed as the expected JSON shape.
class ChatTransportException extends ChatGatewayException {
  /// The underlying exception (SocketException, FormatException, …).
  final Object cause;

  const ChatTransportException({
    required this.cause,
    required String message,
  }) : super(message);
}
