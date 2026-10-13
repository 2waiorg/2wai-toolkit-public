import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

/// Full chat embed widget: avatar video on top, message list + input
/// row below. Self-contained — host page doesn't need to wire send.
///
/// Still listens for and re-emits `reply` / `speaking-*` / `error`
/// events on the host element via the parent's callbacks, so pages
/// that *do* want to react (analytics, custom UI) can.
///
/// Voice input: uses `DefaultTranscriber` — client-side STT (browser
/// SpeechRecognition on web, native STT on iOS/Android/macOS/Windows).
/// Transcripts are committed to the input field on `isFinal`; the
/// user still taps Send to fire text into the T0 engine. This keeps
/// voice input transport-agnostic and low-latency.
class TwaiChatWidget extends StatefulWidget {
  const TwaiChatWidget({
    super.key,
    required this.mint,
    required this.idleUrl,
    required this.transcriber,
    required this.onEngineBound,
    required this.onState,
    required this.onSpeaking,
    required this.onReplyText,
    required this.onEnded,
    required this.onError,
  });

  final Future<t0.MintResult> Function() mint;
  final String? idleUrl;
  final Transcriber transcriber;
  final void Function(t0.LiveKitEngine) onEngineBound;
  final void Function(t0.EngineState) onState;
  final void Function(t0.SpeakingActiveEvent) onSpeaking;
  final void Function(t0.ReplyTextEvent) onReplyText;
  final void Function(t0.EndedEvent) onEnded;
  final void Function(Object) onError;

  @override
  State<TwaiChatWidget> createState() => _TwaiChatWidgetState();
}

class _TwaiChatWidgetState extends State<TwaiChatWidget> {
  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <_Msg>[];
  StreamSubscription<TranscriptEvent>? _transcriptSub;
  t0.LiveKitEngine? _engine;
  t0.EngineState _state = t0.EngineState.idle;
  bool _sending = false;
  bool _listening = false;
  // Set true once transcriber.initialize() succeeds. Mic button is
  // conditionally rendered on this flag — platforms without STT
  // support never see one, no customer-side platform check required.
  bool _voiceAvailable = false;

  bool get _ready => _state == t0.EngineState.ready && _engine != null;

  @override
  void initState() {
    super.initState();
    // Live transcript stream — interim updates write into the input as
    // the user speaks; the final event (isFinal: true) commits and
    // drops the listening indicator.
    _transcriptSub = widget.transcriber.transcripts.listen((ev) {
      _input.text = ev.text;
      _input.selection =
          TextSelection.collapsed(offset: _input.text.length);
      if (ev.isFinal && mounted) setState(() => _listening = false);
    });
    // Eager capability probe — no permission prompt. Mic button
    // appears (or not) once this resolves.
    // ignore: discarded_futures
    _probeVoiceAvailability();
  }

  Future<void> _probeVoiceAvailability() async {
    final ok = await widget.transcriber.initialize();
    if (mounted) setState(() => _voiceAvailable = ok);
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    _input.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    // Tap-to-toggle: tap idle → start; tap recording → stop.
    if (_listening) {
      await widget.transcriber.stop();
    } else {
      if (!mounted) return;
      setState(() => _listening = true);
      await widget.transcriber.start();
    }
  }

  Future<void> _send() async {
    final engine = _engine;
    final text = _input.text.trim();
    if (text.isEmpty || _sending || engine == null || !_ready) return;
    // Dismiss the iOS keyboard up-front so the avatar pane gets its
    // screen real estate back the moment the user commits.
    FocusScope.of(context).unfocus();
    // Cancel any active recognition before the avatar reply comes back.
    // Otherwise the avatar voice can bleed into a hot mic and feed
    // back as a "user" message, kicking off avatar-talks-to-itself.
    if (_listening) {
      // ignore: discarded_futures
      widget.transcriber.cancel();
    }
    setState(() {
      _messages.add(_Msg.user(text));
      _input.clear();
      _sending = true;
      _listening = false;
    });
    _scrollToBottom();
    try {
      await engine.send(text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.add(_Msg.error(e.toString())));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          flex: 5,
          child: ColoredBox(
            color: const Color(0xFF000000),
            // Top-level Listener lifts browser autoplay on first tap.
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                final e = _engine;
                if (e != null) unawaited(e.resumePlayback());
              },
              child: t0.TwaiTransport0Player(
                mint: widget.mint,
                idleBuilder: (ctx) =>
                    widget.idleUrl != null && widget.idleUrl!.isNotEmpty
                        ? NetworkVideoIdle(Uri.parse(widget.idleUrl!)).build(ctx)
                        : const ColoredBox(color: Colors.black),
                onEngine: (e) {
                  _engine = e;
                  widget.onEngineBound(e);
                },
                onState: (s) {
                  setState(() => _state = s);
                  widget.onState(s);
                },
                onSpeaking: (e) {
                  // Belt-and-suspenders mic-feedback guard: if avatar
                  // starts speaking while mic is still hot, force-
                  // cancel the recognizer so speaker output doesn't
                  // bleed in. Same rule as the pre-migration MSE
                  // version, ported.
                  if (e.active && _listening) {
                    // ignore: discarded_futures
                    widget.transcriber.cancel();
                    if (mounted) setState(() => _listening = false);
                  }
                  widget.onSpeaking(e);
                },
                onReplyText: (e) {
                  setState(() => _messages.add(_Msg.assistant(e.text)));
                  _scrollToBottom();
                  widget.onReplyText(e);
                },
                onEnded: widget.onEnded,
                onError: widget.onError,
              ),
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: ColoredBox(
            color: const Color(0xFF1A1A1A),
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (_, i) => _Bubble(msg: _messages[i]),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: _ready
                          ? 'Type or tap the mic…'
                          : 'Connecting… (${_state.name})',
                      hintStyle: const TextStyle(color: Color(0xFF888888)),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      FocusScope.of(context).unfocus();
                      _send();
                    },
                    onTapOutside: (_) =>
                        FocusScope.of(context).unfocus(),
                  ),
                ),
                if (_voiceAvailable && _ready) ...[
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () {
                      // ignore: discarded_futures
                      _toggleListening();
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: _listening
                          ? Colors.redAccent
                          : Theme.of(context).colorScheme.primary,
                    ),
                    icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                  ),
                ],
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending || !_ready ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum _Role { user, assistant, error }

class _Msg {
  final _Role role;
  final String text;
  const _Msg._(this.role, this.text);
  factory _Msg.user(String t) => _Msg._(_Role.user, t);
  factory _Msg.assistant(String t) => _Msg._(_Role.assistant, t);
  factory _Msg.error(String t) => _Msg._(_Role.error, t);
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg});
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == _Role.user;
    final isError = msg.role == _Role.error;
    final color = isError
        ? Colors.red.withValues(alpha: 0.3)
        : isUser
            ? Colors.blue.shade700
            : Colors.grey.shade800;
    return Container(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(msg.text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}
