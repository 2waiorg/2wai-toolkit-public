/// `ChatSession` implementation for Adapter 4 — the twai-api (`/v1/*`)
/// wire (2waiorg/twai-api, deployed 2026-07-25).
///
/// # Where the brain lives
///
/// Unlike Adapter 1 (which owns the LLM server-side) and Adapter 2
/// (same), the twai-api gateway has no brain. `sendMessage(text)` on
/// this session goes to `POST /v1/sessions/{sid}/speak` — the avatar
/// says the *literal* text.
///
/// Two ways to get real conversation on top of this:
///
/// 1. **Provide a [brain] callback** — the SDK calls it with the user's
///    turn, gets back the reply, then ships that reply to `/speak`.
///    The reply flows out on [replyText] as if it came from a
///    server-side brain. This is the usable path for real apps.
///
/// 2. **Skip [brain]** — the SDK treats every `sendMessage(text)` as
///    "make the avatar literally say this text". Useful for demos,
///    prompts baked into a scripted tour, or as a `Text-to-Speech`
///    endpoint the customer app drives directly. This is the dev-echo
///    default.
///
/// # Two credential modes (dev vs prod)
///
/// - **Dev direct**: SDK holds an `sk_` key in a [TwaiApiKeyCredentials]
///   and calls `/v1/*` directly. Only appropriate for hobbyist prototypes,
///   internal tools, and Mason's own dev harnesses — an `sk_` in a
///   browser is per-user compromise.
///
/// - **Prod split-plane**: the customer runs a small mint-proxy server
///   that holds the `sk_`; the SDK talks to that proxy. Advanced users
///   construct a [TwaiApiRestClient] pointed at their proxy and pass it
///   as [restClient]. Step 5 (`apps/twai_api_starter`) ships reference
///   proxies in Node / Python / Cloudflare Worker.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../chat_session.dart';
import '../mse_stream/mse_stream_client.dart' show WebSocketChannelFactory;
import '../mse_stream/mse_stream_config.dart' show SpeakingEvent;
import 'twai_api_client.dart';
import 'twai_api_config.dart';
import 'twai_api_errors.dart';

/// The customer's brain callback: user turn → reply the avatar should
/// speak. Async so real LLM calls fit. Errors propagate to the caller
/// of [ChatSession.sendMessage] as a [ChatSessionSendException].
typedef TwaiBrainCallback = Future<String> Function(String userText);

/// The streaming variant of [TwaiBrainCallback]. The brain implementation
/// is handed a [speak] closure and is expected to call it per sentence as
/// the LLM streams — the pattern Mason's `apimila-demo` uses (see
/// `apimila-demo/app/main.py::_stream_brain_to_speech`). Time-to-first-word
/// drops from ~full-turn-latency to ~first-sentence-latency because the
/// avatar starts speaking after the first sentence lands, not after the
/// whole reply finishes generating.
///
/// The closure passed to the callback is bound to the current session id
/// and posts `POST /v1/sessions/{sid}/speak` per invocation. The callback
/// returns the FULL reply text (for caption / logging); the SDK does NOT
/// call `/speak` on the return value — the brain has already driven every
/// `/speak` call itself via [speak].
///
/// Errors from [speak] surface as whatever the underlying
/// [TwaiApiRestClient] throws (typically [TwaiApiException] subclasses).
/// The brain implementation may catch and continue (skip a failed
/// sentence) or rethrow to fail the whole turn.
typedef TwaiStreamingBrainCallback = Future<String> Function(
  String userText,
  Future<void> Function(String sentence) speak,
);

class TwaiApiChatSession implements ChatSession {
  /// Prefer this constructor when you already have a [TwaiApiRestClient]
  /// wired up (e.g. via `TwaiClient.apiSession()` or a customer proxy).
  ///
  /// Pass [brain] for the single-shot pattern (customer computes full
  /// reply, SDK sends one `/speak`). Pass [streamingBrain] for the
  /// sentence-streaming pattern (customer drives per-sentence `/speak`
  /// as their LLM streams). Exactly one may be non-null. If both are
  /// null, sendMessage echoes the user text to `/speak` verbatim.
  TwaiApiChatSession({
    required TwaiApiRestClient restClient,
    TwaiBrainCallback? brain,
    TwaiStreamingBrainCallback? streamingBrain,
    WebSocketChannelFactory? channelFactory,
  })  : assert(brain == null || streamingBrain == null,
            'Pass either brain OR streamingBrain, not both.'),
        _rest = restClient,
        _brain = brain,
        _streamingBrain = streamingBrain,
        _channelFactory = channelFactory;

  final TwaiApiRestClient _rest;
  final TwaiBrainCallback? _brain;
  final TwaiStreamingBrainCallback? _streamingBrain;
  final WebSocketChannelFactory? _channelFactory;

  TwaiApiSessionMint? _mint;
  TwaiApiWsClient? _ws;
  StreamSubscription<Uint8List>? _binarySub;
  StreamSubscription<SpeakingEvent>? _speakingSub;

  final _replyText = StreamController<String>.broadcast();
  final _speakingEvents = StreamController<SpeakingEvent>.broadcast();
  final _videoBytes = StreamController<Uint8List>.broadcast();
  // Emits after each internally-initiated `/speak` REST completes — the
  // "next clause is on its way" signal that native accumulate-then-play
  // sinks use to short-circuit their tail-window and seal per clause.
  // See ChatSession.speakBoundaries dartdoc for the full contract.
  final _speakBoundaries = StreamController<void>.broadcast();
  final _done = Completer<ChatSessionEndReason>();

  /// The gateway-assigned session id (from POST /v1/sessions). Null
  /// until [connect] resolves.
  String? get sessionId => _mint?.sessionId;

  @override
  Stream<String> get replyText => _replyText.stream;
  @override
  Stream<SpeakingEvent> get speakingEvents => _speakingEvents.stream;
  @override
  Stream<Uint8List> get videoBytes => _videoBytes.stream;
  @override
  Stream<void> get speakBoundaries => _speakBoundaries.stream;
  @override
  Future<ChatSessionEndReason> get done => _done.future;

  @override
  Future<void> connect(Avatar avatar) async {
    if (_ws != null) {
      throw const ChatSessionAlreadyConnectedException();
    }

    final TwaiApiSessionMint mint;
    try {
      mint = await _rest.createSession(TwaiApiSessionRequest(
        avatarId: avatar.id,
        voiceId: avatar.voiceId,
      ));
    } on TwaiApiUnauthorizedException catch (e) {
      throw ChatSessionUnauthorizedException(
          'POST /v1/sessions: 401 — ${e.body}', e);
    } on TwaiApiForbiddenException catch (e) {
      throw ChatSessionForbiddenException(
          'POST /v1/sessions: 403 — ${e.body}', e);
    } on TwaiApiException catch (e) {
      throw ChatSessionConnectException(
          'POST /v1/sessions failed: ${e.message}', e);
    }
    _mint = mint;

    final ws = TwaiApiWsClient(channelFactory: _channelFactory);
    _ws = ws;
    _binarySub = ws.binaryFrames.listen(_videoBytes.add);
    _speakingSub = ws.speakingEvents.listen(_speakingEvents.add);
    // ignore: unawaited_futures
    ws.done.then(_onWsDone);

    try {
      await ws.connect(mint.websocketUrl);
      await ws.ready;
    } on Exception catch (e) {
      throw ChatSessionConnectException('WS connect failed: $e', e);
    }
  }

  void _onWsDone(TwaiApiCloseReason reason) {
    if (_done.isCompleted) return;
    _done.complete(switch (reason) {
      TwaiApiNormalClose() => const ChatSessionClosed('WS closed normally'),
      TwaiApiTokenRejected(reason: final r) => ChatSessionFailed(
          'client_token rejected (WS 4401): ${r.isEmpty ? "expired or invalid" : r}',
          isPermanent: true,
        ),
      TwaiApiConfigMismatch(reason: final r) => ChatSessionFailed(
          'session config mismatch (WS 4403): $r',
          isPermanent: true,
        ),
      TwaiApiOtherClose(code: final c, reason: final r) => ChatSessionFailed(
          'WS closed (code=$c): $r',
        ),
    });
  }

  @override
  Future<void> sendMessage(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) async {
    // gamificationLevel + avatarStateBlock are Adapter-1-only fields
    // (the penthouse brain reads them). Adapter 4 ignores them — the
    // customer's brain callback can accept extra context via closure if
    // it needs to.
    final mint = _mint;
    if (mint == null || _done.isCompleted) {
      throw const ChatSessionNotConnectedException();
    }

    // Brain modes (mutually exclusive; asserted in the ctor):
    //  - _streamingBrain: brain drives per-sentence /speak itself via the
    //    closure we pass. SDK does NOT call /speak on the returned string
    //    (brain already spoke it). Time-to-first-word ≈ first sentence.
    //  - _brain: brain returns full reply. SDK does one /speak. Simpler,
    //    time-to-first-word ≈ whole-turn latency.
    //  - neither: echo mode. SDK /speaks the user's text verbatim.
    final String reply;
    if (_streamingBrain != null) {
      // The speak closure the brain calls per sentence. Errors from any
      // one /speak surface to the brain implementation — it may catch +
      // continue or rethrow to fail the turn.
      Future<void> speakSentence(String sentence) async {
        try {
          await _rest.speak(mint.sessionId, sentence);
        } on TwaiApiUnauthorizedException catch (e) {
          throw ChatSessionUnauthorizedException(
              'POST /v1/sessions/{sid}/speak: 401 — ${e.body}', e);
        } on TwaiApiForbiddenException catch (e) {
          throw ChatSessionForbiddenException(
              'POST /v1/sessions/{sid}/speak: 403 — ${e.body}', e);
        } on TwaiApiRateLimitedException catch (e) {
          throw ChatSessionRateLimitedException(
              'POST /v1/sessions/{sid}/speak: 429 — ${e.body}', e);
        } on TwaiApiException catch (e) {
          throw ChatSessionSendException(
              'POST /v1/sessions/{sid}/speak failed: ${e.message}', e);
        }
        _speakBoundaries.add(null);
      }

      try {
        reply = await _streamingBrain(text, speakSentence);
      } on ChatSessionException {
        rethrow; // /speak error already wrapped by speakSentence
      } on Exception catch (e) {
        throw ChatSessionSendException('streaming brain callback threw: $e', e);
      }
      // SDK skips its own /speak — the brain called speakSentence per clause.
      _replyText.add(reply);
      return;
    }

    if (_brain != null) {
      try {
        reply = await _brain(text);
      } on Exception catch (e) {
        throw ChatSessionSendException('brain callback threw: $e', e);
      }
    } else {
      reply = text;
    }

    try {
      await _rest.speak(mint.sessionId, reply);
    } on TwaiApiUnauthorizedException catch (e) {
      throw ChatSessionUnauthorizedException(
          'POST /v1/sessions/{sid}/speak: 401 — ${e.body}', e);
    } on TwaiApiForbiddenException catch (e) {
      throw ChatSessionForbiddenException(
          'POST /v1/sessions/{sid}/speak: 403 — ${e.body}', e);
    } on TwaiApiRateLimitedException catch (e) {
      throw ChatSessionRateLimitedException(
          'POST /v1/sessions/{sid}/speak: 429 — ${e.body}', e);
    } on TwaiApiException catch (e) {
      throw ChatSessionSendException(
          'POST /v1/sessions/{sid}/speak failed: ${e.message}', e);
    }
    _speakBoundaries.add(null);

    _replyText.add(reply);
  }

  /// Flush the current utterance. Adapter-4 specific — not on the
  /// [ChatSession] interface, but useful for barge-in UX.
  Future<void> interrupt() async {
    final mint = _mint;
    if (mint == null) return;
    try {
      await _rest.interrupt(mint.sessionId);
    } on TwaiApiException {
      // Interrupt is best-effort — swallow errors so the app can retry
      // the next user turn cleanly.
    }
  }

  @override
  Future<void> close() async {
    if (_done.isCompleted && _ws == null && _mint == null) return;
    if (!_done.isCompleted) {
      _done.complete(const ChatSessionClosed());
    }

    await _binarySub?.cancel();
    await _speakingSub?.cancel();
    await _ws?.close();

    final mint = _mint;
    if (mint != null) {
      try {
        await _rest.deleteSession(mint.sessionId);
      } on TwaiApiException {
        // DELETE is best-effort — the gateway's idle reaper will clean
        // up after `session_idle_reap_seconds` even if we can't reach it.
      }
    }
    // Rest client lifecycle is the caller's — same pattern as
    // TwaiClient's shared http.Client across sessions. Don't close it
    // here; a factory that owns it (TwaiClient.apiSession) releases it
    // in TwaiClient.close().

    if (!_replyText.isClosed) await _replyText.close();
    if (!_speakingEvents.isClosed) await _speakingEvents.close();
    if (!_videoBytes.isClosed) await _videoBytes.close();
    if (!_speakBoundaries.isClosed) await _speakBoundaries.close();
  }
}
