import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
// `twai_avatar_sdk` re-exports the core symbols we use (ChatSession,
// SpeakingEvent) — one import covers both.
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

import 'platform/mse_impl.dart';

/// Real-MSE tail-following [VideoSink] for Flutter web.
///
/// Bit-for-bit sink counterpart to the reference controller (see
/// `docs/port_spec_avatar_player.md` §5) and target of
/// `docs/sink_streaming_scoping.md` Phase 1. Appends fMP4 chunks to a
/// growing `SourceBuffer` as they arrive from the WS, drives an
/// `HTMLVideoElement` against the continuous timeline, and honors the
/// controller's live-edge clamp + jitter margin + PTS-gated speaking
/// discipline.
///
/// # Session model
///
/// Unlike [VideoPlayerMseStreamSink] and [MediaKitMseStreamSink], this
/// sink is **controller-owned**, not session-owned. It subscribes to
/// the [TwaiAvatarPlayerController]'s broadcast streams (`videoBytes`,
/// `speakingEvents`) which survive session rotation, so a reconnect
/// under the sink is transparent — the sink stays attached and
/// keeps appending to the same `SourceBuffer`.
///
/// The [attach] parameter is kept for [VideoSink] interface compat but
/// is ignored — the sink reads from [controller] instead. If you want
/// to swap in a new controller, dispose this sink and construct a
/// fresh one.
///
/// # Port status (2026-07-20)
///
/// - [x] Package structure + conditional-import platform boundary
/// - [x] Constructor + [VideoSink] interface conformance
/// - [x] `MediaSource` + `SourceBuffer` open + append queue (Phase 1b)
/// - [x] Video-bytes + speaking-event stream subscriptions (Phase 1c)
/// - [x] `timeupdate` → `controller.updatePlaybackTime` (Phase 1d)
/// - [x] `waiting` → `controller.notifyStall` (guarded on speaking) (Phase 1d)
/// - [x] 1s clamp heartbeat + seek on `computeClampTargetSec` (Phase 1e)
/// - [x] Buffer eviction per `evictKeepBehindSec` (Phase 1f)
/// - [x] iOS gestureless `play()` kick (Phase 1g §12.1.1)
///
/// Phase 1 complete against the reference workaround catalog for the
/// controller-driven MSE sink. What's deferred to a later slice:
///
/// - [ ] iOS `ManagedMediaSource` type selection (currently uses
///       `MediaSource` universally; adequate on Chrome/Firefox/Safari
///       desktop, needs verification on iOS Safari 17.1+)
/// - [ ] Real browser tests via `flutter test --platform chrome`
///
/// # Non-web platforms
///
/// Constructing this class outside Flutter web throws
/// `UnsupportedError`. Multi-platform apps should conditional-import
/// alongside a fallback:
///
/// ```dart
/// // sink_factory_stub.dart
/// VideoSink makeSink({required TwaiAvatarPlayerController controller}) =>
///     VideoPlayerMseStreamSink(); // non-web fallback
///
/// // sink_factory_web.dart
/// VideoSink makeSink({required TwaiAvatarPlayerController controller}) =>
///     WebMseStreamSink(controller: controller);
///
/// // sink_factory.dart
/// export 'sink_factory_stub.dart'
///     if (dart.library.js_interop) 'sink_factory_web.dart';
/// ```
class WebMseStreamSink implements VideoSink {
  // Web MSE tail-follows the WS into a live SourceBuffer — visibility
  // is entirely gated on the controller's speaking-status flag, so the
  // sink itself never claims to self-render. Passive listenable.
  @override
  ValueListenable<bool> get isRenderingContent => alwaysNotRendering;

  WebMseStreamSink({
    required this.controller,
    PlayerConfig? config,
    this.placeholderBuilder,
  }) : config = config ?? const PlayerConfig() {
    _impl = MseImpl(
      codec: this.config.mseCodec,
      evictKeepBehindSec: this.config.evictKeepBehindSec,
      onFirstFrame: _handleFirstFrame,
      onWaiting: _handleWaiting,
      onTimeUpdate: _handleTimeUpdate,
    );
    // LATE-SUBSCRIBER INIT REPLAY (2026-07-24) — muse sends the fMP4
    // init segment (ftyp+moov) as the FIRST binary WS frame per
    // session and never again. If this sink is constructed AFTER
    // that first frame flew past (e.g. a portrait/landscape layout
    // swap in the widget tree creates a fresh sink on the same
    // handle), our SourceBuffer would start receiving mid-stream
    // `moof`/`mdat` fragments with no init and Chrome's demuxer
    // fails with `CHUNK_DEMUXER_ERROR_APPEND_FAILED /
    // RunSegmentParserLoop`. Prepend the controller's cached init
    // BEFORE subscribing so the sink's `_appendQueue` gets init at
    // position 0 and everything after is in the correct order.
    final cachedInit = controller.cachedInitSegment;
    if (cachedInit != null) {
      _onVideoBytes(cachedInit);
    }

    // Subscribe to controller streams immediately. The sink is
    // sink-per-controller, not sink-per-session — its lifecycle is
    // tied to the controller, not to any individual session inside
    // it. `attach(ChatSession)` (the VideoSink interface method) is
    // kept as a no-op for compatibility with existing stage
    // infrastructure; callers of the new sink don't need to invoke
    // it.
    _bytesSub = controller.videoBytes.listen(_onVideoBytes);
    _speakingSub = controller.speakingEvents.listen(_onSpeakingEvent);
    _clampHeartbeat = Timer.periodic(
      const Duration(seconds: 1),
      _onClampHeartbeat,
    );
  }

  /// The controller that owns the session lifecycle + state machine.
  /// The sink subscribes to its broadcast streams and calls its
  /// clamp/stall/playback-time methods.
  final TwaiAvatarPlayerController controller;

  /// Configuration passthrough — codec, eviction window, clamp
  /// thresholds. Defaults to `const PlayerConfig()`.
  final PlayerConfig config;

  /// Optional widget to render before the sink is attached / while
  /// the first frame is loading. If null, the sink renders a small
  /// diagnostic label ("Phase 1a skeleton" in the current build).
  ///
  /// Real customer apps almost always want to pass
  /// `(_) => const SizedBox.expand()` so a wrapping idle/poster layer
  /// shows through.
  final WidgetBuilder? placeholderBuilder;

  late final MseImpl _impl;

  bool _firstFrameReceived = false;
  bool _disposed = false;
  StreamSubscription<Uint8List>? _bytesSub;
  StreamSubscription<SpeakingEvent>? _speakingSub;

  /// 1-second wall-clock heartbeat that polls [MseImpl.currentTime] +
  /// [MseImpl.bufferEnd] and consults
  /// [TwaiAvatarPlayerController.computeClampTargetSec]. Seeks if the
  /// controller returns a target. Port spec §5.1 + §12.1.4 — this is
  /// the SEPARATE wall-clock timer that runs alongside timeupdate,
  /// because iOS throttles timeupdate during long idles.
  Timer? _clampHeartbeat;

  @override
  Future<void> attach(ChatSession _) async {
    // No-op. The sink self-subscribes to controller streams in its
    // constructor — this method exists only for VideoSink interface
    // compat. Calling attach() after dispose is still an error.
    if (_disposed) {
      throw StateError('WebMseStreamSink used after dispose');
    }
  }

  @override
  Widget buildWidget() {
    if (placeholderBuilder != null && !_firstFrameReceived) {
      return Builder(builder: placeholderBuilder!);
    }
    return _impl.buildWidget();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _clampHeartbeat?.cancel();
    _clampHeartbeat = null;
    await _bytesSub?.cancel();
    _bytesSub = null;
    await _speakingSub?.cancel();
    _speakingSub = null;
    await _impl.dispose();
  }

  // ══════════════════════════════════════════════════════════════════
  // Controller stream handlers (Phase 1c)
  // ══════════════════════════════════════════════════════════════════

  void _onVideoBytes(Uint8List bytes) {
    if (_disposed) return;
    _impl.appendBytes(bytes);
  }

  void _onSpeakingEvent(SpeakingEvent ev) {
    if (_disposed) return;
    // Dead-man's-gap kick (port spec §12.1.5): when a speaking:start
    // arrives, nudge the playhead forward via the clamp — iOS muted
    // MSE elements can freeze mid-idle with a pending PTS stranded.
    // The `computeClampTargetSec` path is heartbeat-driven (Phase 1e),
    // but a stranded PTS never triggers timeupdate. So we call it
    // OFF the event, not off a timer, to resume playback even from
    // a frozen state.
    if (ev.value != SpeakingState.start) return;
    _kickClamp();
  }

  void _kickClamp() {
    final playback = _impl.currentTime;
    final bufferEnd = _impl.bufferEnd;
    if (playback == null || bufferEnd == null) return;
    final target = controller.computeClampTargetSec(
      playbackTimeSec: playback,
      bufferEndSec: bufferEnd,
    );
    if (target != null) _impl.seekTo(target);
  }

  void _onClampHeartbeat(Timer _) {
    if (_disposed) return;
    // Only clamp/evict while the pipeline is actively producing (ready
    // or speaking). No point seeking mid-connect/failed — the timeline
    // isn't advancing yet, and we'd race the sink's own state.
    final status = controller.currentStatus;
    if (status != PlayerStatus.ready && status != PlayerStatus.speaking) {
      return;
    }
    _kickClamp();
    // Evict AFTER the clamp — if we just seeked forward, currentTime
    // jumped, so the eviction window is measured from the new
    // playhead. Port spec §3 EVICT_KEEP_BEHIND_SEC.
    _impl.evictOldBuffer(config.evictKeepBehindSec.toDouble());
  }

  // ══════════════════════════════════════════════════════════════════
  // MseImpl callbacks (Phase 1d)
  // ══════════════════════════════════════════════════════════════════

  void _handleFirstFrame() {
    if (_disposed) return;
    _firstFrameReceived = true;
    // NOTE: the controller already transitions to `ready` on first
    // WS-byte arrival. This flag is sink-local for placeholder
    // swap-out only.
  }

  void _handleWaiting() {
    if (_disposed) return;
    // Gate on speaking status — idle-time stalls are the sink's
    // problem, not the state machine's. Only mid-speech stalls bump
    // the jitter margin.
    if (controller.currentStatus != PlayerStatus.speaking) return;
    controller.notifyStall();
  }

  void _handleTimeUpdate(double seconds) {
    if (_disposed) return;
    controller.updatePlaybackTime(seconds);
  }
}
