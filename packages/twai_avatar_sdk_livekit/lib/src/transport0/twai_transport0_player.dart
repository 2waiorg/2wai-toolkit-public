/// Drop-in Flutter widget for Transport 0.
///
/// The engine-native replacement for `TwaiPlayer` on the LiveKit path
/// — no controller, no `_ControllerFeedShim`, no
/// `sinkRendering || _showLive` OR gate, no MSE-era watchdogs. Just
/// the [LiveKitEngine] wired directly to a two-layer Stack:
///
///   - Bottom: consumer-supplied idle widget (optional).
///   - Top: [lk.VideoTrackRenderer] gated by `onSpeaking` events. Shown
///     only during a speaking turn — matches Mason's discipline of
///     using speaking as the sole visibility cue.
///
/// The widget owns:
///
///   - A `ValueNotifier<lk.RemoteVideoTrack?>` — the render surface
///     the engine writes into on TrackSubscribed. Matches Mason's
///     `HTMLVideoElement` in the JS engine: durable, always present,
///     no subscription race.
///   - A [LiveKitEngine] instance, connected via the caller's `mint`
///     closure. Reconstructed if `mint` identity changes.
///
/// Consumers observe engine state / events by passing callbacks
/// (`onState`, `onReplyText`, `onEnded`, …) — the widget wires each
/// once and cancels on dispose.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart'
    show
        TwaiGreeting,
        TwaiGreetingNone,
        TwaiGreetingText,
        TwaiGreetingDynamic,
        GreetingStore,
        SharedPreferencesGreetingStore;

import 'engine.dart';
import 'engine_types.dart';

typedef LiveKitMintClosure = Future<MintResult> Function();

class TwaiTransport0Player extends StatefulWidget {
  /// Zero-arg closure that returns a resolved [MintResult]. Called
  /// exactly once on mount + once per manual reconnect. The engine
  /// does not classify or retry mint errors; propagate them as
  /// [MintRateLimited] / [MintUnavailable] and handle host policy
  /// (see [LiveKitRoomLifecycle]) at the caller.
  final LiveKitMintClosure mint;

  /// Widget rendered when the agent is NOT speaking. May be a looping
  /// idle video, a poster image, a solid color, or a `SizedBox`.
  /// Defaults to an empty transparent box (consumer's own scaffold
  /// shows through).
  final Widget Function(BuildContext context)? idleBuilder;

  /// Fade duration for the speaking ↔ idle swap.
  final Duration fadeDuration;

  /// Identity prefix that marks a participant as the renderer agent.
  /// Defaults to `livealman-agent-`.
  final String agentIdentityPrefix;

  /// Admin review: keep Voice Expression tags in the DISPLAYED text.
  final bool Function()? keepTags;

  /// Engine event callbacks. All optional. Wired once at connect,
  /// cancelled on dispose or engine rotation.
  final void Function(EngineState state)? onState;
  final void Function(WarmingEvent event)? onWarming;
  final void Function(ReadyEvent event)? onReady;
  final void Function(SpeakingActiveEvent event)? onSpeaking;
  final void Function(ReplyStartEvent event)? onReplyStart;
  final void Function(ReplyTextEvent event)? onReplyText;
  final void Function(ReplyCompleteEvent event)? onReplyComplete;
  final void Function(ControlEvent event)? onControl;
  final void Function(TranscriptEvent event)? onTranscript;
  final void Function(EndedEvent event)? onEnded;
  final void Function(NoticeEvent event)? onNotice;

  /// Auto-connect on mount. Consumer sets `false` when the mount is
  /// pre-authorized elsewhere or when tests want to drive `connect()`
  /// manually.
  final bool autoConnect;

  /// Called with the engine instance right after construction (before
  /// connect). Consumer can capture it for `send()` / `disconnect()`
  /// / event stream access.
  final void Function(LiveKitEngine engine)? onEngine;

  /// Called when the internal `_connectSafely` catches a mint /
  /// connect error. This is the ONLY visible surface for that
  /// exception — otherwise mint failures leave the engine at
  /// `state = idle` with no explanation. Wire this to the lab's
  /// STREAMS event log so failures become debuggable at read time
  /// rather than by patching around them.
  final void Function(Object err)? onError;

  /// Session opener. See [TwaiGreeting] for the three variants and
  /// their semantics. Defaults to [TwaiGreeting.none] (no greeting).
  ///
  /// Phase 1 (shipped): [TwaiGreeting.text] — fires `engine.send(text)`
  /// once per `scopeId` after `onReady` (plus `sendAfterReady` delay),
  /// gated by [greetingStore] persistence.
  ///
  /// Phase 2 (pending catalog hydrate): [TwaiGreeting.rendered] +
  /// [TwaiGreeting.dynamic]. Passing those today is a no-op; the
  /// widget treats unknown variants as `.none` and logs a debug warning.
  final TwaiGreeting greeting;

  /// Persistence backend for [TwaiGreeting.text]'s `scopeId` flag.
  /// Defaults to [SharedPreferencesGreetingStore] (opener survives
  /// across app launches). Pass [InMemoryGreetingStore] for the
  /// per-app-session behavior that pre-SDK `apps/mmm_demo._openerSent`
  /// had. Ignored when `greeting` is [TwaiGreeting.none].
  final GreetingStore? greetingStore;

  const TwaiTransport0Player({
    required this.mint,
    this.idleBuilder,
    this.fadeDuration = const Duration(milliseconds: 200),
    this.agentIdentityPrefix = 'livealman-agent-',
    this.keepTags,
    this.autoConnect = true,
    this.onEngine,
    this.onError,
    this.onState,
    this.onWarming,
    this.onReady,
    this.onSpeaking,
    this.onReplyStart,
    this.onReplyText,
    this.onReplyComplete,
    this.onControl,
    this.onTranscript,
    this.onEnded,
    this.onNotice,
    this.greeting = const TwaiGreetingNone(),
    this.greetingStore,
    super.key,
  });

  @override
  State<TwaiTransport0Player> createState() => _TwaiTransport0PlayerState();
}

class _TwaiTransport0PlayerState extends State<TwaiTransport0Player>
    with WidgetsBindingObserver {
  late final ValueNotifier<lk.RemoteVideoTrack?> _videoSlot;
  late LiveKitEngine _engine;
  final _subs = <StreamSubscription<Object?>>[];
  bool _speaking = false;
  // Compositor-visibility of the speaking layer. Follows `_speaking` on
  // the way UP (turn on immediately so the fade-in has something to
  // paint), and lags it on the way DOWN by [widget.fadeDuration] so the
  // opacity animation completes BEFORE we drop the platform view.
  //
  // Why this exists: on Android, `AnimatedOpacity(opacity: 0)` around
  // `lk.VideoTrackRenderer` does NOT stop the underlying SurfaceView /
  // TextureView platform view from painting — the last decoded frame
  // stays visible over the idle layer even though the Flutter side
  // reports opacity 0. Web + iOS composite correctly through opacity.
  // Wrapping in `Visibility(visible: _speakingLayerVisible)` with
  // maintainState/Animation/Size = true forces the Android compositor
  // to skip the platform view once the fade completes, so the idle
  // shows through. Reference: `c:/Dev/avatar-player/src/main.ts` —
  // Mason's `setLive(false)` uses the same "delay the hide until the
  // fade is done" ordering (via CSS `visibility:hidden` on the DOM
  // idle+live pair) for the same reason.
  bool _speakingLayerVisible = false;
  Timer? _speakingHideTimer;

  // Session-opener orchestration state. Guards against double-dispatch
  // when the engine's onReady fires more than once per mount — e.g., a
  // reconnect after a transient drop. The store check inside
  // _dispatchGreetingOnReady is the real correctness bar; this is a
  // cheap short-circuit for the common case.
  bool _greetingDispatchInFlight = false;
  bool _greetingDispatchedThisMount = false;
  Timer? _greetingDispatchTimer;
  GreetingStore? _resolvedGreetingStore;

  GreetingStore _greetingStore() {
    final store = widget.greetingStore ??
        (_resolvedGreetingStore ??= SharedPreferencesGreetingStore());
    return store;
  }

  // Widget-level rotation barrier. Same pattern PP uses in
  // `clg_penthouse_pets/frontend/src/lean/controller.ts:3947-3951`:
  // `await livekitLifecycle.waitForDisconnect()` before minting a new
  // room, so the previous session's room.disconnect() actually
  // completes before the broker sees the next mint. Without this the
  // broker sees a stale participant for the same user_id, the new
  // session's Room.connect races the old room's teardown, and the
  // engine ends up stuck in warming/joining — chip stays IDLE and
  // send() throws SessionNotReady with no visible cause.
  //
  // Static because a new State instance is created on avatar swap
  // (widget key rotates), so an instance-scoped barrier resets each
  // rebuild and doesn't chain. Class-static is the smallest change
  // that preserves ordering across the swap.
  static Future<void> _rotationBarrier = Future.value();
  // Monotonic mint attempt id, matching PP's `connectAttemptId`. The
  // barrier awaits let a fresh widget click supersede an in-flight
  // one: after the await, if attempt id has moved on, we bail.
  static int _connectAttemptId = 0;

  @override
  void initState() {
    super.initState();
    // Return-to-foreground → call resumePlayback. Ports Mason's
    // avatar-player fix f512a2b (2026-09-04): resumeMedia on tab-return
    // was reading `liveAud.srcObject` which was never assigned, so the
    // live element never resumed and the avatar looked frozen while the
    // page seemed alive. In Flutter the equivalent is
    // AppLifecycleState.resumed — Android/iOS return-to-foreground, or
    // web tab-focus. resumePlayback is a no-op when audio is already
    // playing, so calling on every resume is safe.
    WidgetsBinding.instance.addObserver(this);
    _videoSlot = ValueNotifier<lk.RemoteVideoTrack?>(null);
    // Construct engine + wire streams synchronously (safe, no listener
    // notifications), but DEFER both the onEngine callback and the
    // connect() call to a post-frame callback. Two reasons:
    //
    //   1. onEngine typically invokes LabState.bindTransport0Engine
    //      which calls notifyListeners(); doing that from inside
    //      initState() triggers "setState() called during build"
    //      because we're mid-widget-tree construction.
    //   2. connect() throws typed mint errors (MintUnavailable /
    //      MintRateLimited) on 404 / 429. Uncaught, those bubble as
    //      DartErrors from the microtask queue with no context; the
    //      catch below routes them into the widget's onNotice
    //      surrogate so they show in the STREAMS log instead.
    _engine = LiveKitEngine(LiveKitEngineOptions(
      mint: widget.mint,
      media: LiveKitEngineMedia(videoSlot: _videoSlot),
      agentIdentityPrefix: widget.agentIdentityPrefix,
      keepTags: widget.keepTags,
    ));
    _wireEngineStreams();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onEngine?.call(_engine);
      if (widget.autoConnect) {
        _connectSafely();
      }
    });
  }

  Future<void> _connectSafely() async {
    // Take a monotonic slot BEFORE the barrier await. If another
    // widget rebuilds (avatar swap) while we're waiting for the
    // previous session's disconnect to drain, our attempt id will
    // be superseded and we bail — otherwise we'd mint a room the
    // user has already navigated away from. Same PP pattern.
    final myAttempt = ++_connectAttemptId;
    try {
      await _rotationBarrier;
    } catch (_) {
      // barrier's own failure isn't ours; keep going
    }
    if (!mounted || myAttempt != _connectAttemptId) return;
    try {
      await _engine.connect();
    } catch (err) {
      // Surface via BOTH the ValueNotifier (in-widget UI can watch
      // it) AND the onError callback (host wires it to a log/event
      // stream). Without the callback the exception is invisible —
      // engine.state falls back to `idle` and the user only sees an
      // unexplained "SessionNotReady" on the next send attempt.
      // Do NOT rethrow; uncaught errors in initState-fired futures
      // show up as bright red DartErrors in the console with a
      // lab_shell build() frame that misleads.
      _engineErrors.value = '$err';
      widget.onError?.call(err);
    }
  }

  /// Last mint / connect error, or null. Consumers can watch this
  /// via a widget subscription; the built-in `onEnded` handler also
  /// fires when the engine emits `ended` for a transport-side close.
  final ValueNotifier<String?> _engineErrors = ValueNotifier<String?>(null);
  ValueListenable<String?> get errors => _engineErrors;

  void _wireEngineStreams() {
    _engine.state.addListener(_onStateChanged);
    _subs.addAll([
      _engine.onWarming.listen((e) => widget.onWarming?.call(e)),
      _engine.onReady.listen((e) {
        widget.onReady?.call(e);
        // Session opener: dispatch exactly once per widget mount; if
        // the engine re-fires ready (reconnect), the store check
        // suppresses a second send.
        unawaited(_dispatchGreetingOnReady());
      }),
      _engine.onSpeaking.listen((e) {
        // Sole visibility cue. `active=true` → show sink; `false` →
        // show idle. Matches Mason's engine.
        if (mounted && _speaking != e.active) {
          setState(() {
            _speaking = e.active;
            if (e.active) {
              // Turning on: any pending hide from the previous turn's
              // stop is now stale — cancel it and show immediately so
              // the fade-in has a paintable surface underneath.
              _speakingHideTimer?.cancel();
              _speakingHideTimer = null;
              _speakingLayerVisible = true;
            } else {
              // Turning off: let the opacity fade run to completion,
              // THEN drop the platform view from the compositor. On
              // Android this is what actually lets the idle layer
              // paint through — see _speakingLayerVisible doc.
              _speakingHideTimer?.cancel();
              _speakingHideTimer = Timer(widget.fadeDuration, () {
                if (!mounted) return;
                setState(() => _speakingLayerVisible = false);
              });
            }
          });
        }
        widget.onSpeaking?.call(e);
      }),
      _engine.onReplyStart.listen((e) => widget.onReplyStart?.call(e)),
      _engine.onReplyText.listen((e) => widget.onReplyText?.call(e)),
      _engine.onReplyComplete.listen((e) => widget.onReplyComplete?.call(e)),
      _engine.onControl.listen((e) => widget.onControl?.call(e)),
      _engine.onTranscript.listen((e) => widget.onTranscript?.call(e)),
      _engine.onEnded.listen((e) => widget.onEnded?.call(e)),
      _engine.onNotice.listen((e) => widget.onNotice?.call(e)),
    ]);
  }

  void _onStateChanged() {
    widget.onState?.call(_engine.state.value);
  }

  /// Session-opener dispatch, called on every `onReady` fire.
  ///
  /// Only [TwaiGreetingText] does anything here in Phase 1 — the
  /// `.rendered` and `.dynamic` variants are declared in the SDK but
  /// their widget integration ships in Phase 2 (needs catalog hydrate
  /// to be useful). `.none` is a no-op.
  ///
  /// Guards:
  ///   - Short-circuits if a dispatch is already in flight for THIS
  ///     mount (concurrent onReady fires can happen during reconnect).
  ///   - After a successful send, [_greetingDispatchedThisMount] stays
  ///     true for the lifetime of the widget mount; subsequent onReady
  ///     fires (reconnect) won't try again. Scope-level dedup is the
  ///     store's job; this is a cheap mount-local flag.
  ///   - A send that throws rolls back the store flag so a later
  ///     reconnect can retry.
  Future<void> _dispatchGreetingOnReady() async {
    if (_greetingDispatchInFlight || _greetingDispatchedThisMount) return;
    final greeting = widget.greeting;
    final resolved = await _resolveGreeting(greeting);
    if (resolved is! TwaiGreetingText) return;
    if (_greetingDispatchInFlight || _greetingDispatchedThisMount) return;
    _greetingDispatchInFlight = true;
    try {
      if (!mounted) return;
      final store = _greetingStore();
      if (await store.hasBeenSent(resolved.scopeId)) {
        _greetingDispatchedThisMount = true;
        return;
      }
      // Mark BEFORE the send so a late second onReady (reconnect
      // mid-send) doesn't double-fire. Roll back on send failure.
      await store.markSent(resolved.scopeId);
      // Delay to clear the engine's SEND_GRACE_MS window.
      if (resolved.sendAfterReady > Duration.zero) {
        final completer = Completer<void>();
        _greetingDispatchTimer?.cancel();
        _greetingDispatchTimer = Timer(resolved.sendAfterReady, () {
          if (!completer.isCompleted) completer.complete();
        });
        await completer.future;
      }
      if (!mounted) return;
      try {
        await _engine.send(resolved.text);
        _greetingDispatchedThisMount = true;
        resolved.onSent?.call();
      } catch (_) {
        // Send failed — roll back the store flag so a reconnect-driven
        // ready can retry. Deliberately swallow; the engine's own
        // onError surface is where the host sees send failures.
        await store.clear(resolved.scopeId);
        rethrow;
      }
    } catch (err, stack) {
      // Diagnostic only — the host sees send failures through the
      // engine's own error path, not through greeting onSent.
      debugPrint('[TwaiTransport0Player] greeting dispatch failed: $err\n$stack');
    } finally {
      _greetingDispatchInFlight = false;
    }
  }

  /// Resolves [TwaiGreetingDynamic] to its concrete inner variant;
  /// returns other variants as-is. Only one level of indirection is
  /// supported — a dynamic that returns another dynamic is a bug and
  /// is logged, not recursed, to prevent an infinite dispatch loop.
  Future<TwaiGreeting> _resolveGreeting(TwaiGreeting greeting) async {
    if (greeting is! TwaiGreetingDynamic) return greeting;
    try {
      final resolved = await greeting.fetch();
      if (resolved is TwaiGreetingDynamic) {
        debugPrint(
          '[TwaiTransport0Player] TwaiGreeting.dynamic returned another '
          'TwaiGreeting.dynamic; treating as .none to avoid recursion.',
        );
        return const TwaiGreetingNone();
      }
      return resolved;
    } catch (err, stack) {
      debugPrint(
        '[TwaiTransport0Player] TwaiGreeting.dynamic fetch failed: $err\n$stack',
      );
      return const TwaiGreetingNone();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Fire-and-forget: engine.resumePlayback is defensively no-op when
      // audio is already playing or the room is not connected yet.
      unawaited(_engine.resumePlayback());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speakingHideTimer?.cancel();
    _speakingHideTimer = null;
    _greetingDispatchTimer?.cancel();
    _greetingDispatchTimer = null;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _engine.state.removeListener(_onStateChanged);
    // Chain THIS engine's disconnect onto the rotation barrier so
    // any subsequent widget's _connectSafely awaits it before minting
    // a fresh room. Fire-and-forget on the caller side (dispose
    // itself is synchronous), but the next connect will see the
    // updated barrier and wait. The .catchError() prevents a failing
    // disconnect from breaking the chain — the barrier is about
    // ordering, not error propagation.
    final engine = _engine;
    _rotationBarrier = _rotationBarrier
        .catchError((_) {})
        .then((_) async {
      await engine.disconnect();
      await engine.dispose();
    });
    _videoSlot.dispose();
    super.dispose();
  }

  Future<void> _resumePlaybackOnGesture() async {
    // First gesture on the stage lifts the browser's autoplay gate.
    // Ports Mason's `livekit_transport.ts:116-125` `resumePlayback()`
    // call site — PP fires it from a real click / tap handler. See
    // engine.resumePlayback for why this MUST be synchronous with
    // the gesture (browser policy requires the audio unlock call to
    // originate inside the tap handler's stack).
    unawaited(_engine.resumePlayback());
  }

  @override
  Widget build(BuildContext context) {
    // GestureDetector wraps the whole stage so ANY tap on the video
    // area lifts autoplay. HitTestBehavior.opaque so the detector
    // catches taps even on transparent-idle stages. onTapDown fires
    // synchronously inside the browser's gesture context — later
    // async continuations wouldn't count as a user gesture and
    // startAudio() would silently reject.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _resumePlaybackOnGesture(),
      child: Stack(
      fit: StackFit.expand,
      children: [
        // Idle layer — always drawn. When the speaking overlay is
        // opacity 0, this is what the user sees. Deliberately built
        // via a callback so the caller can pass any widget shape
        // (looping video, poster, solid color) without the sink
        // package depending on any specific idle-source API.
        if (widget.idleBuilder != null)
          widget.idleBuilder!(context)
        else
          const SizedBox.expand(),
        // Speaking layer — the WebRTC video track. Bound to the
        // engine-owned ValueNotifier so it reflects the current
        // track without any subscription race. AnimatedOpacity gate
        // is driven by the `onSpeaking` events alone; the video
        // element itself always mounts once a track exists so
        // adaptiveStream (which we disabled) never sees the
        // subscription pause.
        // Visibility gate composed OUTSIDE AnimatedOpacity so the
        // fade animation still runs at the Flutter layer before the
        // compositor drops the platform view. maintainState /
        // maintainAnimation / maintainSize = true keep the track
        // subscription and the underlying VideoTrackRenderer alive
        // across the hide/show cycle — no resubscribe cost on the
        // next turn. See _speakingLayerVisible for why this exists.
        Visibility(
          visible: _speakingLayerVisible,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: AnimatedOpacity(
            opacity: _speaking ? 1.0 : 0.0,
            duration: widget.fadeDuration,
            child: ValueListenableBuilder<lk.RemoteVideoTrack?>(
              valueListenable: _videoSlot,
              builder: (context, track, _) {
                if (track == null) return const SizedBox.expand();
                return lk.VideoTrackRenderer(
                  track,
                  fit: lk.VideoViewFit.contain,
                  mirrorMode: lk.VideoViewMirrorMode.off,
                );
              },
            ),
          ),
        ),
      ],
      ),
    );
  }
}
