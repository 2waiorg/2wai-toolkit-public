import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../credentials.dart';
import 'pipeline_v13_config.dart';
import 'pipeline_v13_errors.dart';

/// Dart client for the v1.3 avatar pipeline (`POST /chat` → MP4).
///
/// One round-trip per turn: send text, get back a complete MP4 + the
/// LLM reply text in the `X-Response-Text` header. No streaming, no WS,
/// no MediaSource — plays in `package:video_player` natively on every
/// Flutter platform. 4–9s latency per `docs/PIPELINE_SPEC_V1.3.md`.
///
/// Targets `2wai-avatar-pipeline/server/server.py` and any server that
/// matches its contract.
///
/// Typical use:
///
/// ```dart
/// final client = PipelineV13Client(
///   baseUrl: Uri.parse('https://<host>'),
///   config: PipelineV13Config(avatar: 'sophi'),
/// );
/// final response = await client.chat('hello');
/// // response.videoBytes -> Uint8List MP4
/// // response.replyText  -> LLM reply
/// ```
class PipelineV13Client {
  PipelineV13Client({
    required this.baseUrl,
    required this.config,
    TwaiCredentials? credentials,
    String? publishableKey,
    http.Client? httpClient,
  })  : _credentials = TwaiCredentials.resolve(
          credentials: credentials,
          publishableKey: publishableKey,
        ),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Server base URL — e.g. `https://krystal-avatar.westus2.cloudapp.azure.com`.
  /// `/chat` and `/health` are resolved against this.
  final Uri baseUrl;

  /// Avatar + voice configuration.
  final PipelineV13Config config;

  final TwaiCredentials _credentials;
  final http.Client _http;
  final bool _ownsClient;

  /// Resolved credentials — either the `credentials` constructor arg,
  /// a [PublicKeyCredentials] wrapping `publishableKey`, or [AnonymousCredentials].
  TwaiCredentials get credentials => _credentials;

  Uri get chatEndpoint => baseUrl.resolve('/chat');
  Uri get healthEndpoint => baseUrl.resolve('/health');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        ..._credentials.httpHeaders(),
      };

  /// Send `message` to the pipeline, get back the rendered MP4 + reply text.
  ///
  /// Throws [PipelineV13HttpException] on HTTP >= 400.
  /// Throws [PipelineV13TransportException] on network failure, empty
  /// body, or missing `X-Response-Text` header.
  Future<PipelineV13Response> chat(
    String message, {
    List<Map<String, dynamic>>? history,
  }) async {
    final body = jsonEncode(config.bodyFor(message, history: history));

    final http.Response resp;
    try {
      resp = await _http.post(chatEndpoint, headers: _headers, body: body);
    } on Exception catch (e) {
      throw PipelineV13TransportException(
        cause: e,
        message: 'POST $chatEndpoint failed: $e',
      );
    }

    if (resp.statusCode >= 400) {
      throw switch (resp.statusCode) {
        401 => PipelineV13UnauthorizedException(body: resp.body),
        403 => PipelineV13ForbiddenException(body: resp.body),
        429 => PipelineV13RateLimitedException(body: resp.body),
        _ => PipelineV13HttpException(
            statusCode: resp.statusCode,
            body: resp.body,
          ),
      };
    }

    if (resp.bodyBytes.isEmpty) {
      throw PipelineV13TransportException(
        cause: StateError('empty response body'),
        message: 'Server returned 2xx with empty body',
      );
    }

    // Headers are lower-cased by package:http.
    final rawReply = resp.headers['x-response-text'];
    if (rawReply == null) {
      throw PipelineV13TransportException(
        cause: StateError('missing X-Response-Text header'),
        message: 'Response has no X-Response-Text header',
      );
    }

    // The server JSON-encodes the string ('"hello"' not 'hello'). Decode
    // once; if it's already a bare string (non-conformant server), fall
    // back to the raw header value.
    String replyText;
    try {
      final decoded = jsonDecode(rawReply);
      replyText = decoded is String ? decoded : rawReply;
    } on FormatException {
      replyText = rawReply;
    }

    return PipelineV13Response(
      videoBytes: Uint8List.fromList(resp.bodyBytes),
      replyText: replyText,
    );
  }

  /// `GET /health`. Returns the raw JSON map — shape varies by server
  /// version (see `PIPELINE_SPEC_V1.3.md` vs `server.py:406`).
  Future<Map<String, dynamic>> health() async {
    final http.Response resp;
    try {
      resp = await _http.get(healthEndpoint, headers: _headers);
    } on Exception catch (e) {
      throw PipelineV13TransportException(
        cause: e,
        message: 'GET $healthEndpoint failed: $e',
      );
    }

    if (resp.statusCode >= 400) {
      throw switch (resp.statusCode) {
        401 => PipelineV13UnauthorizedException(body: resp.body),
        403 => PipelineV13ForbiddenException(body: resp.body),
        429 => PipelineV13RateLimitedException(body: resp.body),
        _ => PipelineV13HttpException(
            statusCode: resp.statusCode,
            body: resp.body,
          ),
      };
    }

    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException(
            'Expected JSON object, got ${decoded.runtimeType}');
      }
      return decoded;
    } on FormatException catch (e) {
      throw PipelineV13TransportException(
        cause: e,
        message: 'Could not parse health response: ${resp.body}',
      );
    }
  }

  /// Release the internal HTTP client (if we created it).
  void close() {
    if (_ownsClient) _http.close();
  }
}
