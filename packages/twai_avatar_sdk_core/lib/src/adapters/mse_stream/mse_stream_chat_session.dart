import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../chat_session.dart';
import '../../credentials.dart';
import 'chat_gateway.dart';
import 'chat_gateway_config.dart';
import 'chat_gateway_errors.dart';
import 'mood.dart';
import 'mse_stream_client.dart';
import 'mse_stream_config.dart';
import 'mse_stream_errors.dart';

/// `ChatSession` implementation for Adapter 1 (penthouse MSE-over-WS).
///
/// Combines [MseStreamClient] (`/ext-api/mse_stream`) and [ChatGateway]
/// (`/ext-api/human`) into one transport-agnostic surface. The WS
/// streams fragmented MP4; the HTTP POST returns the LLM reply text.
class MseStreamChatSession implements ChatSession {
  MseStreamChatSession({
    required this.baseUrl,
    required this.ttsSelection,
    required this.userId,
    TwaiCredentials? credentials,
    this.publishableKey,
    this.pathPrefix = '/ext-api',
    String? sessionId,
    WebSocketChannelFactory? channelFactory,
    http.Client? httpClient,
  })  : _credentials = TwaiCredentials.resolve(
          credentials: credentials,
          publishableKey: publishableKey,
        ),
        _sessionId = sessionId ?? MseStreamConfig.newSessionId(),
        _channelFactory = channelFactory,
        _httpClient = httpClient;

  /// Server base URL — e.g. `https://krystal-avatar.westus2.cloudapp.azure.com`.
  /// The WS URL is derived by swapping `https`→`wss` (or `http`→`ws`)
  /// and using path `$pathPrefix/mse_stream`.
  final Uri baseUrl;

  /// URL prefix for both the WS (`{prefix}/mse_stream`) and the HTTP
  /// chat gateway (`{prefix}/human`). Default `/ext-api` — the
  /// historical wav2lip stack. Muse-migrated avatars route through
  /// `/ext-api-muse`; ONNX dev variants through `/ext-api-onnx`.
  ///
  /// The right prefix per avatar is knowable from
  /// [AvatarCatalogEntry.stack] — callers should read that and pass
  /// the corresponding `AvatarStack.pathPrefix` here rather than
  /// hardcoding a string. Nginx has parallel `location` blocks for
  /// each prefix (`nginx-prod.conf`), each fronting its own
  /// `main_service` + inference worker pair.
  final String pathPrefix;

  /// TTS provider slot, e.g. `'tts5'`. Sent in both the WS handshake
  /// and every `/ext-api/human` POST.
  final String ttsSelection;

  /// Stable per-user id for brain-side memory scoping. `null` for anon.
  final String? userId;

  /// Legacy publishable-key shortcut — wrapped in [PublicKeyCredentials]
  /// if [credentials] wasn't passed. Prefer passing [credentials] directly;
  /// this parameter stays for back-compat with the pre-credentials API.
  final String? publishableKey;

  final TwaiCredentials _credentials;

  /// Resolved credentials in use — either the `credentials` constructor arg,
  /// a [PublicKeyCredentials] wrapping [publishableKey], or
  /// [AnonymousCredentials]. HTTP requests to the chat gateway get
  /// [TwaiCredentials.httpHeaders]; the WS URL gets
  /// [TwaiCredentials.wsQueryParams] (browsers can't set custom headers
  /// on the WebSocket handshake, so query params are the escape hatch).
  TwaiCredentials get credentials => _credentials;

  final String _sessionId;
  final WebSocketChannelFactory? _channelFactory;
  final http.Client? _httpClient;

  MseStreamClient? _ws;
  ChatGateway? _gateway;

  final _replyText = StreamController<String>.broadcast();
  final _speakingEvents = StreamController<SpeakingEvent>.broadcast();
  final _videoBytes = StreamController<Uint8List>.broadcast();
  final _moodEvents = StreamController<MoodEvent>.broadcast();
  final _done = Completer<ChatSessionEndReason>();

  StreamSubscription<Uint8List>? _binarySub;
  StreamSubscription<SpeakingEvent>? _speakingSub;

  /// The session id sent in the WS handshake + every chat POST. Exposed
  /// for diagnostics / logging.
  String get sessionId => _sessionId;

  @override
  Stream<String> get replyText => _replyText.stream;
  @override
  Stream<SpeakingEvent> get speakingEvents => _speakingEvents.stream;
  @override
  Stream<Uint8List> get videoBytes => _videoBytes.stream;
  // Adapter 1's brain lives server-side and there is no SDK-driven /speak
  // — clause pacing is a server concern. Empty stream satisfies the
  // interface without producing any hints for accumulate-then-play sinks.
  @override
  Stream<void> get speakBoundaries => const Stream<void>.empty();
  @override
  Future<ChatSessionEndReason> get done => _done.future;

  /// Brain-inferred mood for each chat turn, sourced from the
  /// `X-Mood` + `X-Mood-Humanized` response headers on
  /// `POST /ext-api/human` (penthouse Patches #62 / Mason 2026-06-15,
  /// echoed from the brain's SSE `event: mood` frame —
  /// `avatar-brain/src/core/mood/`).
  ///
  /// Emits zero or one [MoodEvent] per [sendMessage] turn. Headers
  /// absent or empty → no event. Concrete to this Adapter-1 session
  /// because Adapter 2 has no `X-Mood` path. Customers wanting to drive
  /// UI affordances from mood (avatar pose, background color, icon,
  /// tooltip) subscribe here.
  ///
  /// Each [MoodEvent] carries:
  /// - [MoodEvent.mood] — typed [Mood] enum; [Mood.unknown] when the
  ///   brain ships a new slug this SDK version doesn't recognize.
  /// - [MoodEvent.slug] — raw wire slug (forward-compat).
  /// - [MoodEvent.humanized] — per-avatar tooltip text or `null`.
  Stream<MoodEvent> get moodEvents => _moodEvents.stream;

  Uri get _wsUrl {
    final params = _credentials.wsQueryParams();
    return Uri(
      scheme: switch (baseUrl.scheme) {
        'https' => 'wss',
        'http' => 'ws',
        final s => s,
      },
      host: baseUrl.host,
      port: baseUrl.hasPort ? baseUrl.port : null,
      path: '$pathPrefix/mse_stream',
      queryParameters: params.isEmpty ? null : params,
    );
  }

  @override
  Future<void> connect(Avatar avatar) async {
    if (_ws != null) {
      throw const ChatSessionAlreadyConnectedException();
    }

    final ws = MseStreamClient(channelFactory: _channelFactory);
    final gateway = ChatGateway(
      baseUrl: baseUrl,
      config: ChatGatewayConfig(
        sessionId: _sessionId,
        avatarName: avatar.id,
        avatarVoice: avatar.voiceId ?? 'default',
        ttsSelection: ttsSelection,
        userId: userId,
      ),
      credentials: _credentials,
      pathPrefix: pathPrefix,
      httpClient: _httpClient,
    );

    _ws = ws;
    _gateway = gateway;

    _binarySub = ws.binaryFrames.listen(_videoBytes.add);
    _speakingSub = ws.speakingEvents.listen(_speakingEvents.add);
    // ignore: unawaited_futures
    ws.done.then(_onWsDone);

    try {
      await ws.connect(
        _wsUrl,
        MseStreamConfig(
          sessionId: _sessionId,
          avatarId: avatar.id,
          avatarVoice: avatar.voiceId ?? 'default',
          ttsSelection: ttsSelection,
        ),
      );
    } catch (e) {
      throw ChatSessionConnectException('WS connect failed: $e', e);
    }
  }

  void _onWsDone(MseStreamCloseReason reason) {
    if (_done.isCompleted) return;
    _done.complete(switch (reason) {
      NormalClose() => const ChatSessionClosed('WS closed normally'),
      ConfigError(reason: final m) =>
        ChatSessionFailed('Config error: $m', isPermanent: true),
      Unauthorized(code: final c, reason: final m) =>
        ChatSessionFailed(
          'Unauthorized (WS close $c): ${m.isEmpty ? "publishable key rejected" : m}',
          isPermanent: true,
        ),
      ServerError(reason: final m) =>
        ChatSessionFailed('Server error: $m', isPermanent: true),
      OtherClose(code: final c, reason: final m) =>
        ChatSessionFailed('WS closed (code=$c): $m'),
    });
  }

  @override
  Future<void> sendMessage(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) async {
    final gateway = _gateway;
    if (gateway == null || _done.isCompleted) {
      throw const ChatSessionNotConnectedException();
    }
    try {
      final response = await gateway.sendMessage(
        text,
        gamificationLevel: gamificationLevel,
        avatarStateBlock: avatarStateBlock,
      );
      _replyText.add(response.replyText);
      final moodEvent = MoodEvent.fromHeaders(
        slug: response.mood,
        humanized: response.moodHumanized,
      );
      if (moodEvent != null) {
        _moodEvents.add(moodEvent);
      }
    } on ChatUnauthorizedException catch (e) {
      throw ChatSessionUnauthorizedException(
          'POST /ext-api/human: 401 — ${e.body}', e);
    } on ChatForbiddenException catch (e) {
      throw ChatSessionForbiddenException(
          'POST /ext-api/human: 403 — ${e.body}', e);
    } on ChatRateLimitedException catch (e) {
      throw ChatSessionRateLimitedException(
          'POST /ext-api/human: 429 — ${e.body}', e);
    } on ChatGatewayException catch (e) {
      throw ChatSessionSendException('POST /ext-api/human failed: ${e.message}', e);
    }
  }

  @override
  Future<void> close() async {
    if (_done.isCompleted && _ws == null) return;

    if (!_done.isCompleted) {
      _done.complete(const ChatSessionClosed());
    }

    await _binarySub?.cancel();
    await _speakingSub?.cancel();
    await _ws?.close();
    _gateway?.close();

    if (!_replyText.isClosed) await _replyText.close();
    if (!_speakingEvents.isClosed) await _speakingEvents.close();
    if (!_videoBytes.isClosed) await _videoBytes.close();
    if (!_moodEvents.isClosed) await _moodEvents.close();
  }
}
