import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../credentials.dart';
import 'chat_gateway_config.dart';
import 'chat_gateway_errors.dart';

/// Client for the penthouse-style `POST /ext-api/human` endpoint.
///
/// Pairs with [MseStreamClient]: this gateway returns the LLM's reply
/// text immediately; the audio+video render for that reply arrives on
/// the already-open WebSocket session whose `session_id` matches this
/// gateway's [ChatGatewayConfig.sessionId].
///
/// Typical use:
///
/// ```dart
/// final gateway = ChatGateway(
///   baseUrl: Uri.parse('https://<host>'),
///   config: ChatGatewayConfig(
///     sessionId: sessionId,           // same as the WS handshake
///     avatarName: 'RedJesusTalk2',
///     avatarVoice: '<voice-uuid>',
///     ttsSelection: 'tts5',
///     userId: null,                    // or authenticated user id
///   ),
/// );
/// final response = await gateway.sendMessage('what is a verse for today?');
/// // response.replyText -> the LLM reply
/// // video for this reply arrives on the open MseStreamClient
/// ```
class ChatGateway {
  ChatGateway({
    required this.baseUrl,
    required this.config,
    TwaiCredentials? credentials,
    this.publishableKey,
    this.pathPrefix = '/ext-api',
    http.Client? httpClient,
  })  : _credentials = TwaiCredentials.resolve(
          credentials: credentials,
          publishableKey: publishableKey,
        ),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Server base URL — e.g. `https://krystal-avatar.westus2.cloudapp.azure.com`.
  /// The gateway resolves `$pathPrefix/human` against this.
  final Uri baseUrl;

  /// Session-level config sent on every request.
  final ChatGatewayConfig config;

  /// Legacy publishable-key shortcut. If [credentials] is also passed,
  /// [credentials] wins. Prefer passing [credentials] directly — this
  /// stays as a back-compat convenience for callers on the pre-credentials
  /// API surface.
  final String? publishableKey;

  final TwaiCredentials _credentials;

  /// Resolved credentials in use — either the [credentials] arg, a
  /// [PublicKeyCredentials] wrapping [publishableKey], or [AnonymousCredentials].
  TwaiCredentials get credentials => _credentials;

  /// URL prefix routing the POST. Must match the [MseStreamChatSession]'s
  /// prefix — one nginx `location` block per prefix, each fronting a
  /// different main_service + worker pair (wav2lip vs muse vs onnx).
  /// Default `/ext-api` matches the historical wav2lip stack.
  final String pathPrefix;

  final http.Client _http;
  final bool _ownsClient;

  /// Resolved endpoint for sendMessage POSTs.
  Uri get endpoint => baseUrl.resolve('$pathPrefix/human');

  /// Send `text` to the brain. Returns the reply text + status + the
  /// brain-inferred mood (read from the `X-Mood` response header — `null`
  /// when absent, which is normal pre-r14 or when mood is disabled).
  ///
  /// Optional per-turn brain-context fields (Patch #70 r14):
  /// - [gamificationLevel] — numeric per-(user, avatar) level forwarded
  ///   to the brain to map to a Trust Stage. `null` = brain defaults to
  ///   Stage 1.
  /// - [avatarStateBlock] — opaque context block (mood / pose / outfit)
  ///   forwarded to the brain unchanged. `null` = no extra context.
  ///
  /// Throws [ChatProtocolException] if the server responds 200 but with
  /// `code != 0`; [ChatHttpException] on HTTP >= 400; [ChatTransportException]
  /// on network/parse failures.
  Future<ChatResponse> sendMessage(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) async {
    final body = jsonEncode(config.bodyFor(
      text,
      gamificationLevel: gamificationLevel,
      avatarStateBlock: avatarStateBlock,
    ));

    final headers = <String, String>{
      'Content-Type': 'application/json',
      ..._credentials.httpHeaders(),
    };

    final http.Response resp;
    try {
      resp = await _http.post(endpoint, headers: headers, body: body);
    } on Exception catch (e) {
      throw ChatTransportException(
        cause: e,
        message: 'POST $endpoint failed: $e',
      );
    }

    if (resp.statusCode >= 400) {
      throw switch (resp.statusCode) {
        401 => ChatUnauthorizedException(body: resp.body),
        403 => ChatForbiddenException(body: resp.body),
        429 => ChatRateLimitedException(body: resp.body),
        _ => ChatHttpException(statusCode: resp.statusCode, body: resp.body),
      };
    }

    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
      }
      json = decoded;
    } on FormatException catch (e) {
      throw ChatTransportException(
        cause: e,
        message: 'Could not parse response body: ${resp.body}',
      );
    }

    final code = json['code'];
    if (code is! int || code != 0) {
      throw ChatProtocolException(
        code: code is int ? code : -1,
        data: json['data'] as String?,
        message: 'Server returned code=$code, data=${json['data']}',
      );
    }

    // X-Mood + X-Mood-Humanized headers (Patch #62 r14 — main_service
    // echoes the brain SSE event: mood frame as a pair of response
    // headers, verified against penthouse main_service/.../chat.py:262-291).
    // Dart's http.Response normalizes header names to lowercase, so we
    // check the lowercased forms. Empty string treated as absent.
    final moodHeader = resp.headers['x-mood'];
    final mood = (moodHeader == null || moodHeader.isEmpty) ? null : moodHeader;
    final humHeader = resp.headers['x-mood-humanized'];
    final moodHumanized =
        (humHeader == null || humHeader.isEmpty) ? null : humHeader;

    try {
      return ChatResponse.fromJson(json, mood: mood, moodHumanized: moodHumanized);
    } on FormatException catch (e) {
      throw ChatTransportException(
        cause: e,
        message: 'Malformed success response: ${resp.body}',
      );
    }
  }

  /// Release the internal HTTP client (if we created it). No-op if the
  /// caller injected a client via [httpClient] — they own its lifecycle.
  void close() {
    if (_ownsClient) _http.close();
  }
}
