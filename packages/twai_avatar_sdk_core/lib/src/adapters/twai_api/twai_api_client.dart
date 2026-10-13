/// REST + WebSocket clients for the twai-api (`/v1/*`) wire.
///
/// - [TwaiApiRestClient] wraps the control-plane calls (POST /v1/sessions,
///   POST /v1/sessions/{sid}/speak, POST /v1/sessions/{sid}/interrupt,
///   DELETE /v1/sessions/{sid}).
/// - [TwaiApiWsClient] wraps the `/v1/stream` WebSocket — demuxes
///   `session.ready` + `speaking` text frames from the fMP4 binary frames.
///
/// Both are usable standalone (for advanced flows / tests) or via
/// [TwaiApiChatSession] which ties them into the [ChatSession] interface.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../credentials.dart';
import '../mse_stream/mse_stream_client.dart' show WebSocketChannelFactory;
import '../mse_stream/mse_stream_config.dart' show SpeakingEvent;
import 'twai_api_config.dart';
import 'twai_api_errors.dart';

/// REST client for the twai-api control plane. In dev mode this sits in
/// the SDK process holding an sk_ key; in prod split-plane a customer's
/// server holds the sk_ and the browser SDK talks to a mint-proxy that
/// mirrors this shape.
class TwaiApiRestClient {
  TwaiApiRestClient({
    required Uri baseUrl,
    required TwaiCredentials credentials,
    http.Client? httpClient,
  })  : baseUrl = _normalizeBase(baseUrl),
        _credentials = credentials,
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Base URL for `/v1/*` — e.g.
  /// `https://twai-api.<...>.azurecontainerapps.io` (direct-to-gateway),
  /// `http://127.0.0.1:8787` (local CORS proxy for dev), or
  /// `https://myapp.com/twai` (customer mint-proxy at a URL prefix, prod
  /// split-plane). Trailing slash is added automatically so a `/twai`
  /// prefix is preserved when joining paths.
  final Uri baseUrl;

  /// Ensure the path ends with `/` so `baseUrl.resolve('v1/sessions')`
  /// preserves any URL prefix (`/twai/v1/sessions` rather than replacing
  /// `twai` with `v1/sessions`). Called once in the constructor.
  static Uri _normalizeBase(Uri u) {
    if (u.path.endsWith('/')) return u;
    return u.replace(path: '${u.path.isEmpty ? "" : u.path}/');
  }

  final TwaiCredentials _credentials;
  final http.Client _http;
  final bool _ownsClient;

  /// The credentials used to sign every REST call. `sk_` lives here in
  /// dev mode; in prod split-plane the customer's server holds the sk_
  /// and this SDK-side client either uses anonymous credentials + a
  /// per-request cookie, or a customer-defined mint-proxy Bearer.
  TwaiCredentials get credentials => _credentials;

  /// POST /v1/sessions — mint a fresh session. Returns
  /// `{session_id, client_token, websocket_url}`.
  Future<TwaiApiSessionMint> createSession(TwaiApiSessionRequest req) async {
    final resp = await _post(
      baseUrl.resolve('v1/sessions'),
      body: jsonEncode(req.toJson()),
    );
    // Gateway returns 201 on create per app/routers/sessions.py:74.
    _throwIfNotOk(resp, expected: {201, 200});
    return _decodeMint(resp);
  }

  /// POST /v1/sessions with `transport: "livekit"` -- mint an
  /// Adapter-5 (LiveKit/WebRTC) session. Same endpoint as
  /// [createSession], different request + response envelope.
  ///
  /// Returns the LiveKit connection tuple:
  /// `{session_id, livekit_url, participant_token, room_name, agent_identity}`.
  ///
  /// The `agent_identity` hint tells the SDK-side client which
  /// participant in the room is the avatar's agent (livealman-host);
  /// data events from other participants are ignored.
  ///
  /// Requires the gateway's LiveKit transport to be configured AND the
  /// target avatar to have `livekit_profile` set to a slug in the
  /// gateway's allowlist. Fail-closed: 503 if unconfigured, 404 if
  /// avatar not enabled, 404 if profile not allowed.
  Future<TwaiApiLiveKitMint> createLiveKitSession(
      TwaiApiLiveKitSessionRequest req) async {
    final resp = await _post(
      baseUrl.resolve('v1/sessions'),
      body: jsonEncode(req.toJson()),
    );
    _throwIfNotOk(resp, expected: {201, 200});
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } on FormatException catch (e) {
      throw TwaiApiTransportException(
        message: 'Bad JSON in /v1/sessions LiveKit response: ${resp.body}',
        cause: e,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw TwaiApiTransportException(
        message: 'Expected JSON object, got ${decoded.runtimeType}',
      );
    }
    try {
      return TwaiApiLiveKitMint.fromJson(decoded);
    } on FormatException catch (e) {
      throw TwaiApiTransportException(
        message: 'Malformed LiveKit mint response: ${resp.body}',
        cause: e,
      );
    }
  }

  /// POST /v1/sessions/{sid}/speak — enqueue TTS + video for the
  /// literal text. Fire-and-forget on the app side; the SDK's WS is
  /// the observable side channel.
  Future<void> speak(String sessionId, String text, {String? voiceId}) async {
    final resp = await _post(
      baseUrl.resolve('v1/sessions/$sessionId/speak'),
      body: speakBodyJson(text, voiceId: voiceId),
    );
    _throwIfNotOk(resp, expected: {200, 202});
  }

  /// POST /v1/sessions/{sid}/interrupt — flush the current utterance.
  Future<void> interrupt(String sessionId) async {
    final resp = await _post(
      baseUrl.resolve('v1/sessions/$sessionId/interrupt'),
    );
    _throwIfNotOk(resp, expected: {200, 202});
  }

  /// DELETE /v1/sessions/{sid} — end the session. The WS relay will
  /// close server-side after this.
  Future<void> deleteSession(String sessionId) async {
    final http.Response resp;
    try {
      resp = await _http.delete(
        baseUrl.resolve('v1/sessions/$sessionId'),
        headers: _credentials.httpHeaders(),
      );
    } on Exception catch (e) {
      throw TwaiApiTransportException(
        message: 'DELETE /v1/sessions/$sessionId failed: $e',
        cause: e,
      );
    }
    _throwIfNotOk(resp, expected: {200, 204});
  }

  /// GET /v1/avatars/{owner}/{name} — resolve an avatar handle to a
  /// playable [TwaiApiAvatar] record. For public avatars, returns the
  /// record alone. For private avatars owned by the authenticating
  /// `sk_` tenant, returns the record AND a view token the SDK threads
  /// through to subsequent session mints.
  ///
  /// Throws:
  ///   - [TwaiApiAvatarNotFoundException] on 404 (avatar does not
  ///     exist OR is private and the authenticating tenant does not
  ///     own it — the gateway returns 404 rather than 403 for the
  ///     latter so the response doesn't leak existence outside the
  ///     tenant).
  ///   - [TwaiApiUnauthorizedException] / [TwaiApiForbiddenException] /
  ///     [TwaiApiRateLimitedException] / [TwaiApiHttpException] /
  ///     [TwaiApiTransportException] per the standard ladder.
  ///
  /// See `docs/catalog_hydrate_plan.md` for the gateway contract and
  /// the full [TwaiApiAvatar] shape.
  Future<TwaiApiAvatarResult> getAvatar({
    required String owner,
    required String name,
  }) async {
    final path = 'v1/avatars/'
        '${Uri.encodeComponent(owner)}/'
        '${Uri.encodeComponent(name)}';
    final resp = await _get(baseUrl.resolve(path));

    // 404 branches to a typed exception BEFORE the generic ladder so
    // callers can `catch (TwaiApiAvatarNotFoundException)` without
    // string-matching the body.
    if (resp.statusCode == 404) {
      String? detail;
      try {
        final body = jsonDecode(resp.body);
        if (body is Map && body['detail'] is String) {
          detail = body['detail'] as String;
        }
      } on FormatException {
        // Non-JSON body — leave detail null.
      }
      throw TwaiApiAvatarNotFoundException(
        owner: owner,
        name: name,
        detail: detail,
      );
    }

    _throwIfNotOk(resp, expected: {200});

    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } on FormatException catch (e) {
      throw TwaiApiTransportException(
        message: 'Bad JSON in /v1/avatars/$owner/$name response: ${resp.body}',
        cause: e,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw TwaiApiTransportException(
        message: 'Expected JSON object from /v1/avatars/$owner/$name, '
            'got ${decoded.runtimeType}',
      );
    }
    try {
      return TwaiApiAvatarResult.fromJson(decoded);
    } on Exception catch (e) {
      throw TwaiApiTransportException(
        message: 'Malformed avatar response: ${resp.body}',
        cause: e,
      );
    }
  }

  /// Release the internal HTTP client (if we created it).
  void close() {
    if (_ownsClient) _http.close();
  }

  Future<http.Response> _get(Uri url) async {
    try {
      return await _http.get(url, headers: _credentials.httpHeaders());
    } on Exception catch (e) {
      throw TwaiApiTransportException(
        message: 'GET $url failed: $e',
        cause: e,
      );
    }
  }

  Future<http.Response> _post(Uri url, {String? body}) async {
    final headers = <String, String>{
      if (body != null) 'Content-Type': 'application/json',
      ..._credentials.httpHeaders(),
    };
    try {
      return await _http.post(url, headers: headers, body: body);
    } on Exception catch (e) {
      throw TwaiApiTransportException(
        message: 'POST $url failed: $e',
        cause: e,
      );
    }
  }

  void _throwIfNotOk(http.Response resp, {required Set<int> expected}) {
    if (expected.contains(resp.statusCode)) return;
    switch (resp.statusCode) {
      case 401:
        throw TwaiApiUnauthorizedException(body: resp.body);
      case 403:
        throw TwaiApiForbiddenException(body: resp.body);
      case 429:
        final ra = resp.headers['retry-after'];
        throw TwaiApiRateLimitedException(
          body: resp.body,
          retryAfterSeconds: ra == null ? null : int.tryParse(ra),
        );
      default:
        throw TwaiApiHttpException(
          statusCode: resp.statusCode,
          body: resp.body,
        );
    }
  }

  TwaiApiSessionMint _decodeMint(http.Response resp) {
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } on FormatException catch (e) {
      throw TwaiApiTransportException(
        message: 'Bad JSON in /v1/sessions response: ${resp.body}',
        cause: e,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw TwaiApiTransportException(
        message: 'Expected JSON object, got ${decoded.runtimeType}',
      );
    }
    try {
      return TwaiApiSessionMint.fromJson(decoded);
    } on FormatException catch (e) {
      throw TwaiApiTransportException(
        message: 'Malformed /v1/sessions response: ${resp.body}',
        cause: e,
      );
    }
  }
}

/// WebSocket client for `/v1/stream`. Connects to the URL returned by
/// [TwaiApiRestClient.createSession] and demuxes server frames.
///
/// Wire (per `apps/twai_api_demo/lib/main.dart` — the zero-SDK reference):
/// - First text frame: `{"type":"session.ready"}` when the relay's upstream
///   is up and ready to accept `/speak` calls.
/// - Later text frames: `{"type":"speaking","value":"start|stop","pts":...}`.
/// - Binary frames: fMP4 init segment (once) then media segments (repeated).
class TwaiApiWsClient {
  TwaiApiWsClient({WebSocketChannelFactory? channelFactory})
      : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final WebSocketChannelFactory _channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _connected = false;

  final _ready = Completer<void>();
  final _binaryFrames = StreamController<Uint8List>();
  final _speakingEvents = StreamController<SpeakingEvent>();
  final _done = Completer<TwaiApiCloseReason>();

  /// Fires once when the gateway sends `session.ready`. Callers can
  /// await this before calling `/speak` to avoid a `stream_not_connected`
  /// bounce from the relay.
  Future<void> get ready => _ready.future;

  /// fMP4 binary frames from the server — init segment, then media
  /// segments.
  Stream<Uint8List> get binaryFrames => _binaryFrames.stream;

  /// `speaking` events (start/stop) with playback timestamps.
  Stream<SpeakingEvent> get speakingEvents => _speakingEvents.stream;

  /// Resolves when the WS closes.
  Future<TwaiApiCloseReason> get done => _done.future;

  /// Open the WebSocket at [url]. Does NOT send any handshake — the URL
  /// already carries the client_token as `?token=`. Server sends
  /// `session.ready` when the upstream muse socket is up.
  Future<void> connect(Uri url) async {
    if (_connected) {
      throw StateError('TwaiApiWsClient.connect called twice');
    }
    _connected = true;
    final ch = _channelFactory(url);
    _channel = ch;
    await ch.ready;
    _sub = ch.stream.listen(
      _onFrame,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic frame) {
    if (frame is Uint8List) {
      _binaryFrames.add(frame);
    } else if (frame is List<int>) {
      _binaryFrames.add(Uint8List.fromList(frame));
    } else if (frame is String) {
      _handleText(frame);
    }
  }

  void _handleText(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['type']) {
      case 'session.ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'speaking':
        try {
          _speakingEvents.add(SpeakingEvent.fromJson(decoded));
        } on FormatException {
          // Malformed — drop silently.
        }
      case 'session.closing':
      case null:
      default:
        // Unknown types get dropped so a future gateway addition doesn't
        // crash old SDKs. Diagnostics can bolt on later via a raw-frame
        // Stream if we need one.
        break;
    }
  }

  void _onError(Object error, StackTrace st) {
    if (!_done.isCompleted) {
      _done.complete(TwaiApiOtherClose(-1, error.toString()));
    }
    if (!_ready.isCompleted) {
      _ready.completeError(error, st);
    }
    if (!_binaryFrames.isClosed) _binaryFrames.addError(error, st);
    if (!_speakingEvents.isClosed) _speakingEvents.addError(error, st);
  }

  void _onDone() {
    final ch = _channel;
    final reason = twaiApiCloseFor(ch?.closeCode, ch?.closeReason);
    if (!_done.isCompleted) _done.complete(reason);
    if (!_ready.isCompleted) {
      _ready.completeError(
        TwaiApiTransportException(message: 'WS closed before session.ready'),
      );
    }
    if (!_binaryFrames.isClosed) _binaryFrames.close();
    if (!_speakingEvents.isClosed) _speakingEvents.close();
  }

  /// Close the WebSocket cleanly (code 1000). Non-blocking on the close
  /// handshake — some platforms hang on `close()` waiting for the peer.
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete(const TwaiApiNormalClose());
    final ch = _channel;
    if (ch != null) {
      unawaited(ch.sink.close(1000).catchError((_) {}));
    }
    await _sub?.cancel();
    if (!_binaryFrames.isClosed) await _binaryFrames.close();
    if (!_speakingEvents.isClosed) await _speakingEvents.close();
  }
}
