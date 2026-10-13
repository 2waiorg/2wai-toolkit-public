// twai-api starter — REFERENCE APP for the 2wai Toolkit's Transport 0
// (LiveKit) integration with **BYO brain** (Option β).
//
// ═══════════════════════════════════════════════════════════════════════
// WHAT THIS APP IS
// ═══════════════════════════════════════════════════════════════════════
//
// The smallest possible customer-facing Flutter app that talks to the
// twai-api gateway (api.2wai.ai/v1/*) using the split-plane security
// pattern: sk_ NEVER in the browser, the customer runs a tiny mint
// proxy that holds it server-side.
//
// Wire choice: **Transport 0 (LiveKit)** — the only live-chat wire on
// every 2wai avatar surface since 2026-08-22 (ADR-045 / ADR-049).
//
// Brain choice: **Customer-owned (Option β)** — the app calls
// `POST /v1/sessions/:sid/speak` DIRECTLY with the text the avatar
// should say. Your LLM produces the text; the toolkit only renders it.
// Echo mode by default (avatar says the literal user text — proves the
// wire is working). To wire a real LLM, plug it in at `_send()`:
//   1. call your brain with the user text
//   2. stream/collect the reply
//   3. call `_rest.speak(sessionId, replyChunk)` per completed clause.
// See apps/enlighten/lib/main.dart for the full streaming-brain pattern,
// or apps/candy_demo for a lower-level example.
//
// Alternative: swap the direct `/speak` call in `_send()` for
// `_engine.send(text)` to use the 2wai-hosted agent's brain instead
// (persona bound to the avatar's `livekit_profile`). That collapses
// this into apps/enlighten's shape.
//
// Reference companions (same SDK, different shapes):
//   apps/enlighten   — T0 + streaming BYO-brain (Dr. Alman + Lumara pattern)
//   apps/hello_avatar — T0 minimum-viable, agent-brain (Option α)
//   apps/jesus       — T0 + brain override profile (talk2jesus-web-test)
//   apps/mmm_demo    — T0 + primer + retail QR-scan flow
//
// ═══════════════════════════════════════════════════════════════════════
// HOW TO RUN
// ═══════════════════════════════════════════════════════════════════════
//
// 1. Start a mint proxy in a separate shell (Node reference here; there
//    are Python and CF Worker equivalents in apps/mint_proxy_examples/):
//
//      cd apps/mint_proxy_examples/node
//      npm install
//      $env:SK_KEY = "sk_test_..."   # your 2wai secret key
//      node server.js                # listens on :8787
//
// 2. In another shell, run this app:
//
//      cd apps/twai_api_starter
//      flutter run -d chrome --web-port 5174
//      flutter run -d <android-device>
//      flutter run -d <iphone>
//
//    Android/iOS from a physical device: use your dev box's LAN IP,
//    since localhost on the phone is the phone itself:
//      flutter run -d <device> ^
//        --dart-define=MINT_PROXY_URL=http://192.168.1.42:8787
//
// 3. Override any of the defaults below via --dart-define. Example:
//      --dart-define=AVATAR_ID=avt_your_avatar_id ^
//      --dart-define=VOICE_ID=vc_your_voice_id ^
//      --dart-define=IDLE_URL=https://your-cdn/your-idle-loop.mp4

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURATION — every knob a customer will typically want to change
// ═══════════════════════════════════════════════════════════════════════

/// Where your mint proxy lives. The SDK sends every /v1/* call here;
/// your proxy passes them through to https://api.2wai.ai with your
/// sk_ Bearer added. The browser NEVER sees the sk_.
///
/// From a physical phone on the same LAN as your dev box, override
/// with your dev box's LAN IP:
///   --dart-define=MINT_PROXY_URL=http://192.168.1.42:8787
const _kMintProxyUrl = String.fromEnvironment(
  'MINT_PROXY_URL',
  defaultValue: 'http://localhost:8787',
);

/// The tenant-scoped avatar id from POST /admin/avatars. Shape:
/// `avt_<hex>`. Every avatar your tenant registers gets its own
/// avt_ id — this is NOT the raw muse-worker pipeline slug.
///
/// Default is Mila on the toolkit-demo tenant
/// (`ten_0e2277049d82a22bbb02ed30`). Replace with your own registered
/// avatar for anything real.
const _kAvatarId = String.fromEnvironment(
  'AVATAR_ID',
  defaultValue: 'avt_441ad4d95906438490a85b79',
);

/// Voice id — shape `vc_<hex>`. Points at a tenant-scoped voice
/// registered via POST /v1/files + POST /v1/voices. Empty string falls
/// through to the broker profile's default voice.
///
/// Default is Mila's tenant-scoped voice.
const _kVoiceId = String.fromEnvironment(
  'VOICE_ID',
  defaultValue: 'vc_e72e888d566aca3a4e63fbe8',
);

/// Idle loop URL. Shown behind the LiveKit video sink whenever the
/// avatar isn't actively speaking.
const _kIdleUrl = String.fromEnvironment(
  'IDLE_URL',
  defaultValue:
      'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4',
);
// Optional server-side STT endpoint. See other apps for the same shape.
const _kSttUrl = String.fromEnvironment('STT_URL', defaultValue: '');

// ═══════════════════════════════════════════════════════════════════════
// UI
// ═══════════════════════════════════════════════════════════════════════

void main() => runApp(const TwaiApiStarterApp());

class TwaiApiStarterApp extends StatelessWidget {
  const TwaiApiStarterApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'twai-api starter',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
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
  final _log = <String>[];
  final _input = TextEditingController();
  t0.LiveKitEngine? _engine;
  t0.EngineState _state = t0.EngineState.idle;
  // The T0 session id, captured on mint. Needed by every subsequent
  // control-plane call (`speak` / `interrupt` / `DELETE`).
  String? _sessionId;
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    // ─── Mint-proxy client ─────────────────────────────────────────────
    // Points the SDK at your mint proxy. AnonymousCredentials tells
    // the SDK NOT to send an Authorization header — the proxy adds
    // the sk_ Bearer server-side. NEVER construct with raw sk_ in a
    // browser build.
    _rest = TwaiApiRestClient(
      baseUrl: Uri.parse(_kMintProxyUrl),
      credentials: const AnonymousCredentials(),
    );
    _transcriber = _kSttUrl.isNotEmpty
        ? HttpSttTranscriber(endpoint: Uri.parse(_kSttUrl))
        : DefaultTranscriber();
  }

  // The mint closure — the ONLY place the tenant's `avt_` id crosses
  // into the SDK. Called by TwaiTransport0Player on mount / reconnect.
  Future<t0.MintResult> _mint() async {
    try {
      final voiceId = _kVoiceId.startsWith('vc_') ? _kVoiceId : null;
      final m = await _rest.createLiveKitSession(
        TwaiApiLiveKitSessionRequest(
          avatarId: _kAvatarId,
          voiceId: voiceId,
        ),
      );
      // Capture the session id — every direct /speak call below needs it.
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

  // ─── The BYO-brain send loop (Option β) ─────────────────────────────
  //
  // Echo mode: post the user's literal text to /v1/sessions/:sid/speak.
  // The avatar TTSes + renders it. No LLM involved — the SDK is only
  // the render layer.
  //
  // To wire a real LLM, replace the single `_rest.speak(...)` call below
  // with: (a) call your brain with `text` and `_sessionId`, (b) stream
  // the reply, (c) `await _rest.speak(_sessionId, clause)` per completed
  // clause. Interrupt with `_rest.interrupt(_sessionId)` if the user
  // sends a new message before the previous reply finishes.
  //
  // Alternative — swap for the agent's brain: replace with
  // `await _engine.send(text)` to let the 2wai-hosted brain (persona
  // bound to the avatar's `livekit_profile`) generate the reply. This
  // is the enlighten / hello_avatar shape (Option α).
  Future<void> _send() async {
    final sid = _sessionId;
    if (sid == null || _state != t0.EngineState.ready) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _appendLog('user: $text');
    try {
      await _rest.speak(sid, text);
    } catch (e) {
      _appendLog('speak failed: $e');
    }
  }

  @override
  void dispose() {
    // TwaiTransport0Player owns and disposes the engine it hands to
    // us via onEngine. Best-effort session-delete via the REST client
    // helps the gateway release the slot; the gateway also idle-reaps
    // if this call is dropped.
    final sid = _sessionId;
    if (sid != null) {
      unawaited(_rest.deleteSession(sid).catchError((_) {}));
    }
    _rest.close();
    _input.dispose();
    unawaited(_transcriber.dispose());
    super.dispose();
  }

  void _appendLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('twai-api starter'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  'proxy: ${Uri.parse(_kMintProxyUrl).authority}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ],
        ),
        // Top-level Listener lifts browser autoplay for the LiveKit audio
        // track on the first tap. Required on web; harmless on native.
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            final e = _engine;
            if (e != null) unawaited(e.resumePlayback());
          },
          child: Column(
            children: [
              Expanded(
                flex: 3,
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      // TwaiTransport0Player owns: LiveKit room join,
                      // WebRTC track subscription, idle→speaking crossfade,
                      // reconnect classification. Consumer passes the mint
                      // closure + an idle builder + engine/state callbacks.
                      child: t0.TwaiTransport0Player(
                        mint: _mint,
                        idleBuilder: (ctx) =>
                            NetworkVideoIdle(Uri.parse(_kIdleUrl)).build(ctx),
                        onEngine: (e) => setState(() => _engine = e),
                        onState: (s) {
                          _appendLog('state → ${s.name}');
                          setState(() => _state = s);
                        },
                        // Track avatar speaking so the mic button disables
                        // itself while the reply plays back.
                        onSpeaking: (e) {
                          if (mounted) setState(() => _speaking = e.active);
                        },
                        onReplyText: (e) => _appendLog('avatar: ${e.text}'),
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                flex: 2,
                child: Container(
                  color: Colors.grey.shade900,
                  padding: const EdgeInsets.all(8),
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Text(
                      _log[_log.length - 1 - i],
                      style: const TextStyle(
                          fontSize: 13, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          decoration: InputDecoration(
                            hintText: _state == t0.EngineState.ready
                                ? 'Say something for the avatar to echo…'
                                : 'Connecting… (${_state.name})',
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Hold to speak. Final transcript populates the
                      // field + fires send() immediately.
                      TwaiMicButton(
                        transcriber: _transcriber,
                        enabled: _state == t0.EngineState.ready && !_speaking,
                        onTranscript: (text) {
                          _input.text = text;
                          _send();
                        },
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed:
                            _state == t0.EngineState.ready ? _send : null,
                        icon: const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
