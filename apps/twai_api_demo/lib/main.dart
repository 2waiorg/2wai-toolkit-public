// Direct exercise of the twai-api gateway on Transport 0 (LiveKit).
// Zero twai SDK deps: this app talks to /v1/* itself and joins the
// LiveKit room via the `livekit_client` package directly, so you can
// prove the wire works end-to-end before adopting the higher-level SDK.
//
// Migrated from the pre-2026-08-22 MSE-wire raw client after
// ADR-045 / ADR-049 retired MSE. The MSE version rendered with a
// hand-rolled MediaSource + SourceBuffer against ws://api.2wai.ai/v1/stream.
// This T0 version uses LiveKit-Cloud subscribed WebRTC tracks and drives
// `lk.chat` data messages for user text.
//
// Wire (canonical spec: wiki avatar-toolkit/protocol/livekit.md):
//   POST /v1/sessions  sk-Bearer  {avatar_id, transport:"livekit", voice_id?}
//     -> {session_id, transport:"livekit", livekit_url, participant_token,
//         room_name, agent_identity}
//   WSS  <livekit_url> with token=<participant_token>
//     -> ParticipantConnected(agent identity 'livealman-agent-<hex>')
//     -> TrackSubscribed(video, audio) — the avatar's WebRTC tracks
//     -> DataReceived(topic="2wai.reply", ...) — reply text frames
//     -> DataReceived(topic="livealman", ...) — speaking start/stop events
//   Publish DataMessage(topic="lk.chat", data=<envelope>) to talk to
//     the agent's brain. Envelope = {"v":1,"request_id":<uuid>,"text":<text>}.
//   POST /v1/sessions/{id}/speak     sk-Bearer  {"text":"..."}    for BYO-brain
//   POST /v1/sessions/{id}/interrupt sk-Bearer                    barge-in
//   DELETE /v1/sessions/{id}         sk-Bearer                    release
//
// NOTE ON THE SPLIT-PLANE PATTERN
// The gateway wants the sk_ key on a customer SERVER, not in a browser.
// This app puts sk_ in the client for dev-only convenience — do NOT ship
// this shape to real users. For the production shape (mint-proxy holds
// sk_, browser sees only tenant-scoped short-lived tokens), see
// apps/twai_api_starter (SDK) or apps/mint_proxy_examples/ (mint proxy).
//
// RUN
//   1. cp apps/twai_api_demo/.env.example apps/twai_api_demo/.env
//      Then fill in SK_KEY (see .env.example header for the az cmd).
//   2. cd apps/twai_api_demo
//      flutter run -d chrome --web-port 5173 --dart-define-from-file=.env
//   3. To swap avatars, override AVATAR_ID / VOICE_ID at runtime:
//      --dart-define=AVATAR_ID=avt_your_avatar_id
//
// CORS: the gateway serves CORS directly for any localhost/127.0.0.1
// origin, so the browser talks to https://api.2wai.ai unmediated.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:uuid/uuid.dart';

// ═══════════════════════════════════════════════════════════════════
// CONFIG — supplied via --dart-define-from-file=.env (see .env.example).
// Defaults compile-safe placeholders so the app still runs; it'll bounce
// with 401 from the gateway if SK_KEY isn't overridden.
// ═══════════════════════════════════════════════════════════════════
const _kGatewayBase = String.fromEnvironment(
  'GATEWAY_BASE',
  defaultValue: 'https://api.2wai.ai',
);
const _kSkKey =
    String.fromEnvironment('SK_KEY', defaultValue: 'sk_test_REPLACE_ME');
// Mila on the toolkit-demo tenant. Verified 2026-08-16.
const _kAvatarId = String.fromEnvironment(
  'AVATAR_ID',
  defaultValue: 'avt_441ad4d95906438490a85b79',
);
const _kVoiceId = String.fromEnvironment(
  'VOICE_ID',
  defaultValue: 'vc_e72e888d566aca3a4e63fbe8',
);
// Chat topics from the wire spec. Must match the agent's expectations.
const _kTopicChat = 'lk.chat';
const _kTopicReply = '2wai.reply';
const _kTopicSpeaking = 'livealman';
// Agent identity prefix. The broker names the agent
// `livealman-agent-<hex>`; we filter to this when detecting agent join.
const _kAgentIdentityPrefix = 'livealman-agent-';

void main() => runApp(const TwaiApiDemoApp());

class TwaiApiDemoApp extends StatelessWidget {
  const TwaiApiDemoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'twai-api demo (T0 raw wire)',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: const _HomeScreen(),
      );
}

class _HomeScreenState extends State<_HomeScreen> {
  final _log = <String>[];
  final _input = TextEditingController();
  final _uuid = const Uuid();
  String _status = 'idle';

  // Session state, captured on POST /v1/sessions.
  String? _sessionId;
  // LiveKit room instance + the remote video track (once the agent
  // publishes it) so the video widget can render.
  lk.Room? _room;
  lk.VideoTrack? _remoteVideoTrack;

  @override
  void initState() {
    super.initState();
    // Kick the whole handshake automatically on mount.
    _connect();
  }

  @override
  void dispose() {
    _cleanup();
    _input.dispose();
    super.dispose();
  }

  void _appendLog(String s) {
    if (!mounted) return;
    setState(() {
      _log.add(s);
      if (_log.length > 200) _log.removeAt(0);
    });
  }

  // ─── 1) Mint a T0 session ─────────────────────────────────────────
  //
  // POST /v1/sessions with `transport:"livekit"` → returns the LiveKit
  // tuple to join. This is where the sk_ Bearer is used (dev-only —
  // production apps do this via a mint proxy; see twai_api_starter).
  Future<Map<String, dynamic>?> _mint() async {
    _appendLog('POST $_kGatewayBase/v1/sessions  (avatar=$_kAvatarId)');
    setState(() => _status = 'minting');
    try {
      final resp = await http.post(
        Uri.parse('$_kGatewayBase/v1/sessions'),
        headers: {
          'Authorization': 'Bearer $_kSkKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'avatar_id': _kAvatarId,
          'transport': 'livekit',
          if (_kVoiceId.startsWith('vc_')) 'voice_id': _kVoiceId,
        }),
      );
      _appendLog('  → HTTP ${resp.statusCode}');
      if (resp.statusCode != 201 && resp.statusCode != 200) {
        _appendLog('  body: ${resp.body.substring(0, resp.body.length.clamp(0, 200))}');
        return null;
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      _appendLog('  session_id: ${j['session_id']}');
      _appendLog('  room:       ${j['room_name']}');
      _appendLog('  agent:      ${j['agent_identity'] ?? '(unbound)'}');
      return j;
    } catch (e) {
      _appendLog('  MINT FAILED: $e');
      return null;
    }
  }

  // ─── 2) Join the LiveKit room ─────────────────────────────────────
  //
  // The mint response gives you `livekit_url` + `participant_token`.
  // `livekit_client` handles the WebRTC negotiation, ICE, and track
  // subscription. All we do is wire up event listeners.
  Future<void> _connect() async {
    final tuple = await _mint();
    if (tuple == null) {
      setState(() => _status = 'mint-failed');
      return;
    }
    _sessionId = tuple['session_id'] as String;

    final url = tuple['livekit_url'] as String;
    final token = tuple['participant_token'] as String;

    setState(() => _status = 'joining');
    final room = lk.Room(
      // adaptiveStream=false: the video element may be hidden between
      // replies; adaptiveStream would pause the subscription and stall
      // the next reply. Same rule as the SDK's canonical engine.dart.
      roomOptions: const lk.RoomOptions(
          adaptiveStream: false, dynacast: false),
    );
    _room = room;

    // Track subscription: fires when the agent publishes each track.
    room.addListener(() {
      // Room-level state changes (connected/disconnected/reconnecting).
      _appendLog('room state: ${room.connectionState}');
    });

    room.createListener()
      ..on<lk.RoomConnectedEvent>((_) {
        setState(() => _status = 'connected');
        _appendLog('WebRTC connected (${room.remoteParticipants.length} remote)');
      })
      ..on<lk.ParticipantConnectedEvent>((e) {
        final id = e.participant.identity;
        _appendLog('participant joined: $id');
        if (id.startsWith(_kAgentIdentityPrefix)) {
          setState(() => _status = 'agent-present');
        }
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) {
        _appendLog('participant left: ${e.participant.identity}');
        if (e.participant.identity.startsWith(_kAgentIdentityPrefix)) {
          setState(() => _status = 'agent-ended');
        }
      })
      ..on<lk.TrackSubscribedEvent>((e) {
        final kind = e.track.kind.name;
        _appendLog('trackSubscribed: $kind from=${e.participant.identity}');
        if (e.track is lk.VideoTrack) {
          setState(() => _remoteVideoTrack = e.track as lk.VideoTrack);
        }
      })
      ..on<lk.DataReceivedEvent>((e) {
        // Decode the raw bytes per topic. The wire uses JSON envelopes
        // on 2wai.reply and livealman; raw text on lk.transcription.
        final topic = e.topic ?? '(none)';
        final payload = utf8.decode(e.data);
        if (topic == _kTopicReply) {
          _handleReplyFrame(payload);
        } else if (topic == _kTopicSpeaking) {
          _handleSpeakingFrame(payload);
        } else {
          _appendLog('data[$topic]: $payload');
        }
      });

    try {
      await room.connect(url, token);
      // state → 'connected' emits via the event listener above.
      // Once the agent publishes video, _remoteVideoTrack is populated
      // and the widget swaps from placeholder to VideoTrackRenderer.
    } catch (e) {
      _appendLog('room.connect() failed: $e');
      setState(() => _status = 'connect-failed');
    }
  }

  void _handleReplyFrame(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final kind = j['kind'];
      final text = j['text'];
      if (kind == 'text' && text is String && text.isNotEmpty) {
        _appendLog('avatar: $text');
      } else {
        _appendLog('reply[$kind]: $payload');
      }
    } catch (_) {
      _appendLog('reply(raw): $payload');
    }
  }

  void _handleSpeakingFrame(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (j['type'] == 'speaking') {
        _appendLog('speaking: ${j['value']}');
      }
    } catch (_) {
      _appendLog('speaking(raw): $payload');
    }
  }

  // ─── 3) Send user text via `lk.chat` (agent-brain path) ───────────
  //
  // The client publishes an envelope on the `lk.chat` topic; the agent
  // reads it, calls the brain, streams the reply back as 2wai.reply
  // data frames + WebRTC video/audio tracks.
  //
  // Alternative for BYO-brain: skip lk.chat and POST directly to
  // /v1/sessions/{sid}/speak with your generated text. Same rendering,
  // your LLM chooses what to say. See _sendViaSpeak() below.
  Future<void> _sendViaChat() async {
    final room = _room;
    if (room == null || _status != 'agent-present') return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _appendLog('user (lk.chat): $text');
    final envelope = jsonEncode({
      'v': 1,
      'request_id': _uuid.v4(),
      'text': text,
    });
    await room.localParticipant?.publishData(
      utf8.encode(envelope),
      topic: _kTopicChat,
      reliable: true,
    );
  }

  // BYO-brain alternative — hit /speak directly, avatar echoes text.
  // ignore: unused_element
  Future<void> _sendViaSpeak(String text) async {
    final sid = _sessionId;
    if (sid == null) return;
    _appendLog('POST /v1/sessions/$sid/speak  ($text)');
    final resp = await http.post(
      Uri.parse('$_kGatewayBase/v1/sessions/$sid/speak'),
      headers: {
        'Authorization': 'Bearer $_kSkKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'text': text}),
    );
    _appendLog('  → HTTP ${resp.statusCode}');
  }

  void _cleanup() {
    final sid = _sessionId;
    if (sid != null) {
      // Best-effort session release — gateway idle-reaps if we can't.
      unawaited(http.delete(
        Uri.parse('$_kGatewayBase/v1/sessions/$sid'),
        headers: {'Authorization': 'Bearer $_kSkKey'},
      ).catchError((_) => http.Response('', 0)));
    }
    _room?.disconnect().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('twai-api demo — raw T0 wire'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text('status: $_status',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // ─── Avatar video pane ────────────────────────────────────
            Expanded(
              flex: 3,
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: _remoteVideoTrack == null
                        ? Center(
                            child: Text(
                              _status == 'idle' || _status == 'minting'
                                  ? 'Waiting for mint…'
                                  : _status == 'joining' ||
                                          _status == 'connected'
                                      ? 'Waiting for agent…'
                                      : _status,
                              style: const TextStyle(color: Colors.white54),
                            ),
                          )
                        : lk.VideoTrackRenderer(_remoteVideoTrack!),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            // ─── Log pane ────────────────────────────────────────────
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
                        fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            // ─── Composer ────────────────────────────────────────────
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
                          hintText: _status == 'agent-present'
                              ? 'Say something (publishes lk.chat)…'
                              : 'Waiting… ($_status)',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _sendViaChat(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _status == 'agent-present' ? _sendViaChat : null,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();
  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

// Silence the unused-import warning on non-web builds; kIsWeb is
// referenced so `flutter build web` inlines platform-conditional code
// paths in dependent packages without emitting a warning here.
// ignore: unused_element
void _unused() {
  const _ = kIsWeb;
}
