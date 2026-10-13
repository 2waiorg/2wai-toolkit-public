import 'dart:typed_data';

/// Successful chat response from the v1.3 `POST /chat` endpoint.
///
/// Plays directly in `package:video_player`'s `VideoPlayerController`
/// via a temporary file or `Uri.dataFromBytes`. No fragment demux, no
/// MediaSource — just standard MP4.
class PipelineV13Response {
  /// Complete MP4 video bytes from the response body.
  final Uint8List videoBytes;

  /// LLM reply text decoded from the `X-Response-Text` response header.
  /// The server JSON-encodes the string; this field holds the decoded
  /// plain text (no surrounding quotes).
  final String replyText;

  const PipelineV13Response({
    required this.videoBytes,
    required this.replyText,
  });

  @override
  String toString() =>
      'PipelineV13Response(${videoBytes.length} bytes MP4, replyText: ${replyText.length} chars)';
}

/// Base exception type for all `PipelineV13Client` failures.
sealed class PipelineV13Exception implements Exception {
  final String message;
  const PipelineV13Exception(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

/// HTTP request returned a non-2xx status code. For known auth/quota
/// statuses (401, 403, 429) the typed subclasses below are thrown.
class PipelineV13HttpException extends PipelineV13Exception {
  final int statusCode;
  final String body;

  const PipelineV13HttpException({
    required this.statusCode,
    required this.body,
  }) : super('HTTP $statusCode');
}

/// HTTP 401 — missing or invalid `publishableKey`.
class PipelineV13UnauthorizedException extends PipelineV13HttpException {
  const PipelineV13UnauthorizedException({required String body})
      : super(statusCode: 401, body: body);
}

/// HTTP 403 — key valid but not scoped for this request.
class PipelineV13ForbiddenException extends PipelineV13HttpException {
  const PipelineV13ForbiddenException({required String body})
      : super(statusCode: 403, body: body);
}

/// HTTP 429 — quota exhausted.
class PipelineV13RateLimitedException extends PipelineV13HttpException {
  const PipelineV13RateLimitedException({required String body})
      : super(statusCode: 429, body: body);
}

/// Transport-level failure (network, TLS, DNS) OR response was 200 but
/// didn't have the expected shape (missing header, empty body, etc).
class PipelineV13TransportException extends PipelineV13Exception {
  final Object cause;

  const PipelineV13TransportException({
    required this.cause,
    required String message,
  }) : super(message);
}
