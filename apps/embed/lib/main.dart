// 2wai Avatar Web Component (Flutter) on Transport 0 (LiveKit).
//
// Migrated from the Adapter 1 MSE-over-WebSocket embed 2026-09-04 after
// ADR-045 / ADR-049 retired MSE as a live-chat wire. Same custom-element
// API surface (`<twai-avatar>` / `<twai-chat>` + imperative bridge +
// CustomEvents), new wire underneath.
//
// **Companion:** JS/TS Web Component at 2waiorg/twai-web-sdk
// (`@twai/web-component`). Both provide the same drop-in `<twai-avatar>`
// pattern for non-framework HTML pages — pick whichever runtime you
// prefer (Flutter renders on canvas + ships a larger bundle; the JS
// version renders on the browser's <video> element + is smaller). The
// wire, mint proxy contract, and event surface are identical.
//
// Boot sequence:
//   1. Customer drops `<script src="embed.js">` + `<twai-avatar ...>` or
//      `<twai-chat ...>` in their HTML.
//   2. embed.js registers the custom elements; on the first connected
//      element, it stashes the element on `window.__twaiHostElement`,
//      then loads Flutter's engine loader and runs us.
//   3. We read the host element + attributes via [readEmbedConfig].
//   4. We build a mint closure targeting the customer's mint proxy,
//      hand it to TwaiTransport0Player (via avatar_widget or chat_widget
//      depending on tag name), and wire T0 lifecycle events into the
//      JS CustomEvent bridge.
//   5. We publish the imperative API (`connect` / `disconnect` / `send`
//      / mic controls / `sessionId`) back to JS.
//
// Required HTML attributes: avatar-id, mint-proxy-url.
// Recommended: idle-url. Optional: voice-id.

import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

import 'src/avatar_widget.dart';
import 'src/chat_widget.dart';
import 'src/embed_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(_EmbedRoot(config: readEmbedConfig()));
}

class _EmbedRoot extends StatefulWidget {
  const _EmbedRoot({required this.config});
  final EmbedConfig? config;

  @override
  State<_EmbedRoot> createState() => _EmbedRootState();
}

class _EmbedRootState extends State<_EmbedRoot> {
  TwaiApiRestClient? _rest;
  Transcriber? _transcriber;
  t0.LiveKitEngine? _engine;
  String? _sessionId;
  String? _bootError;

  @override
  void initState() {
    super.initState();
    final cfg = widget.config;
    if (cfg == null) {
      _bootError = 'twai_embed must be loaded via embed.js with a '
          '<twai-avatar> or <twai-chat> element on the page.';
      return;
    }
    _bootstrap(cfg);
  }

  void _bootstrap(EmbedConfig cfg) {
    if (cfg.avatarId == null || cfg.mintProxyUrl == null) {
      _bootError = '<${cfg.tagName}> requires avatar-id and mint-proxy-url attributes '
          '(voice-id and idle-url are optional).';
      return;
    }

    final Uri mintUri;
    try {
      mintUri = Uri.parse(cfg.mintProxyUrl!);
    } catch (e) {
      _bootError = 'Bad mint-proxy-url: $e';
      return;
    }

    _rest = TwaiApiRestClient(
      baseUrl: mintUri,
      credentials: const AnonymousCredentials(),
    );
    // stt-url attribute takes precedence: server-side Whisper. When
    // absent, the zero-config DefaultTranscriber (browser SpeechRecognition
    // on web, speech_to_text on native builds we might target later).
    final sttUrl = cfg.sttUrl;
    _transcriber = (sttUrl != null && sttUrl.isNotEmpty)
        ? HttpSttTranscriber(endpoint: Uri.parse(sttUrl))
        : DefaultTranscriber();

    // Publish the JS bridge immediately so the host page can call
    // element.send() / element.startListening() etc. Individual calls
    // gracefully no-op until the engine is bound.
    publishBridge(
      connect: _connect,
      disconnect: _disconnect,
      send: _send,
      startListening: _startListening,
      stopListening: _stopListening,
      cancelListening: _cancelListening,
      voiceInputAvailable: () => _transcriber?.isAvailable ?? false,
      sessionId: () => _sessionId,
    );
  }

  // ─── Mint closure ────────────────────────────────────────────────
  //
  // Called by TwaiTransport0Player on mount (and on reconnect if the
  // room ends transportly). Captures the session_id so the bridge can
  // expose it to JS callers.
  Future<t0.MintResult> _mint() async {
    final cfg = widget.config!;
    final rest = _rest!;
    try {
      final voiceId = (cfg.voiceId ?? '').startsWith('vc_') ? cfg.voiceId : null;
      final m = await rest.createLiveKitSession(
        TwaiApiLiveKitSessionRequest(
          avatarId: cfg.avatarId!,
          voiceId: voiceId,
        ),
      );
      _sessionId = m.sessionId;
      return t0.MintResultEnabled(
        url: m.livekitUrl.toString(),
        token: m.participantToken,
        room: m.roomName,
      );
    } on TwaiApiRateLimitedException catch (e) {
      final retry = e.retryAfterSeconds ?? 60;
      dispatchEvent(cfg.element, 'error',
          detail: ErrorDetail(
            kind: 'mint-rate-limited',
            message: 'Rate limited by mint proxy; retry after ${retry}s',
            permanent: false,
          ));
      throw t0.MintRateLimited(retry);
    } catch (e) {
      dispatchEvent(cfg.element, 'error',
          detail: ErrorDetail(
            kind: 'mint-unavailable',
            message: 'Mint proxy unreachable: $e',
            permanent: false,
          ));
      throw t0.MintUnavailable('gateway mint failed: $e', cause: e);
    }
  }

  // ─── Bridge implementations ──────────────────────────────────────
  //
  // On T0, the engine and its underlying LiveKit room lifecycle are
  // owned by TwaiTransport0Player, not by us. `connect` is a no-op —
  // the widget mounts and mints on its own. `disconnect` disposes.
  // `send` is what does actual work.

  Future<void> _connect() async {
    // TwaiTransport0Player auto-connects on mount. Nothing to do here
    // in the T0 model; this method exists for API-compat with the MSE
    // era where the page controlled connect/disconnect.
  }

  Future<void> _disconnect() async {
    final e = _engine;
    if (e == null) return;
    await e.disconnect();
    _engine = null;
    _sessionId = null;
  }

  Future<void> _send(String text) async {
    final engine = _engine;
    final cfg = widget.config!;
    if (engine == null) {
      dispatchEvent(cfg.element, 'error',
          detail: ErrorDetail(
            kind: 'unknown',
            message: 'send() called before engine bound',
            permanent: false,
          ));
      return;
    }
    try {
      await engine.send(text);
    } catch (e) {
      dispatchEvent(cfg.element, 'error',
          detail: ErrorDetail(
            kind: 'unknown',
            message: 'send failed: $e',
            permanent: false,
          ));
      rethrow;
    }
  }

  Future<void> _startListening() async {
    final transcriber = _transcriber;
    final cfg = widget.config!;
    if (transcriber == null) return;
    final ok = await transcriber.initialize();
    if (!ok) {
      dispatchEvent(cfg.element, 'error',
          detail: _transcriberErrorDetail(TranscriberError.notSupported));
      return;
    }
    // Transcript events → page-level CustomEvents. Each event fires
    // either 'transcript' (interim, isFinal=false) or 'transcript-final'
    // (committed).
    transcriber.transcripts.listen((ev) {
      dispatchEvent(
        cfg.element,
        ev.isFinal ? 'transcript-final' : 'transcript',
        detail: ev.text.toJS,
      );
    });
    transcriber.errors.listen((err) {
      dispatchEvent(cfg.element, 'error', detail: _transcriberErrorDetail(err));
    });
    await transcriber.start();
  }

  Future<void> _stopListening() async => _transcriber?.stop();
  Future<void> _cancelListening() async => _transcriber?.cancel();

  ErrorDetail _transcriberErrorDetail(TranscriberError err) {
    final (String kind, String message, bool permanent) = switch (err) {
      TranscriberError.permissionDenied => (
          'voice-permission-denied',
          'Microphone permission denied',
          true,
        ),
      TranscriberError.noSpeech => (
          'voice-no-speech',
          'No speech detected',
          false,
        ),
      TranscriberError.networkError => (
          'voice-network-error',
          'Speech recognizer network failure',
          false,
        ),
      TranscriberError.notSupported => (
          'voice-not-supported',
          'Voice input not available on this platform / browser',
          true,
        ),
      TranscriberError.other => (
          'voice-error',
          'Voice input failed',
          false,
        ),
    };
    return ErrorDetail(kind: kind, message: message, permanent: permanent);
  }

  // ─── T0 event → JS CustomEvent wiring ────────────────────────────
  //
  // These callbacks are what avatar_widget and chat_widget invoke.

  void _onEngineBound(t0.LiveKitEngine e) {
    _engine = e;
  }

  void _onState(t0.EngineState s) {
    final host = widget.config!.element;
    if (s == t0.EngineState.ready) {
      dispatchEvent(host, 'connected');
    } else if (s == t0.EngineState.ended) {
      dispatchEvent(host, 'disconnected');
    }
  }

  void _onSpeaking(t0.SpeakingActiveEvent e) {
    dispatchEvent(widget.config!.element,
        e.active ? 'speaking-start' : 'speaking-end');
  }

  void _onReplyText(t0.ReplyTextEvent e) {
    dispatchEvent(widget.config!.element, 'reply', detail: e.text.toJS);
  }

  void _onEnded(t0.EndedEvent e) {
    dispatchEvent(widget.config!.element, 'disconnected',
        detail: e.cause.name.toJS);
  }

  void _onEngineError(Object err) {
    // Best-effort classification — TwaiTransport0Player's onError
    // surfaces mint / connect failures (typed via mintHelpers)
    // plus any uncaught exception in the engine's internal futures.
    final message = err.toString();
    final (String kind, bool permanent) = err is t0.MintRateLimited
        ? ('mint-rate-limited', false)
        : err is t0.MintUnavailable
            ? ('mint-unavailable', false)
            : ('unknown', false);
    dispatchEvent(widget.config!.element, 'error',
        detail: ErrorDetail(
            kind: kind, message: message, permanent: permanent));
  }

  @override
  void dispose() {
    final e = _engine;
    if (e != null) {
      // ignore: discarded_futures
      e.disconnect();
    }
    _transcriber?.dispose();
    _rest?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'twai embed',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(backgroundColor: Colors.black, body: _buildBody()),
      );

  Widget _buildBody() {
    if (_bootError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _bootError!,
            style: const TextStyle(
                color: Colors.redAccent, fontFamily: 'monospace'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final cfg = widget.config!;
    return cfg.isChatMode
        ? TwaiChatWidget(
            mint: _mint,
            idleUrl: cfg.idleUrl,
            transcriber: _transcriber!,
            onEngineBound: _onEngineBound,
            onState: _onState,
            onSpeaking: _onSpeaking,
            onReplyText: _onReplyText,
            onEnded: _onEnded,
            onError: _onEngineError,
          )
        : TwaiAvatarWidget(
            mint: _mint,
            idleUrl: cfg.idleUrl,
            onEngine: _onEngineBound,
            onState: _onState,
            onSpeaking: _onSpeaking,
            onReplyText: _onReplyText,
            onEnded: _onEnded,
            onError: _onEngineError,
          );
  }
}
