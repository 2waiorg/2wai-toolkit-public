import 'dart:async';

import 'package:flutter/material.dart';

import 'transcriber.dart';

/// Gesture model for [TwaiMicButton].
///
/// `tapToToggle` (**default**) — tap once to start, tap again to commit.
/// This is the stable path: verified on iPhone 15 / iOS 26.6.2 inside a
/// scrollable composer, where the plain-tap recognizer wins the gesture
/// arena reliably. If the mic never seems to arm on a tap-and-hold, this
/// is why — the toolkit picked tap-to-toggle after Lumara's on-device
/// research demonstrated `pushToTalk`'s `onTapDown`/`onTapUp` events get
/// canceled by parent scrollables on iOS.
///
/// `pushToTalk` — press to start, release to commit, drag off to cancel.
/// Matches Penthouse Pets' mature mobile UX and Mason's `@twai/mic`
/// shape. Only reliable OUTSIDE scrollable containers on iOS (Android is
/// more permissive). Use when your composer is fixed at the bottom of a
/// non-scrolling row.
enum TwaiMicGesture { pushToTalk, tapToToggle }

/// The 2wai avatar toolkit's default mic button.
///
/// One widget, one job: drive a [Transcriber], surface a push-to-talk
/// affordance, and hand transcripts to the caller. Consumer decides how
/// to route the transcript (typically `engine.send(transcript)` on the
/// LiveKit T0 engine, but the widget is transport-agnostic).
///
/// The widget owns:
///   - Transcriber lifecycle (initialize/start/stop/cancel wiring — but
///     NOT the transcriber's own dispose(); that's the consumer's, since
///     a transcriber can outlive many button mounts).
///   - The listening/idle visual (a circular icon button).
///   - Gesture handling (press/release/drag-off for push-to-talk).
///   - Auto-hide when `Transcriber.isAvailable == false` after
///     [initialize] resolves (Firefox web, unsupported platforms).
///
/// The widget does NOT own:
///   - The transcript stream buffer or history.
///   - Sending the transcript to the avatar (consumer wires `onTranscript`).
///   - Cancelling mid-utterance when the avatar starts speaking (consumer
///     drives via the [enabled] prop or by calling
///     [TwaiMicButtonController.cancel] externally).
class TwaiMicButton extends StatefulWidget {
  const TwaiMicButton({
    super.key,
    required this.transcriber,
    required this.onTranscript,
    this.onInterim,
    this.onError,
    this.gesture = TwaiMicGesture.tapToToggle,
    this.enabled = true,
    this.autoInitialize = true,
    this.iconSize = 24,
    this.tooltip = 'Tap to speak',
    this.idleColor,
    this.listeningColor,
    this.disabledColor,
    this.backgroundColor,
    this.hideWhenUnavailable = true,
  });

  /// Backend that turns audio into text. Not disposed by the widget —
  /// consumers construct once and reuse across mounts.
  final Transcriber transcriber;

  /// Called with the final transcript when the user commits a turn.
  /// Empty strings are suppressed by [TwaiMicButton] and reach here only
  /// when the transcriber produced text.
  final ValueChanged<String> onTranscript;

  /// Optional live interim callback (fires as the user speaks, before
  /// they release). Nice for a preview bubble; omit if you don't want
  /// partial text at all.
  final ValueChanged<String>? onInterim;

  /// Optional error callback. If null, errors are silently swallowed
  /// (the visual returns to idle either way). Consumers that want to
  /// surface a snackbar / banner pass a handler.
  final void Function(TranscriberError err)? onError;

  /// See [TwaiMicGesture]. Default push-to-talk.
  final TwaiMicGesture gesture;

  /// When false, the button renders disabled and refuses gestures.
  /// Wire to `avatar.state != speaking` (via a `ValueListenableBuilder`
  /// on the T0 engine's `state`) to prevent hot-mic feedback while the
  /// avatar is talking.
  final bool enabled;

  /// If true (default), the widget calls [Transcriber.initialize] once
  /// on mount. Consumers who pre-initialize (e.g. warm the recognizer
  /// on app launch to skip the first-press latency) can pass false.
  final bool autoInitialize;

  /// Icon size in logical pixels. The tap area is slightly larger.
  final double iconSize;

  /// Tooltip text shown on hover / long-press on platforms that
  /// surface tooltips.
  final String tooltip;

  /// Optional color override for the idle mic glyph.
  final Color? idleColor;

  /// Optional color override for the listening mic glyph. Defaults to
  /// theme colorScheme.error to signal "hot mic."
  final Color? listeningColor;

  /// Optional color override for the disabled glyph.
  final Color? disabledColor;

  /// Optional background color (fills the button circle). Null draws
  /// a subtle theme-derived fill.
  final Color? backgroundColor;

  /// When true (default), the widget renders `SizedBox.shrink()` if
  /// the transcriber reports `isAvailable: false` after initialize —
  /// e.g. Firefox web with browser SpeechRecognition. Set false to
  /// render a permanently-disabled button in that case.
  final bool hideWhenUnavailable;

  @override
  State<TwaiMicButton> createState() => _TwaiMicButtonState();
}

class _TwaiMicButtonState extends State<TwaiMicButton> {
  bool _available = false;
  bool _initialized = false;
  bool _listening = false;
  StreamSubscription<TranscriptEvent>? _transcriptSub;
  StreamSubscription<TranscriberError>? _errorSub;

  @override
  void initState() {
    super.initState();
    _wireStreams();
    if (widget.autoInitialize) unawaited(_ensureInitialized());
  }

  @override
  void didUpdateWidget(TwaiMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rewire streams if the transcriber instance changed. Consumers
    // that keep one transcriber for the lifetime of a screen won't hit
    // this, but a lab / test harness that swaps backends live can.
    if (!identical(oldWidget.transcriber, widget.transcriber)) {
      _transcriptSub?.cancel();
      _errorSub?.cancel();
      _available = false;
      _initialized = false;
      _listening = false;
      _wireStreams();
      if (widget.autoInitialize) unawaited(_ensureInitialized());
    }
    // If disabled mid-utterance (avatar started speaking), cancel the
    // in-flight capture so we don't accidentally send audio the user
    // didn't mean.
    if (oldWidget.enabled && !widget.enabled && _listening) {
      unawaited(widget.transcriber.cancel());
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    _errorSub?.cancel();
    // Deliberately do NOT dispose the transcriber — it's consumer-owned.
    if (_listening) unawaited(widget.transcriber.cancel());
    super.dispose();
  }

  void _wireStreams() {
    _transcriptSub = widget.transcriber.transcripts.listen((event) {
      if (event.isFinal) {
        if (event.text.isNotEmpty) widget.onTranscript(event.text);
        if (mounted && _listening) setState(() => _listening = false);
      } else {
        widget.onInterim?.call(event.text);
      }
    });
    _errorSub = widget.transcriber.errors.listen((err) {
      widget.onError?.call(err);
      if (mounted && _listening) setState(() => _listening = false);
    });
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final ok = await widget.transcriber.initialize();
    if (!mounted) return;
    setState(() {
      _initialized = true;
      _available = ok;
    });
  }

  Future<void> _startListening() async {
    if (!widget.enabled || !_available || _listening) return;
    setState(() => _listening = true);
    try {
      await widget.transcriber.start();
    } catch (e) {
      debugPrint('[TwaiMicButton] start failed: $e');
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _stopListening() async {
    if (!_listening) return;
    setState(() => _listening = false);
    try {
      await widget.transcriber.stop();
    } catch (e) {
      debugPrint('[TwaiMicButton] stop failed: $e');
    }
  }

  Future<void> _cancelListening() async {
    if (!_listening) return;
    setState(() => _listening = false);
    try {
      await widget.transcriber.cancel();
    } catch (e) {
      debugPrint('[TwaiMicButton] cancel failed: $e');
    }
  }

  void _handleTapToToggle() {
    if (_listening) {
      unawaited(_stopListening());
    } else {
      unawaited(_startListening());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hideWhenUnavailable && _initialized && !_available) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final disabled = !widget.enabled || !_available;
    final iconColor = disabled
        ? (widget.disabledColor ?? scheme.onSurface.withValues(alpha: 0.38))
        : _listening
            ? (widget.listeningColor ?? scheme.error)
            : (widget.idleColor ?? scheme.primary);

    final background = widget.backgroundColor ??
        (_listening
            ? scheme.errorContainer.withValues(alpha: 0.5)
            : scheme.surfaceContainerHighest);

    final button = Semantics(
      label: widget.tooltip,
      button: true,
      enabled: !disabled,
      child: Tooltip(
        message: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
          ),
          padding: EdgeInsets.all(widget.iconSize * 0.4),
          child: Icon(
            _listening ? Icons.mic : Icons.mic_none,
            size: widget.iconSize,
            color: iconColor,
          ),
        ),
      ),
    );

    if (disabled) return button;

    switch (widget.gesture) {
      case TwaiMicGesture.pushToTalk:
        return GestureDetector(
          onTapDown: (_) => unawaited(_startListening()),
          onTapUp: (_) => unawaited(_stopListening()),
          onTapCancel: () => unawaited(_cancelListening()),
          child: button,
        );
      case TwaiMicGesture.tapToToggle:
        return GestureDetector(
          onTap: _handleTapToToggle,
          child: button,
        );
    }
  }
}
