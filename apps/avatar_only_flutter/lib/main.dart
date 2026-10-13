// candy_demo — Flutter twin of Mason's apimila-demo, migrated to
// Transport 0 (LiveKit) — the wire since 2026-08-22 (ADR-045 / ADR-049).
//
// Adapter shape: **T0 + BYO brain (Option β)** — customer's LLM
// generates reply text, app POSTs `/v1/sessions/:sid/speak` directly.
// Same shape as apps/twai_api_starter, wired to a live Candy-like mock
// brain that returns in-character Mila replies. The SDK is only the
// render layer; Candy owns the LLM.
//
// **INTERNAL VALIDATION artifact — NOT a customer pitch tool.**
// Per the 2026-07-28 Jim/Mason conversation: this app exists so we can
// stress-test the SDK against Mila continuously. Every fix that lands
// here is proof the SDK holds up under real load.
//
// RUN
//   1. Start the mint proxy (any of apps/mint_proxy_examples/) with
//      Mila's sk_ in the env. Node default:
//        $env:SK_KEY = "sk_..."; node apps/mint_proxy_examples/node/server.js
//   2. Start the mock Candy brain in a spare shell:
//        python apps/candy_demo/mock_candy_brain/server.py
//   3. cp apps/candy_demo/.env.example apps/candy_demo/.env
//      (edit URLs if not the defaults)
//   4. cd apps/candy_demo
//      flutter run -d web-server --web-port 5175 --dart-define-from-file=.env
//      flutter run -d <android-device> --dart-define-from-file=.env
//      flutter run -d <iphone>      --dart-define-from-file=.env

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

const _kMintProxyUrl = String.fromEnvironment(
  'MINT_PROXY_URL',
  defaultValue: 'http://localhost:8787',
);
const _kBrainUrl = String.fromEnvironment(
  'BRAIN_URL',
  defaultValue: 'http://localhost:9090/reply',
);
// Mila on the toolkit-demo tenant (`ten_0e2277049d82a22bbb02ed30`), verified
// working 2026-08-16.
const _kAvatarId = String.fromEnvironment(
  'AVATAR_ID',
  defaultValue: 'avt_441ad4d95906438490a85b79',
);
const _kVoiceId = String.fromEnvironment(
  'VOICE_ID',
  defaultValue: 'vc_e72e888d566aca3a4e63fbe8',
);
const _kIdleUrl = String.fromEnvironment(
  'IDLE_URL',
  defaultValue:
      'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4',
);
// Optional server-side STT endpoint. See other apps for the same shape.
const _kSttUrl = String.fromEnvironment('STT_URL', defaultValue: '');

// Palette — Candy-ish pink accent on deep bg.
const _accent = Color(0xFFEB50B8);
const _bg = Color(0xFF0F1015);
const _panel = Color(0xFF1B1D24);
const _panelBorder = Color(0xFF2E3542);

void main() => runApp(const CandyDemoApp());

class CandyDemoApp extends StatelessWidget {
  const CandyDemoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'candy_demo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          scaffoldBackgroundColor: _bg,
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            surface: _panel,
          ),
        ),
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final TwaiApiRestClient _rest;
  late final Transcriber _transcriber;
  final _brainClient = http.Client();
  final _messages = <_Msg>[];
  final _input = TextEditingController();
  t0.LiveKitEngine? _engine;
  t0.EngineState _state = t0.EngineState.idle;
  String? _sessionId;
  bool _brainBusy = false;
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    _rest = TwaiApiRestClient(
      baseUrl: Uri.parse(_kMintProxyUrl),
      credentials: const AnonymousCredentials(),
    );
    _transcriber = _kSttUrl.isNotEmpty
        ? HttpSttTranscriber(endpoint: Uri.parse(_kSttUrl))
        : DefaultTranscriber();
  }

  Future<t0.MintResult> _mint() async {
    try {
      final voiceId = _kVoiceId.startsWith('vc_') ? _kVoiceId : null;
      final m = await _rest.createLiveKitSession(
        TwaiApiLiveKitSessionRequest(
          avatarId: _kAvatarId,
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
      throw t0.MintRateLimited(e.retryAfterSeconds ?? 60);
    } catch (e) {
      throw t0.MintUnavailable('gateway mint failed: $e', cause: e);
    }
  }

  // ─── The BYO-brain loop ────────────────────────────────────────────
  //
  // 1) User types → append to log.
  // 2) POST to Candy's mock brain (customer LLM in prod) → get reply text.
  // 3) POST to /v1/sessions/:sid/speak with the reply → avatar renders it
  //    on the LiveKit tracks.
  //
  // The SDK is only the render layer here — Candy owns the LLM entirely.
  // In a real integration, `_kBrainUrl` points at Candy's LLM service and
  // this loop is where per-clause streaming would happen (SSE from brain,
  // one /speak call per completed clause). See apps/enlighten for the
  // streaming variant.
  Future<void> _send() async {
    if (_brainBusy || _state != t0.EngineState.ready) return;
    final sid = _sessionId;
    if (sid == null) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _appendMsg(_Msg.user(text));
    setState(() => _brainBusy = true);
    try {
      final reply = await _callBrain(text);
      _appendMsg(_Msg.mila(reply));
      await _rest.speak(sid, reply);
    } catch (e) {
      _appendMsg(_Msg.system('send failed: $e'));
    } finally {
      if (mounted) setState(() => _brainBusy = false);
    }
  }

  Future<String> _callBrain(String userText) async {
    try {
      final resp = await _brainClient.post(
        Uri.parse(_kBrainUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': userText}),
      );
      if (resp.statusCode != 200) return '(brain returned ${resp.statusCode})';
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      return decoded['reply'] as String? ?? '(brain returned no reply)';
    } on Exception catch (e) {
      return '(brain unreachable: $e)';
    }
  }

  @override
  void dispose() {
    final sid = _sessionId;
    if (sid != null) {
      unawaited(_rest.deleteSession(sid).catchError((_) {}));
    }
    _rest.close();
    _brainClient.close();
    _input.dispose();
    unawaited(_transcriber.dispose());
    super.dispose();
  }

  void _appendMsg(_Msg m) {
    if (!mounted) return;
    setState(() => _messages.add(m));
  }

  @override
  Widget build(BuildContext context) {
    final ready = _state == t0.EngineState.ready;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _panel,
        title: Row(children: [
          const CircleAvatar(
            radius: 12,
            backgroundColor: _accent,
            child: Text('M',
                style: TextStyle(fontSize: 12, color: Colors.white)),
          ),
          const SizedBox(width: 10),
          const Text('Mila', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          _StatusDot(state: _state, brainBusy: _brainBusy),
        ]),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                'proxy: ${Uri.parse(_kMintProxyUrl).authority}  ·  brain: ${Uri.parse(_kBrainUrl).authority}',
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
      // Top-level Listener lifts browser autoplay on first tap.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          final e = _engine;
          if (e != null) unawaited(e.resumePlayback());
        },
        child: Column(
          children: [
            // Video pane — 9:16 portrait for Mila's muse bake.
            Expanded(
              flex: 3,
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: t0.TwaiTransport0Player(
                      mint: _mint,
                      idleBuilder: (ctx) =>
                          NetworkVideoIdle(Uri.parse(_kIdleUrl)).build(ctx),
                      onEngine: (e) => setState(() => _engine = e),
                      onState: (s) => setState(() => _state = s),
                      // Drive mic-button disable while Mila speaks.
                      onSpeaking: (e) {
                        if (mounted) setState(() => _speaking = e.active);
                      },
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: _panelBorder),
            // Chat log.
            Expanded(
              flex: 2,
              child: Container(
                color: _panel,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ListView.builder(
                  reverse: true,
                  itemCount: _messages.length,
                  itemBuilder: (_, i) =>
                      _MsgBubble(_messages[_messages.length - 1 - i]),
                ),
              ),
            ),
            const Divider(height: 1, color: _panelBorder),
            // Composer.
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: InputDecoration(
                        hintText: ready
                            ? 'Say something to Mila…'
                            : 'Connecting… (${_state.name})',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20)),
                        isDense: true,
                        filled: true,
                        fillColor: _bg,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Hold to speak. Final transcript populates the field
                  // + fires send() immediately.
                  TwaiMicButton(
                    transcriber: _transcriber,
                    enabled: ready && !_brainBusy && !_speaking,
                    onTranscript: (text) {
                      _input.text = text;
                      _send();
                    },
                    idleColor: _accent,
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: _accent),
                    onPressed: ready && !_brainBusy ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Msg {
  const _Msg({required this.who, required this.text});
  factory _Msg.user(String t) => _Msg(who: _Who.user, text: t);
  factory _Msg.mila(String t) => _Msg(who: _Who.mila, text: t);
  factory _Msg.system(String t) => _Msg(who: _Who.system, text: t);
  final _Who who;
  final String text;
}

enum _Who { user, mila, system }

class _MsgBubble extends StatelessWidget {
  const _MsgBubble(this.m);
  final _Msg m;

  @override
  Widget build(BuildContext context) {
    final isUser = m.who == _Who.user;
    final isSystem = m.who == _Who.system;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (isSystem)
            Text(m.text,
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontStyle: FontStyle.italic))
          else
            Flexible(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isUser ? _accent : _bg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(m.text,
                    style: const TextStyle(fontSize: 14, height: 1.35)),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.state, required this.brainBusy});
  final t0.EngineState state;
  final bool brainBusy;
  @override
  Widget build(BuildContext context) {
    final (color, label) = brainBusy
        ? (_accent, 'brain…')
        : switch (state) {
            t0.EngineState.idle => (Colors.grey, 'idle'),
            t0.EngineState.minting => (Colors.amber, 'minting'),
            t0.EngineState.joining => (Colors.amber, 'joining'),
            t0.EngineState.warming => (Colors.amber, 'warming'),
            t0.EngineState.ready => (Colors.greenAccent, 'ready'),
            t0.EngineState.ended => (Colors.redAccent, 'ended'),
          };
    return Row(children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 11, color: color)),
    ]);
  }
}
