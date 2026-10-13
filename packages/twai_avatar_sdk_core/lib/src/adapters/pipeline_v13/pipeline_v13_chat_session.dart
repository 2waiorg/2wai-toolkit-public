import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../chat_session.dart';
import '../../credentials.dart';
import '../mse_stream/mse_stream_config.dart' show SpeakingEvent;
import 'pipeline_v13_client.dart';
import 'pipeline_v13_config.dart';
import 'pipeline_v13_errors.dart';

/// `ChatSession` implementation for Adapter 2 (v1.3 `POST /chat` → MP4).
///
/// Wraps [PipelineV13Client]. Each [sendMessage] is one POST that
/// returns a complete MP4 + reply text. No persistent connection;
/// [connect] is purely local configuration.
///
/// History is tracked internally: every turn appends to a per-session
/// history list that gets sent with subsequent POSTs.
class PipelineV13ChatSession implements ChatSession {
  PipelineV13ChatSession({
    required this.baseUrl,
    TwaiCredentials? credentials,
    this.publishableKey,
    http.Client? httpClient,
  })  : _credentials = TwaiCredentials.resolve(
          credentials: credentials,
          publishableKey: publishableKey,
        ),
        _httpClient = httpClient;

  /// Server base URL — e.g. `https://krystal-avatar.westus2.cloudapp.azure.com`.
  /// `/chat` is resolved against this.
  final Uri baseUrl;

  /// Legacy publishable-key shortcut — wrapped in [PublicKeyCredentials]
  /// if `credentials` wasn't passed. Prefer `credentials:` directly.
  final String? publishableKey;

  final TwaiCredentials _credentials;
  final http.Client? _httpClient;

  /// Resolved credentials in use.
  TwaiCredentials get credentials => _credentials;

  PipelineV13Client? _client;
  final List<Map<String, dynamic>> _history = [];

  final _replyText = StreamController<String>.broadcast();
  final _speakingEvents = StreamController<SpeakingEvent>.broadcast();
  final _videoBytes = StreamController<Uint8List>.broadcast();
  final _done = Completer<ChatSessionEndReason>();

  /// Read-only view of conversation history (user + assistant turns).
  /// Maintained automatically as messages are sent and replies received.
  List<Map<String, dynamic>> get history => List.unmodifiable(_history);

  @override
  Stream<String> get replyText => _replyText.stream;

  /// Always empty for Adapter 2 — the consumer's video player drives
  /// speaking state directly.
  @override
  Stream<SpeakingEvent> get speakingEvents => _speakingEvents.stream;

  @override
  Stream<Uint8List> get videoBytes => _videoBytes.stream;

  // Adapter 2 delivers one full MP4 per turn via POST /chat and has no
  // SDK-driven /speak. Empty stream — sinks that would seal on a
  // boundary have nothing to gate against.
  @override
  Stream<void> get speakBoundaries => const Stream<void>.empty();

  @override
  Future<ChatSessionEndReason> get done => _done.future;

  @override
  Future<void> connect(Avatar avatar) async {
    if (_client != null) {
      throw const ChatSessionAlreadyConnectedException();
    }
    _client = PipelineV13Client(
      baseUrl: baseUrl,
      config: PipelineV13Config(avatar: avatar.id, voiceId: avatar.voiceId),
      credentials: _credentials,
      httpClient: _httpClient,
    );
    // No network call — Adapter 2 is request/response. Session is
    // ready to sendMessage immediately.
  }

  @override
  Future<void> sendMessage(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) async {
    // Adapter 2 ignores [gamificationLevel] + [avatarStateBlock]. The
    // v1.3 request/response server (`2wai-avatar-pipeline/server.py`)
    // doesn't accept them — POST /chat takes only `{message, history}`.
    // Accepting them here keeps the [ChatSession] interface uniform so
    // callers can write transport-agnostic code; the fields silently
    // degrade to no-op against an Adapter 2 backend.
    final client = _client;
    if (client == null || _done.isCompleted) {
      throw const ChatSessionNotConnectedException();
    }
    try {
      final response = await client.chat(text, history: List.of(_history));
      _history.add({'role': 'user', 'content': text});
      _history.add({'role': 'assistant', 'content': response.replyText});
      _replyText.add(response.replyText);
      _videoBytes.add(response.videoBytes);
    } on PipelineV13UnauthorizedException catch (e) {
      throw ChatSessionUnauthorizedException('POST /chat: 401 — ${e.body}', e);
    } on PipelineV13ForbiddenException catch (e) {
      throw ChatSessionForbiddenException('POST /chat: 403 — ${e.body}', e);
    } on PipelineV13RateLimitedException catch (e) {
      throw ChatSessionRateLimitedException('POST /chat: 429 — ${e.body}', e);
    } on PipelineV13Exception catch (e) {
      throw ChatSessionSendException('POST /chat failed: ${e.message}', e);
    }
  }

  @override
  Future<void> close() async {
    if (_done.isCompleted && _client == null) return;
    if (!_done.isCompleted) {
      _done.complete(const ChatSessionClosed());
    }
    _client?.close();
    _client = null;
    if (!_replyText.isClosed) await _replyText.close();
    if (!_speakingEvents.isClosed) await _speakingEvents.close();
    if (!_videoBytes.isClosed) await _videoBytes.close();
  }
}
