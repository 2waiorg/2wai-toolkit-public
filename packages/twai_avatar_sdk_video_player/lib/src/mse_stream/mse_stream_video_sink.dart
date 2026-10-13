import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:video_player/video_player.dart';

import '../platform/blob_url.dart' as blob;
import 'fmp4_tfdt_rebase.dart';

/// [VideoSink] for Adapter 1 — "accumulate-then-play" strategy with
/// **serial reply queueing**.
///
/// Adapter 1's `videoBytes` stream is a continuous fragmented MP4:
/// one init segment (`ftyp`+`moov`) followed by a never-ending stream
/// of media segments (`moof`+`mdat`), with the server emitting idle
/// frames between speech and real speech frames in between
/// `speaking start`/`stop` events.
///
/// `package:video_player` can't tail-follow a growing file, so this
/// sink doesn't attempt true streaming playback. Instead, it:
///
/// 1. Caches the **first** binary frame (init segment).
/// 2. On `speaking start`, cancels any pending flush timer and enables
///    byte collection. Does **not** seal a prior in-flight turn — see
///    coalescing note below.
/// 3. On `speaking stop`, **schedules** a flush [tailWindow] later
///    (default 2s) — the tail of speech-bearing fragments arrives on
///    the WS 0.5–1.5s after the event itself per `protocol.md` §1b.
///    When the timer fires, the turn is sealed and enqueued.
/// 4. A separate playback loop dequeues sealed turns one at a time:
///    it writes `[init + buffer]` to a temp MP4 (or blob URL on web),
///    creates a fresh [VideoPlayerController], plays it to completion,
///    then advances to the next queued turn.
///
/// **Coalescing sub-cycles into one turn (2026-07-14):**
/// A single user message may produce multiple `speaking:start`/`stop`
/// cycles server-side — e.g. Mason's `#527` sentence_breaks pass
/// inserts a `\n\n` pause between sentences, and each sentence pause
/// on the muse stack fires its own event pair. Earlier logic sealed at
/// every `start` boundary, which produced N sealed MP4s per user turn
/// and played them back-to-back — the user heard the same phrase
/// repeated. The fix: sealing is driven purely by the tail-quiet
/// timer, so any number of sub-cycles that share a run of
/// contiguous speech accumulate into one MP4. A new user turn's
/// content only lands after the [tailWindow] of silence has elapsed
/// (which is when the user's next message would realistically arrive
/// anyway, since the reply text is displayed immediately and the user
/// waits for playback to catch up).
///
/// Earlier versions of this sink replaced the active controller
/// immediately on each `_flushAndPlay`, which meant rapid user input
/// caused replies to drop or get cut off mid-play. The queue ensures
/// every reply plays through fully, in order. If the user genuinely
/// wants to interrupt the avatar mid-speech, that should be a separate
/// explicit API (not implemented in V1).
///
/// **Tradeoff:** loses streaming latency (caller sees the reply text
/// immediately but waits ~2s after `speaking stop` to see video, plus
/// the duration of all in-queue turns ahead of it). A proper
/// MediaSource / WebView-based sink will replace this for real-time
/// playback once we need it.
class VideoPlayerMseStreamSink implements VideoSink {
  VideoPlayerMseStreamSink({
    this.tailWindow = const Duration(milliseconds: 2000),
    this.debugLog = false,
    this.placeholderBuilder,
  });

  /// How long to keep accumulating after `speaking:stop` before sealing
  /// the turn. Default 2 seconds — tuned to comfortably cover the
  /// 0.5–1.5s playback-head lag noted in `protocol.md` §1b.
  final Duration tailWindow;

  /// When true, every byte arrival, speaking event, and queue state
  /// transition is logged with a millisecond timestamp from attach.
  /// Used to diagnose the cold-start ordering between the WS protocol
  /// and the buffer-and-play state machine.
  final bool debugLog;

  /// Widget to render when no [VideoPlayerController] is initialized
  /// yet — i.e. during connect and before the first sealed turn plays.
  ///
  /// Default `null` keeps the historic behavior: a dark ColoredBox
  /// with a "Waiting for first reply…" label — good for SDK smoke
  /// tests, poor for customer UX because it hides any poster/idle
  /// layer the caller wraps behind [buildWidget].
  ///
  /// To let a wrapped poster / idle-loop show through, pass
  /// `placeholderBuilder: (_) => const SizedBox.expand()` — the sink
  /// then renders a transparent, parent-sized box until the first
  /// video frame arrives.
  final WidgetBuilder? placeholderBuilder;

  final _controller = ValueNotifier<VideoPlayerController?>(null);

  // Backing notifier for [isRenderingContent] — flipped true when a
  // sealed MP4 begins playing, false when the poll detects end-of-media
  // (or on dispose). The composition layer (TwaiAvatarPlayerStage)
  // OR-combines this with the speaking-status flag so the sink widget
  // stays visible past speaking:stop while the sealed clip renders.
  final _isRenderingContent = ValueNotifier<bool>(false);
  @override
  ValueListenable<bool> get isRenderingContent => _isRenderingContent;

  StreamSubscription<Uint8List>? _bytesSub;
  StreamSubscription<SpeakingEvent>? _speakingSub;
  StreamSubscription<void>? _speakBoundarySub;
  bool _attached = false;
  bool _disposed = false;
  DateTime? _attachedAt;

  Uint8List? _initSegment;
  // Bytes for the in-flight turn. Sealed (cleared and enqueued) on the
  // next `speaking:start` or when the post-stop tail timer fires.
  final _turnBytes = BytesBuilder(copy: false);
  bool _collecting = false;
  Timer? _flushTimer;
  // Track the wire-timeline PTS of the current turn's speaking bracket
  // so we can stamp an accurate duration into the sealed MP4's moov
  // headers. Without an accurate duration, video_player_android either
  // stops at 1ms (unstamped) or overshoots real content into empty
  // territory (fake 1hr stamp). See _sealAndEnqueue for the math.
  double? _turnFirstStartPts;
  double? _turnLastStopPts;

  String _ts() {
    final t = _attachedAt;
    if (t == null) return '?';
    return '${DateTime.now().difference(t).inMilliseconds.toString().padLeft(5)}ms';
  }

  void _log(String msg) {
    if (!debugLog) return;
    debugPrint('[twai_sink ${_ts()}] $msg');
  }

  // FIFO of sealed turns waiting to play. Each entry holds either a
  // filesystem path (native) or a `blob:` URL (web).
  final _queue = <_QueuedTurn>[];

  // Currently-playing turn — null when idle. The controller is
  // released and the source freed once playback completes and we
  // advance to the next queued turn.
  VideoPlayerController? _activeController;
  String? _activeSource;
  bool _activePlaying = false;

  @override
  Future<void> attach(ChatSession session) async {
    if (_attached) {
      throw StateError('VideoPlayerMseStreamSink.attach called twice');
    }
    _attached = true;
    _attachedAt = DateTime.now();
    _log('attach: subscribing to videoBytes + speakingEvents + speakBoundaries');
    _bytesSub = session.videoBytes.listen(_onBytes);
    _speakingSub = session.speakingEvents.listen(_onSpeaking);
    _speakBoundarySub = session.speakBoundaries.listen(_onSpeakBoundary);
  }

  // Counter model for per-clause sealing when streaming brain drives
  // multiple /speak calls per user turn. The gist: only seal on a
  // speaking:stop if the SDK has told us MORE clauses are coming than
  // we've sealed so far. That way:
  //
  //  - Server-side sub-cycles (Mason's #527 sentence_breaks — one
  //    /speak produces multiple start/stop pairs) coalesce, because
  //    boundariesReceived stays at 1 while stops keep arriving:
  //    `boundariesReceived - sealsDone == 1` at each stop, we wait
  //    for the tail-window.
  //  - Real clause boundaries (streaming brain calls speak() again)
  //    push boundariesReceived to 2. On the next speaking:stop,
  //    `boundariesReceived - sealsDone == 2` → seal now.
  //  - The last clause's stop has `boundariesReceived - sealsDone == 1`
  //    → falls through to the tail-window fallback (existing behavior).
  //
  // Boundaries can arrive BEFORE their corresponding /speak's wire
  // bytes even start (the brain SSE can produce all clauses faster
  // than the WS delivers audio for the first). We bank them here so
  // the check on speaking:stop has the right count.
  int _boundariesReceived = 0;
  int _sealsDone = 0;

  void _onSpeakBoundary(void _) {
    _boundariesReceived++;
    debugPrint(
      'VideoPlayerMseStreamSink: speakBoundary '
      '(bR=$_boundariesReceived, sD=$_sealsDone, '
      'flushTimer=${_flushTimer == null ? "null" : "pending"}, '
      'bufBytes=${_turnBytes.length})',
    );
    _maybeSealForNextClause();
  }

  /// Called on both boundary receipt and speaking:stop. If the SDK has
  /// told us about more /speak calls than we've sealed AND we have a
  /// pending tail timer, seal now — a real clause boundary is imminent
  /// (or already recorded), so waiting the full tail window would just
  /// coalesce this clause with the next.
  ///
  /// The `> 1` gate is important: we need to know at least ONE next
  /// clause is queued (not just this one). Sub-cycles within a single
  /// /speak keep the difference at 1 and correctly fall through to the
  /// tail-window fallback for coalescing.
  void _maybeSealForNextClause() {
    if (_flushTimer == null) return;
    if (_boundariesReceived - _sealsDone <= 1) return;
    debugPrint(
      'VideoPlayerMseStreamSink: maybeSeal FIRING '
      '(bR=$_boundariesReceived, sD=$_sealsDone → ${_sealsDone + 1})',
    );
    _flushTimer!.cancel();
    _flushTimer = null;
    _collecting = false;
    _sealCurrentTurn();
    _sealsDone++;
  }

  void _onBytes(Uint8List bytes) {
    if (_initSegment == null) {
      _log('bytes: ${bytes.length}B — cached as init segment');
      _initSegment = bytes;
      return;
    }
    if (_collecting) {
      _turnBytes.add(bytes);
      _log('bytes: ${bytes.length}B — collected (turn buffer=${_turnBytes.length}B)');
    } else {
      _log('bytes: ${bytes.length}B — DROPPED (not collecting)');
    }
  }

  void _onSpeaking(SpeakingEvent ev) {
    _log('speaking ${ev.value.name} pts=${ev.pts?.toStringAsFixed(2) ?? 'n/a'} '
        '(collecting was $_collecting, turn buffer=${_turnBytes.length}B)');
    switch (ev.value) {
      case SpeakingState.start:
        // NOTE (coalescing fix 2026-07-14): do NOT seal on start. Multi-
        // sentence replies emit start/stop per sentence (Mason's #527
        // sentence_breaks + muse substrate rotation). Sealing on every
        // start produced one MP4 per sub-cycle, which video_player played
        // sequentially and the user heard as repeat playback of the same
        // phrase. Now: keep accumulating; the tail-window timer is the
        // sole sealing edge.
        debugPrint(
          'VideoPlayerMseStreamSink: speaking:start '
          '(bR=$_boundariesReceived, sD=$_sealsDone, '
          'flushTimer=${_flushTimer == null ? "null" : "cancelling"}, '
          'bufBytes=${_turnBytes.length})',
        );
        _flushTimer?.cancel();
        _flushTimer = null;
        _collecting = true;
        // Record the first start of the current turn so we can compute
        // real content duration at seal. Sub-cycles' starts within one
        // turn keep the original first-start reference.
        _turnFirstStartPts ??= ev.pts;
      case SpeakingState.stop:
        // Latest stop wins — sub-cycles update this until the turn seals.
        if (ev.pts != null) _turnLastStopPts = ev.pts;
        _flushTimer?.cancel();
        _flushTimer = Timer(tailWindow, () {
          if (_disposed) return;
          debugPrint(
            'VideoPlayerMseStreamSink: tail-timer FIRED '
            '(bR=$_boundariesReceived, sD=$_sealsDone → ${_sealsDone + 1}, '
            'bufBytes=${_turnBytes.length})',
          );
          _collecting = false;
          _sealCurrentTurn();
          _sealsDone++;
        });
        debugPrint(
          'VideoPlayerMseStreamSink: speaking:stop → tail timer scheduled '
          '(bR=$_boundariesReceived, sD=$_sealsDone, bufBytes=${_turnBytes.length})',
        );
        // Streaming brain may have already queued the next clause's
        // boundary before this stop arrived. If so, seal now instead of
        // waiting the tail window.
        _maybeSealForNextClause();
    }
  }

  void _sealCurrentTurn() {
    final media = _turnBytes.takeBytes();
    if (media.isEmpty) return;
    // Derive real content duration from the speaking bracket PTS pair
    // captured during collection. Fallback: 30s if PTS is missing
    // (shouldn't happen for a normal turn, but keeps sealing robust).
    final first = _turnFirstStartPts;
    final last = _turnLastStopPts;
    final Duration realDuration;
    if (first != null && last != null && last > first) {
      // Add the tailWindow to cover fragments that arrive after
      // speaking:stop (0.5-1.5s per protocol.md §1b) plus a second of
      // slop so the player doesn't stop before the last frame decodes.
      final seconds = (last - first) + tailWindow.inSeconds + 1;
      realDuration = Duration(milliseconds: (seconds * 1000).round());
    } else {
      realDuration = const Duration(seconds: 30);
    }
    // Reset for the next turn so state doesn't leak forward.
    _turnFirstStartPts = null;
    _turnLastStopPts = null;
    // ignore: discarded_futures
    _sealAndEnqueue(media, realDuration);
  }

  Future<void> _sealAndEnqueue(Uint8List media, Duration realDuration) async {
    final init = _initSegment;
    if (init == null) return;
    // Rebase per-track tfdt to 0 before concatenating with the init
    // segment. The wire fragments carry absolute wire-timeline tfdt
    // (monotonic across the whole session); splicing `init + slice`
    // into a standalone MP4 without rebasing leaves the container
    // with `start_time=<absolute>, duration=<absolute-end>` which
    // makes video_player / video_player_android compute
    // `value.duration = 1ms` and drop playback immediately.
    //
    // The 2026-07-14 ffmpeg-remux fix (`-reset_timestamps 1`) handled
    // this on Windows but ffmpeg isn't on Android's PATH. This pure-
    // Dart rewrite works everywhere, no dependency. See
    // fmp4_tfdt_rebase.dart for the box-tree walker.
    rebaseFmp4Tfdt(media);
    // Copy the cached init segment before stamping — the original stays
    // pristine so subsequent seals (and any late-mounted sinks that
    // prepend it) get a clean init to rewrite themselves.
    final stampedInit = Uint8List.fromList(init);
    // Use ceil() so we never under-stamp (which would make player stop
    // one second short of real content end).
    final stampSeconds =
        (realDuration.inMilliseconds / 1000).ceil().clamp(1, 3600);
    stampFmp4InitDurations(stampedInit, fakeSeconds: stampSeconds);
    debugPrint(
      'VideoPlayerMseStreamSink: tfdt rebased + init duration stamped '
      '(${media.length} bytes media, ${stampedInit.length} bytes init, '
      'realDuration=${realDuration.inMilliseconds}ms → stamp=${stampSeconds}s)',
    );
    final allBytes = (BytesBuilder(copy: false)
          ..add(stampedInit)
          ..add(media))
        .takeBytes();

    final String source;
    if (kIsWeb) {
      source = blob.createObjectUrl(allBytes);
    } else {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().microsecondsSinceEpoch;
      final path = '${dir.path}/twai_mse_$ts.mp4';
      await File(path).writeAsBytes(allBytes, flush: true);
      source = path;
    }

    if (_disposed) {
      _disposeSource(source);
      return;
    }

    _queue.add(_QueuedTurn(source: source, byteLen: allBytes.length));
    debugPrint(
      'VideoPlayerMseStreamSink: enqueued turn '
      '(${allBytes.length} bytes, queue depth=${_queue.length})',
    );
    // ignore: discarded_futures
    _advanceQueue();
  }

  Future<void> _advanceQueue() async {
    if (_activePlaying) return;
    if (_queue.isEmpty) return;
    if (_disposed) return;
    _activePlaying = true;

    final turn = _queue.removeAt(0);
    final source = turn.source;
    final fresh = kIsWeb
        ? VideoPlayerController.networkUrl(Uri.parse(source))
        : VideoPlayerController.file(File(source));

    try {
      await fresh.initialize();
    } catch (e, st) {
      // Decode failed — drop this turn, advance to the next.
      debugPrint(
        'VideoPlayerMseStreamSink: initialize() failed for $source.\n'
        '  Bytes: ${turn.byteLen}\n'
        '  Error: $e\n  Stack: $st',
      );
      await fresh.dispose();
      _disposeSource(source);
      _activePlaying = false;
      // ignore: discarded_futures
      _advanceQueue();
      return;
    }

    // Explicit non-loop: Android's video_player defaults to non-looping
    // but video_player_win on Windows defaults to loop, so without this
    // the avatar replays each turn forever. Each queued turn is a
    // complete MP4 that should play once and stop on the last frame.
    await fresh.setLooping(false);

    // Swap in the new controller and release the previous one (its
    // playback already completed — we only get here when _activePlaying
    // went false).
    final oldController = _activeController;
    final oldSource = _activeSource;
    _activeController = fresh;
    _activeSource = source;
    _controller.value = fresh;
    _isRenderingContent.value = true;
    await fresh.play();
    await oldController?.dispose();
    _disposeSource(oldSource);

    debugPrint(
      'VideoPlayerMseStreamSink: playing $source '
      '(${turn.byteLen} bytes, '
      'aspectRatio=${fresh.value.aspectRatio.toStringAsFixed(3)}, '
      'duration=${fresh.value.duration.inMilliseconds}ms, '
      'queue remaining=${_queue.length})',
    );

    // Watch for end-of-play. The naive approach — `fresh.value.isCompleted`
    // — is unreliable on Android because `video_player_android` reads
    // fragmented-MP4 durations from `mdhd.duration` which is always 0 in
    // an fMP4 init segment. It reports `value.duration = 1ms` for a
    // real 22-second clip, then fires `isCompleted` ~immediately even
    // though decoded frames are still arriving. That causes the sink
    // to hand the render slot back to the placeholder before any frame
    // renders — user sees only idle.
    //
    // Instead: poll `value.position` periodically and treat "position
    // hasn't advanced for [advanceQuietWindow]" as the real end-of-media
    // signal. Works for any player + any container regardless of what
    // it reports for `duration`.
    Duration lastPos = fresh.value.position;
    DateTime lastMoveAt = DateTime.now();
    const advanceQuietWindow = Duration(milliseconds: 800);
    const pollInterval = Duration(milliseconds: 200);
    late Timer poll;
    void finish() {
      if (_disposed) return;
      if (_activeController != fresh) return;
      poll.cancel();
      _activePlaying = false;
      // Idle↔conversation state-machine edge (2026-07-16): when this
      // was the last queued turn, hand the render slot back to the
      // placeholder — the customer's idle content (poster / looping
      // idle video / anything via `placeholderBuilder`) takes back
      // over. Without this the Video widget stayed frozen on the
      // turn's last frame between turns, breaking the
      // idle→conversation→idle cycle. See `TwaiAvatarStage` for the
      // customer-facing wrapper that composes this with an
      // `AvatarIdleSource`.
      if (_queue.isEmpty) {
        _controller.value = null;
        _isRenderingContent.value = false;
      }
      // ignore: discarded_futures
      _advanceQueue();
    }

    int tick = 0;
    poll = Timer.periodic(pollInterval, (_) {
      if (_disposed || _activeController != fresh) {
        poll.cancel();
        return;
      }
      final pos = fresh.value.position;
      final now = DateTime.now();
      tick++;
      // Print every 5th tick (~1s) so log doesn't drown but we see progress.
      if (tick % 5 == 0) {
        debugPrint(
          'VideoPlayerMseStreamSink: poll tick=$tick pos=${pos.inMilliseconds}ms '
          'lastPos=${lastPos.inMilliseconds}ms isPlaying=${fresh.value.isPlaying} '
          'isBuffering=${fresh.value.isBuffering} '
          'hasError=${fresh.value.hasError}',
        );
      }
      if (pos != lastPos) {
        lastPos = pos;
        lastMoveAt = now;
        return;
      }
      // Position hasn't advanced. If the quiet window has elapsed AND
      // the video has actually started playing (pos > 0 OR pos == 0 for
      // 3s after start — clip never started because it's empty), treat
      // as end-of-media.
      final quietFor = now.difference(lastMoveAt);
      if (pos > Duration.zero && quietFor >= advanceQuietWindow) {
        debugPrint(
          'VideoPlayerMseStreamSink: end-of-play detected (quiet for '
          '${quietFor.inMilliseconds}ms at pos=${pos.inMilliseconds}ms)',
        );
        finish();
      } else if (pos == Duration.zero && quietFor >= const Duration(seconds: 3)) {
        debugPrint(
          'VideoPlayerMseStreamSink: never started (pos=0 for 3s) — dropping',
        );
        finish();
      }
    });
  }

  /// Release a previously-active source. On native, deletes the temp
  /// MP4 file (fire-and-forget). On web, revokes the blob URL so the
  /// browser frees the in-memory bytes.
  void _disposeSource(String? source) {
    if (source == null) return;
    if (kIsWeb) {
      blob.revokeObjectUrl(source);
    } else {
      // ignore: unawaited_futures
      File(source).delete().catchError((_) => File(source));
    }
  }

  @override
  Widget buildWidget() => _MseVideoView(
        controller: _controller,
        placeholderBuilder: placeholderBuilder,
      );

  @override
  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _bytesSub?.cancel();
    await _speakingSub?.cancel();
    await _speakBoundarySub?.cancel();

    // Drain anything still in the queue without playing it.
    for (final turn in _queue) {
      _disposeSource(turn.source);
    }
    _queue.clear();

    final activeController = _activeController;
    final activeSource = _activeSource;
    _activeController = null;
    _activeSource = null;
    _controller.value = null;
    await activeController?.dispose();
    _disposeSource(activeSource);
    _controller.dispose();
    _isRenderingContent.value = false;
    _isRenderingContent.dispose();
  }
}

class _QueuedTurn {
  _QueuedTurn({required this.source, required this.byteLen});
  final String source;
  final int byteLen;
}

class _MseVideoView extends StatelessWidget {
  const _MseVideoView({
    required this.controller,
    this.placeholderBuilder,
  });

  final ValueListenable<VideoPlayerController?> controller;
  final WidgetBuilder? placeholderBuilder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: controller,
      builder: (context, c, _) {
        if (c == null || !c.value.isInitialized) {
          // Caller-supplied placeholder wins — usually a transparent
          // SizedBox.expand so a poster / idle-loop wrapped behind the
          // sink can show through.
          final builder = placeholderBuilder;
          if (builder != null) return builder(context);
          // New default (2026-07-16): transparent — see
          // MediaKitMseStreamSink for rationale. Old opaque
          // "Waiting for first reply…" box hid idle content that
          // customers wrapped behind the sink via `TwaiAvatarStage`.
          return const SizedBox.expand();
        }
        // BoxFit.contain — full avatar visible even in wide panes
        // (letterboxes side bars). Cover was tried 2026-07-16 to
        // match the idle source but cropped avatars' faces off when
        // the pane was landscape-oriented; contain everywhere is the
        // safer default. Pairs with `AvatarIdleSource`'s `contain`
        // default so idle and talking states show the avatar at the
        // same size.
        return ColoredBox(
          color: const Color(0xFF000000),
          child: Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
        );
      },
    );
  }
}
