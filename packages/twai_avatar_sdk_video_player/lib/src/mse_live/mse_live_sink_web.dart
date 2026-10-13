import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:web/web.dart' as web;

/// [VideoSink] for Adapter 1 (penthouse MSE-over-WS) with **true
/// streaming playback** via the browser's Media Source Extensions API.
///
/// Unlike [VideoPlayerMseStreamSink] (which buffers each turn into a
/// complete MP4 blob and plays it after `speaking:stop` + tail window),
/// this sink feeds fMP4 fragments directly into a `SourceBuffer` as
/// they arrive on the WebSocket. First-frame latency drops from ~9s
/// to ~1-2s (one fragment plus decoder warm-up). This is the same
/// strategy penthouse uses natively and is the SOTA approach for
/// avatar streaming on the web.
///
/// **Web-only.** Native targets get a stub that throws on construction
/// (see `mse_live_sink_stub.dart`).
///
/// Tradeoffs vs the buffered sink:
/// - + Far lower first-frame latency.
/// - + No per-turn controller churn — one `<video>` element for the
///     entire session.
/// - + Idle frames between turns play naturally instead of being
///     dropped.
/// - – Web-only.
/// - – Speaking events become advisory (UI hints) rather than turn
///     boundaries; this sink ignores them.
/// - – Autoplay-with-sound rules: the first reply on a cold connection
///     may play muted until a user gesture occurs (subsequent replies
///     get audio).
class VideoPlayerMseLiveSink implements VideoSink {
  @override
  ValueListenable<bool> get isRenderingContent => alwaysNotRendering;

  VideoPlayerMseLiveSink({this.debugLog = false})
      : _viewType = 'twai-mse-live-${DateTime.now().microsecondsSinceEpoch}' {
    // Register the platform view factory eagerly. Flutter Web caches
    // factories by view type; the unique `_viewType` ensures multiple
    // sink instances don't collide.
    ui_web.platformViewRegistry.registerViewFactory(_viewType, _viewFactory);
  }

  /// Verbose per-event logging (init/append/sourceopen/updateend).
  final bool debugLog;

  final String _viewType;

  StreamSubscription<Uint8List>? _bytesSub;
  StreamSubscription<SpeakingEvent>? _speakingSub;
  bool _attached = false;
  bool _disposed = false;
  DateTime? _attachedAt;

  web.HTMLVideoElement? _videoElement;
  web.MediaSource? _mediaSource;
  web.SourceBuffer? _sourceBuffer;
  String? _objectUrl;

  Uint8List? _initSegment;
  // Fragments waiting for the source buffer to become idle. Drained
  // on every `updateend`.
  final _appendQueue = <Uint8List>[];

  String _ts() {
    final t = _attachedAt;
    if (t == null) return '?';
    return '${DateTime.now().difference(t).inMilliseconds.toString().padLeft(5)}ms';
  }

  void _log(String msg) {
    if (!debugLog) return;
    debugPrint('[twai_mse_live ${_ts()}] $msg');
  }

  // The factory may be called BEFORE attach() is called, or after.
  // It just creates and configures the <video> element; MediaSource
  // attachment is gated on having both element + init segment.
  web.HTMLVideoElement _viewFactory(int id) {
    final v = web.HTMLVideoElement();
    v.autoplay = true;
    v.controls = false;
    // Muted-by-default so Chrome's autoplay-with-sound policy doesn't
    // block playback. The page can call element.unmute() later (or we
    // can unmute on first user gesture). Without this, the very first
    // play() call after src is set silently fails with NotAllowedError
    // and the video element stays paused on its first frame.
    v.muted = true;
    v.style.width = '100%';
    v.style.height = '100%';
    v.style.objectFit = 'contain';
    v.style.backgroundColor = '#000000';
    // playsInline is essential on iOS Safari — without it the video
    // tries to go fullscreen, which an embedded widget can't survive.
    v.setAttribute('playsinline', 'true');
    _videoElement = v;
    _log('view factory: created <video> element');
    _maybeAttachMediaSource();
    return v;
  }

  @override
  Future<void> attach(ChatSession session) async {
    if (_attached) {
      throw StateError('VideoPlayerMseLiveSink.attach called twice');
    }
    _attached = true;
    _attachedAt = DateTime.now();
    _log('attach: subscribing to videoBytes + speakingEvents');
    _bytesSub = session.videoBytes.listen(_onBytes);
    _speakingSub = session.speakingEvents.listen(_onSpeaking);
  }

  void _onBytes(Uint8List bytes) {
    if (_disposed) return;
    if (_initSegment == null) {
      _initSegment = bytes;
      _log('bytes: ${bytes.length}B — cached as init segment');
      _maybeAttachMediaSource();
      return;
    }
    _appendQueue.add(bytes);
    _log('bytes: ${bytes.length}B — queued (queue=${_appendQueue.length}, '
        'sb.updating=${_sourceBuffer?.updating})');
    _flushAppendQueue();
  }

  void _onSpeaking(SpeakingEvent ev) {
    _log('speaking ${ev.value.name} pts=${ev.pts?.toStringAsFixed(2) ?? 'n/a'} (advisory)');
  }

  // Wires the MediaSource to the <video> element. Idempotent — only
  // fires the first time we have both element and init segment.
  void _maybeAttachMediaSource() {
    if (_disposed) return;
    if (_mediaSource != null) return;
    if (_videoElement == null) return;
    if (_initSegment == null) return;

    final ms = web.MediaSource();
    _mediaSource = ms;
    ms.addEventListener('sourceopen', _onSourceOpen.toJS);
    ms.addEventListener('sourceended', _onSourceEnded.toJS);
    ms.addEventListener('sourceclose', _onSourceClose.toJS);

    final url = web.URL.createObjectURL(ms);
    _objectUrl = url;
    _videoElement!.src = url;
    _log('attached MediaSource to <video>, awaiting sourceopen');
  }

  void _onSourceOpen(web.Event _) {
    final ms = _mediaSource;
    final init = _initSegment;
    if (ms == null || init == null) return;

    // For an unbounded live stream, the duration must be Infinity. The
    // default (NaN) keeps the video element waiting for a finite
    // duration before allowing the playhead to advance past the first
    // sample. Without this, "first frame appears, no playback" is the
    // common symptom.
    try {
      ms.duration = double.infinity;
    } catch (e) {
      _log('setting duration=Infinity failed (non-fatal): $e');
    }

    final codec = _pickCodec(init);
    _log('sourceopen: adding source buffer (codec="$codec")');

    web.SourceBuffer sb;
    try {
      sb = ms.addSourceBuffer(codec);
    } catch (e) {
      _log('addSourceBuffer FAILED for $codec: $e — trying fallback');
      // Fallback is the pipeline's canonical baseline codec, NOT the
      // 42E01E high-profile that used to live here. High-profile was
      // never emitted by our worker — an avcC-parse failure fallback
      // to 42E01E silently broke playback (2026-07-07 outage class).
      // Source of truth: c:\Dev\twai-protocol\schema\constants.json.
      sb = ms.addSourceBuffer(kMseCodecs);
    }
    // 'sequence' mode tells the SourceBuffer to ignore timestamps in
    // the moof boxes and append fragments back-to-back in feed order.
    // Safer for a live feed where per-turn timestamp resets could
    // otherwise cause Chrome to skip large stretches of the timeline.
    try {
      sb.mode = 'sequence';
    } catch (e) {
      _log('setting mode=sequence failed (non-fatal): $e');
    }
    _sourceBuffer = sb;
    sb.addEventListener('updateend', _onUpdateEnd.toJS);
    sb.addEventListener('error', _onSourceBufferError.toJS);

    _safeAppend(init);
  }

  void _onSourceEnded(web.Event _) {
    _log('sourceended');
  }

  void _onSourceClose(web.Event _) {
    _log('sourceclose');
  }

  void _onUpdateEnd(web.Event _) {
    _flushAppendQueue();
  }

  void _onSourceBufferError(web.Event _) {
    _log('source buffer error event');
  }

  void _flushAppendQueue() {
    final sb = _sourceBuffer;
    if (sb == null) return;
    if (sb.updating) return;
    if (_appendQueue.isEmpty) return;
    final next = _appendQueue.removeAt(0);
    _safeAppend(next);
  }

  void _safeAppend(Uint8List bytes) {
    final sb = _sourceBuffer;
    if (sb == null) return;
    try {
      sb.appendBuffer(bytes.toJS);
    } catch (e) {
      _log('appendBuffer FAILED (${bytes.length}B): $e');
    }
  }

  // Parses the `avcC` box from the fMP4 init segment to derive the
  // exact codec string Chrome will accept. Falls back to baseline 3.0
  // if the box can't be found.
  String _pickCodec(Uint8List init) {
    // 'a','v','c','C' = 0x61, 0x76, 0x63, 0x43.
    for (var i = 0; i < init.length - 12; i++) {
      if (init[i] == 0x61 &&
          init[i + 1] == 0x76 &&
          init[i + 2] == 0x63 &&
          init[i + 3] == 0x43) {
        // After the 4-byte type comes:
        //   configurationVersion (1B)
        //   AVCProfileIndication (1B)
        //   profile_compatibility (1B)
        //   AVCLevelIndication (1B)
        final pi = init[i + 5];
        final pc = init[i + 6];
        final li = init[i + 7];
        final video = 'avc1.${_hex(pi)}${_hex(pc)}${_hex(li)}';
        // Audio: assume AAC-LC (mp4a.40.2) — the only codec the 2wai
        // pipeline emits per protocol.md content pipeline spec.
        return 'video/mp4; codecs="$video, mp4a.40.2"';
      }
    }
    // avcC parse failed — fall back to the canonical baseline codec
    // the worker actually emits (kMseCodecs = avc1.42C01F baseline
    // + AAC-LC). Was previously 42E01E high-profile, which the
    // worker never emits — silent playback failure. See
    // codec_constants.dart.
    return kMseCodecs;
  }

  String _hex(int b) =>
      b.toRadixString(16).padLeft(2, '0').toUpperCase();

  @override
  Widget buildWidget() => HtmlElementView(viewType: _viewType);

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _bytesSub?.cancel();
    await _speakingSub?.cancel();

    final ms = _mediaSource;
    if (ms != null && ms.readyState == 'open') {
      try {
        ms.endOfStream();
      } catch (_) {
        // Ignore — endOfStream throws if a source buffer is mid-update.
      }
    }
    _mediaSource = null;
    _sourceBuffer = null;
    _appendQueue.clear();

    final url = _objectUrl;
    _objectUrl = null;
    if (url != null) {
      web.URL.revokeObjectURL(url);
    }

    final v = _videoElement;
    if (v != null) {
      v.removeAttribute('src');
      v.load();
    }
    _videoElement = null;
  }
}
