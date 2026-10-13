// The smallest possible 2wai Avatar app on Transport 0 (LiveKit).
//
// This file is the whole app. It's the minimum-viable-integration
// reference — one screen, one TwaiTransport0Player, one send button.
// Every line is load-bearing. Read this end-to-end before the deeper
// customer-shape references:
//   apps/enlighten/lib/main.dart  → full customer-shape (chat log,
//                                    palette, status badge, error handling)
//   apps/jesus/lib/main.dart       → verbose lifecycle logging
//   apps/mmm_demo/lib/product_chat_screen.dart → primer + retail flow
//
// Migrated from Adapter 1 (penthouse-staging MSE-over-WS) 2026-09-04
// after ADR-049 retired MSE. Same shape as enlighten, stripped to the bone.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

// The three consumer-owned inputs. Every T0 integration needs these
// exact three; the rest is boilerplate.
const _kMintProxyUrl = String.fromEnvironment(
  'MINT_PROXY_URL',
  defaultValue: 'http://localhost:8787',
);
// Krystal Casual on the jim-toolkit-demo tenant.
// livekit_profile=krystal-harper. Swap to any other tenant-registered
// avatar_id and hello_avatar talks to that one instead.
const _kAvatarId = String.fromEnvironment(
  'AVATAR_ID',
  defaultValue: 'avt_096ef7f928a9bcee503eb1f9',
);
const _kIdleUrl = String.fromEnvironment(
  'IDLE_URL',
  defaultValue:
      'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_IdleDefault.mp4',
);
// Optional server-side STT endpoint. When set, TwaiMicButton uses
// HttpSttTranscriber; when unset, falls back to DefaultTranscriber
// (browser SpeechRecognition on web / speech_to_text on native).
const _kSttUrl = String.fromEnvironment('STT_URL', defaultValue: '');

void main() => runApp(const HelloAvatarApp());

class HelloAvatarApp extends StatelessWidget {
  const HelloAvatarApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hello Avatar',
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
  final _input = TextEditingController();
  t0.LiveKitEngine? _engine;
  t0.EngineState _state = t0.EngineState.idle;
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

  // The mint closure — the ONLY place the tenant's `avt_` id crosses
  // into the SDK. Called by the widget on mount / reconnect.
  Future<t0.MintResult> _mint() async {
    try {
      final m = await _rest.createLiveKitSession(
          TwaiApiLiveKitSessionRequest(avatarId: _kAvatarId));
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

  Future<void> _send() async {
    final e = _engine;
    if (e == null || _state != t0.EngineState.ready) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await e.send(text);
    } catch (_) {
      // fire-and-forget in the minimal demo; enlighten shows how to
      // surface errors in-UI.
    }
  }

  @override
  void dispose() {
    // TwaiTransport0Player owns and disposes the engine it hands to
    // us via onEngine. Only the REST client + text controller are ours.
    _rest.close();
    _input.dispose();
    unawaited(_transcriber.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _state == t0.EngineState.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('Hello Avatar')),
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
              child: AspectRatio(
                aspectRatio: 9 / 16,
                // The whole avatar experience — idle video, LiveKit
                // tracks, fade transitions — is this one widget.
                child: t0.TwaiTransport0Player(
                  mint: _mint,
                  idleBuilder: (ctx) =>
                      NetworkVideoIdle(Uri.parse(_kIdleUrl)).build(ctx),
                  onEngine: (e) => setState(() => _engine = e),
                  onState: (s) => setState(() => _state = s),
                  // Mic-feedback mitigation: disable the mic while the
                  // avatar is talking (hot-mic loop guard).
                  onSpeaking: (e) {
                    if (mounted) setState(() => _speaking = e.active);
                  },
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        decoration: InputDecoration(
                          hintText: ready ? 'Say something…' : 'Connecting…',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Hold to speak. Final transcript populates the
                    // field + fires send() immediately.
                    TwaiMicButton(
                      transcriber: _transcriber,
                      enabled: ready && !_speaking,
                      onTranscript: (text) {
                        _input.text = text;
                        _send();
                      },
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: ready ? _send : null,
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
}
