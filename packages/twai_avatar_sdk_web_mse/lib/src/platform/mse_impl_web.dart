// Real MSE implementation for Flutter web.
//
// Phase 1b status: MediaSource + SourceBuffer + append queue live.
// - Constructor creates HTMLVideoElement + MediaSource + platform view
// - `sourceopen` handler adds a SourceBuffer with the verified codec
// - `appendBytes` enqueues; `_drain` funnels through the backpressure
//   guard (`SourceBuffer.updating`) via the `updateend` handler
//
// Phase 1c will subscribe to controller streams and pipe them through
// [appendBytes]. Phase 1d will wire timeupdate/waiting listeners.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// iOS 17.1+ Safari ships `ManagedMediaSource` as a separate global.
/// Plain `MediaSource` on iPhone Safari hangs the `<video>` at
/// HAVE_METADATA even when `isTypeSupported` returns true — the
/// element never advances past the metadata phase and no bytes play.
/// Detecting the managed variant and using it fixes the hang.
///
/// Modeled after twai-web-sdk mseSession.ts:40-44 and matches the
/// same detection logic Safari 17.1+ shipped for MSE-in-video.
///
/// Returns null on any platform that doesn't ship the global — the
/// caller falls back to plain `MediaSource`.
web.MediaSource? _tryConstructManagedMediaSource() {
  final ctor = web.window.getProperty('ManagedMediaSource'.toJS);
  if (ctor == null || ctor.isUndefinedOrNull) return null;
  try {
    // ManagedMediaSource inherits from MediaSource — interface
    // identity means we can treat the constructed instance as one.
    final instance = (ctor as JSFunction).callAsConstructor<JSObject>();
    return instance as web.MediaSource;
  } catch (_) {
    return null;
  }
}

/// Real-web MediaSource + SourceBuffer wrapper.
///
/// Owns the browser `<video>` element + `MediaSource` + `SourceBuffer`
/// trio. Exposes a small imperative surface the [WebMseStreamSink]
/// drives:
///
/// - [appendBytes] — enqueue fMP4 chunk for `SourceBuffer.appendBuffer`
/// - [currentTime] — current playhead (seconds), from HTMLVideoElement
/// - [bufferEnd] — last buffered timestamp (seconds), i.e. live edge
/// - [seekTo] — set playhead
/// - Callbacks: [onFirstFrame], [onWaiting], [onTimeUpdate]
class MseImpl {
  MseImpl({
    required this.codec,
    required this.evictKeepBehindSec,
    required this.onFirstFrame,
    required this.onWaiting,
    required this.onTimeUpdate,
  }) {
    if (!web.MediaSource.isTypeSupported(codec)) {
      throw StateError(
        'Browser does not support MSE codec "$codec". Verify codec '
        'string matches the worker output — see port spec §5.4.',
      );
    }

    // Start muted so Chrome / Safari autoplay policies actually play.
    // The gesture listener (below) unmutes on first pointerdown /
    // keydown / touchstart. Ported from twai-web-sdk mseSession.ts
    // — without it the avatar is silent for the whole session on
    // any browser with autoplay-with-sound restrictions.
    _videoEl = web.HTMLVideoElement()
      ..autoplay = true
      ..controls = false
      ..muted = true
      ..playsInline = true;

    // iOS 17.1+ Safari needs ManagedMediaSource — plain MediaSource
    // hangs at HAVE_METADATA. Detect + prefer the managed variant
    // when the global exists; fall back to plain MediaSource
    // everywhere else. See _tryConstructManagedMediaSource docstring.
    final managed = _tryConstructManagedMediaSource();
    _mediaSource = managed ?? web.MediaSource();

    // Attach the MediaSource to the video element. Two paths:
    //
    // - **ManagedMediaSource (iOS 17.1+)** — MUST use `srcObject`.
    //   Blob-URL attach doesn't work; the element stays wedged at
    //   HAVE_METADATA even after append. Verified against
    //   2wai-edu's useMseAvatarPlayer (lines 106-115 + 384-391) and
    //   twai-web-sdk's mseSession.ts (lines 188-203).
    // - **Plain MediaSource** — blob URL is the standard attach path
    //   everywhere it works (Chrome, Firefox, Edge, older Safari).
    //   Must revoke in [dispose].
    if (managed != null) {
      _videoEl.srcObject = managed as web.MediaProvider;
      _srcUrl = null;
    } else {
      final url = web.URL.createObjectURL(_mediaSource);
      _srcUrl = url;
      _videoEl.src = url;
    }

    // Faithful-port fix (2026-07-24, verified against
    // clg_penthouse_pets/frontend/src/lean/controller.ts:2189-2190 which
    // is the ACTIVE MuseTalk client on staging using /ext-api-muse/).
    // Set muted=true AFTER src attach + explicit .load() to kick media
    // loading. Without .load() Chrome does not initiate media parse
    // reliably; SourceBuffer parser hangs and CHUNK_DEMUXER_ERROR_APPEND_FAILED
    // fires on first append.
    _videoEl.muted = true;
    try {
      _videoEl.load();
    } catch (_) {
      // load() should not throw; best-effort.
    }

    // Port spec §12.1.1 — iOS `ManagedMediaSource` wedges on
    // gestureless connect. Calling `.play()` (even when the browser
    // rejects the promise due to autoplay policy) mutates the
    // element to "loading," which propagates to the MediaSource and
    // triggers `sourceopen`. Without this the connect stalls forever
    // on iOS 18.7+.
    //
    // `autoplay = true` (set above) is insufficient on its own for
    // this specific quirk — the explicit `.play()` is the extra kick
    // the reference impl found necessary. Harmless on other browsers.
    _kickPlay();

    // Register a platform view so a Flutter HtmlElementView can host
    // this <video>. The id is unique per instance so multiple sinks
    // (e.g. dev A/B comparison) don't collide.
    _viewId = 'twai-web-mse-${_seq++}';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewId,
      (int _) => _videoEl,
    );

    // Listeners. See event handlers below for behavior.
    _mediaSource.addEventListener('sourceopen', _onSourceOpen.toJS);
    _videoEl.addEventListener('playing', _onPlaying.toJS);
    _videoEl.addEventListener('waiting', _onWaitingEvent.toJS);
    _videoEl.addEventListener('timeupdate', _onTimeUpdateEvent.toJS);

    _installGestureUnmute();
  }

  /// Attach a one-shot global gesture listener that unmutes the
  /// video on the first pointerdown / keydown / touchstart. The
  /// listeners self-remove after firing.
  ///
  /// Chrome's autoplay policy blocks audio without a prior user
  /// interaction; without this wiring the avatar would be silent for
  /// the whole session on any page the user hasn't clicked yet.
  /// Ported from twai-web-sdk mseSession.ts:88-117.
  void _installGestureUnmute() {
    // Store the JSFunction refs so we can un-register the SAME
    // wrappers later. `.toJS` each time yields a different function
    // identity, so we bind once here.
    _gestureHandlerJs = _handleFirstGesture.toJS;
    for (final ev in const ['pointerdown', 'keydown', 'touchstart']) {
      web.window.addEventListener(ev, _gestureHandlerJs);
    }
  }

  void _handleFirstGesture(web.Event _) {
    if (_disposed || _gestureSeen) return;
    _gestureSeen = true;
    // Un-register — one-shot semantics. Uses the SAME JSFunction
    // instance we registered in _installGestureUnmute so the
    // browser's listener map finds the match.
    for (final ev in const ['pointerdown', 'keydown', 'touchstart']) {
      web.window.removeEventListener(ev, _gestureHandlerJs);
    }
    _videoEl.muted = false;
    // Retry play — the initial autoplay may have been rejected;
    // this call is now within a user-gesture handler and will
    // succeed. Rejection is still harmless (element may already be
    // playing muted).
    _videoEl.play().toDart.catchError((_) {
      return null;
    });
  }

  final String codec;
  final int evictKeepBehindSec;
  final void Function() onFirstFrame;
  final void Function() onWaiting;
  final void Function(double seconds) onTimeUpdate;

  static int _seq = 0;

  late final web.HTMLVideoElement _videoEl;
  late final web.MediaSource _mediaSource;
  // Null when attached via `srcObject` (ManagedMediaSource on iOS
  // 17.1+). Non-null when attached via blob URL (standard path on
  // Chrome / Firefox / Edge / older Safari); the URL must be revoked
  // on dispose to release the browser's grip on the MediaSource.
  String? _srcUrl;
  late final String _viewId;

  web.SourceBuffer? _sourceBuffer;

  /// Chunks that arrived before [_sourceBuffer] existed OR while
  /// `_sourceBuffer.updating == true`. Drained on `sourceopen` and
  /// `updateend`. Kept as a queue so ordering is preserved.
  final List<Uint8List> _appendQueue = <Uint8List>[];

  bool _firstFrameSignalled = false;
  bool _disposed = false;

  /// True once the first user gesture fired and audio was unmuted.
  /// The gesture listeners self-remove after that; a subsequent
  /// reconnect (Phase B2) will NOT re-mute.
  bool _gestureSeen = false;

  /// The bound JSFunction wrapper for [_handleFirstGesture]. Held
  /// so `removeEventListener` finds the exact same identity — a
  /// fresh `.toJS` yields a different function each call.
  late final JSFunction _gestureHandlerJs;

  /// Called by [WebMseStreamSink] on every video-bytes frame.
  /// Non-blocking — enqueues + kicks the drain.
  void appendBytes(List<int> bytes) {
    if (_disposed) return;
    _appendQueue.add(Uint8List.fromList(bytes));
    _drain();
  }

  double? get currentTime {
    if (_disposed) return null;
    final t = _videoEl.currentTime;
    return t.isFinite ? t : null;
  }

  double? get bufferEnd {
    if (_disposed) return null;
    final ranges = _videoEl.buffered;
    if (ranges.length == 0) return null;
    final end = ranges.end(ranges.length - 1);
    return end.isFinite ? end : null;
  }

  void seekTo(double seconds) {
    if (_disposed) return;
    if (!seconds.isFinite) return;
    _videoEl.currentTime = seconds;
  }

  /// Evict buffered ranges older than [keepBehindSec] behind current
  /// playhead. Prevents OOM stutter after long sessions (port spec §3
  /// — `EVICT_KEEP_BEHIND_SEC = 5`).
  ///
  /// No-op if:
  /// - SourceBuffer not yet created
  /// - SourceBuffer is currently `updating` (an append/remove is in flight)
  /// - The append queue is non-empty (let appends drain first — remove()
  ///   would race)
  /// - Playhead hasn't advanced past [keepBehindSec] (nothing to evict)
  void evictOldBuffer(double keepBehindSec) {
    if (_disposed) return;
    final buf = _sourceBuffer;
    if (buf == null) return;
    if (buf.updating) return;
    if (_appendQueue.isNotEmpty) return;
    final t = _videoEl.currentTime;
    if (!t.isFinite || t < keepBehindSec) return;
    final evictEnd = t - keepBehindSec;
    try {
      buf.remove(0, evictEnd);
    } catch (_) {
      // InvalidStateError under weird timing — best-effort.
    }
  }

  Widget buildWidget() => HtmlElementView(viewType: _viewId);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _appendQueue.clear();
    // Remove any un-fired gesture listeners. If the user disposed
    // before gesturing, leaving them attached would leak — every
    // subsequent tap on the page would trigger a dead handler
    // trying to unmute an already-disposed video.
    if (!_gestureSeen) {
      for (final ev in const ['pointerdown', 'keydown', 'touchstart']) {
        web.window.removeEventListener(ev, _gestureHandlerJs);
      }
    }
    // Signal end-of-stream if we can, then revoke the blob URL to
    // free the browser's grip on the MediaSource.
    try {
      if (_mediaSource.readyState == 'open') {
        _mediaSource.endOfStream();
      }
    } catch (_) {
      // Best-effort; if endOfStream throws (unusual state) we still
      // want to proceed with URL revocation.
    }
    // Only revoke when we minted one. srcObject-attach paths (iOS
    // ManagedMediaSource) never allocate a blob URL.
    final url = _srcUrl;
    if (url != null) {
      web.URL.revokeObjectURL(url);
      _srcUrl = null;
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Event handlers
  // ══════════════════════════════════════════════════════════════════

  /// The gestureless-connect kick (port spec §12.1.1). Calling
  /// `videoEl.play()` — even when the browser rejects the returned
  /// Promise due to autoplay policy — mutates the element into a
  /// "loading" state that propagates through the attached
  /// MediaSource and triggers `sourceopen`.
  ///
  /// Also usable after a dead-man's-gap kick (§12.1.5) if we ever
  /// need to nudge a frozen playhead from the sink side.
  void _kickPlay() {
    if (_disposed) return;
    final promise = _videoEl.play();
    // Convert the JSPromise to a Dart future purely so we can attach
    // a catchError — the rejection is EXPECTED under autoplay policy
    // and doesn't indicate a problem; the side-effect of the call
    // is what we want. Swallow silently.
    promise.toDart.catchError((_) {
      // Autoplay blocked — that's fine. The kick still fired.
      return null;
    });
  }

  void _onSourceOpen(web.Event _) {
    if (_disposed) return;
    if (_sourceBuffer != null) return; // sourceopen can fire twice
    try {
      final buf = _mediaSource.addSourceBuffer(codec);
      // REQUIRED for muse's fMP4 stream — matches
      // clg_penthouse_pets/frontend/src/lean/controller.ts:2363. Chrome's
      // default `'segments'` mode expects each chunk to carry its own
      // baseMediaDecodeTime; muse resets timestamps per turn so segments
      // mode rejects with CHUNK_DEMUXER_ERROR_APPEND_FAILED.
      buf.mode = 'sequence';
      buf.addEventListener('updateend', _onUpdateEnd.toJS);
      _sourceBuffer = buf;
    } catch (e) {
      // If addSourceBuffer throws (bad codec, wrong readyState), we
      // can't recover in-place. The sink's dispose will catch this
      // via the video element error path in Phase 1d.
      return;
    }
    _drain();
  }

  void _onUpdateEnd(web.Event _) {
    if (_disposed) return;
    _drain();
  }

  void _drain() {
    if (_disposed) return;
    final buf = _sourceBuffer;
    if (buf == null) return; // sourceopen hasn't fired yet
    if (buf.updating) return; // backpressure — wait for updateend
    if (_appendQueue.isEmpty) return;
    final chunk = _appendQueue.removeAt(0);
    try {
      buf.appendBuffer(chunk.toJS);
    } catch (e) {
      // QuotaExceededError is the main case we care about; in Phase
      // 1f (buffer eviction) the sink evicts older ranges before
      // hitting quota. For now, swallow — the queue keeps flowing
      // and the browser will drop the append.
    }
  }

  void _onPlaying(web.Event _) {
    if (_disposed) return;
    if (_firstFrameSignalled) return;
    _firstFrameSignalled = true;
    onFirstFrame();
  }

  void _onWaitingEvent(web.Event _) {
    if (_disposed) return;
    onWaiting();
  }

  void _onTimeUpdateEvent(web.Event _) {
    if (_disposed) return;
    final t = _videoEl.currentTime;
    if (t.isFinite) onTimeUpdate(t);
  }
}
