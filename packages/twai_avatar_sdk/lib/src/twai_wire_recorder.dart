// TwaiWireRecorder — Flutter port of Mason's `?review=1` wire capture
// from c:/Dev/avatar-player/src/main.ts.
//
// Subscribes to a handle's `videoBytes` stream (fMP4 fragments coming
// off the WS), buffers them in memory, and exposes counters + the
// concatenated bytes for save/scrub/replay.
//
// Design principle: bit-exact fMP4 dump. The bytes buffered here are
// the exact bytes the SDK's sink receives from the wire — so artifacts
// round-trip cleanly through Mason's twai-api/scripts/ CLI (fMP4 box
// parser + report generator). No transformation, no re-muxing.
//
// Consumer usage:
//   final recorder = TwaiWireRecorder();
//   recorder.start(handle.videoBytes);
//   // ... let it record ...
//   recorder.stop();
//   final bytes = recorder.getBytes();  // → save to file, feed a video element, etc.
//   recorder.clear();

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Where the recorder is in its lifecycle.
enum WireRecorderState {
  /// No source ever started, or was fully cleared. Buffer empty.
  idle,

  /// Subscribed to a source and actively appending each fragment.
  recording,

  /// Subscription closed. Buffer retained until [clear] or another
  /// [start] call.
  stopped,
}

/// One captured fragment — a single `Uint8List` from the source stream.
/// The panel uses these to render a per-fragment timeline. The controller
/// keeps this list in-memory alongside the concatenated buffer so counters
/// stay cheap.
class WireFragment {
  final DateTime at;
  final int byteLength;
  const WireFragment({required this.at, required this.byteLength});
}

/// The recorder. Not a singleton — each instance owns one recording
/// session. Notifies listeners on every fragment append, state change,
/// or clear so widgets can render byte counts + duration reactively.
class TwaiWireRecorder extends ChangeNotifier {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final List<WireFragment> _fragments = [];
  StreamSubscription<Uint8List>? _sub;
  WireRecorderState _state = WireRecorderState.idle;
  DateTime? _startedAt;
  DateTime? _stoppedAt;

  WireRecorderState get state => _state;

  /// Total bytes buffered.
  int get bytesCount => _buffer.length;

  /// Total fragments appended across the current recording (or the last
  /// stopped one, until [clear]).
  int get fragmentCount => _fragments.length;

  /// Per-fragment metadata list — cheap read-only view for panels.
  List<WireFragment> get fragments => List.unmodifiable(_fragments);

  /// Wall-clock duration from [start] to now (while recording) or to
  /// [stop] (once stopped). [Duration.zero] before the first start.
  Duration get elapsed {
    final started = _startedAt;
    if (started == null) return Duration.zero;
    final end = _stoppedAt ?? DateTime.now();
    return end.difference(started);
  }

  /// Subscribe to [source] and start buffering. If already recording,
  /// stops the previous subscription and (unless [replace] is false)
  /// clears the buffer first.
  ///
  /// The recorder does not manage the lifetime of the source stream —
  /// caller is responsible for the underlying handle.
  void start(Stream<Uint8List> source, {bool replace = true}) {
    if (_sub != null) {
      _sub!.cancel();
      _sub = null;
    }
    if (replace) {
      _buffer.clear();
      _fragments.clear();
    }
    _startedAt = DateTime.now();
    _stoppedAt = null;
    _state = WireRecorderState.recording;
    _sub = source.listen(
      _onFragment,
      onError: (Object e, StackTrace st) {
        debugPrint('TwaiWireRecorder: source error $e');
      },
      onDone: _onSourceDone,
      cancelOnError: false,
    );
    notifyListeners();
  }

  /// Stop the recording. Retains the buffer for save / scrub. Idempotent.
  void stop() {
    if (_state != WireRecorderState.recording) return;
    _sub?.cancel();
    _sub = null;
    _stoppedAt = DateTime.now();
    _state = WireRecorderState.stopped;
    notifyListeners();
  }

  /// Drop the buffer + fragments + timestamps. Does NOT stop an active
  /// recording — call [stop] first if you want to end capture.
  void clear() {
    _buffer.clear();
    _fragments.clear();
    _startedAt = _state == WireRecorderState.recording ? DateTime.now() : null;
    _stoppedAt = null;
    if (_state == WireRecorderState.stopped) {
      _state = WireRecorderState.idle;
    }
    notifyListeners();
  }

  /// Snapshot of the concatenated buffer. Safe to call while recording —
  /// returns bytes captured up to this moment.
  Uint8List getBytes() => _buffer.toBytes();

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  void _onFragment(Uint8List frag) {
    if (_state != WireRecorderState.recording) return;
    _buffer.add(frag);
    _fragments.add(WireFragment(
      at: DateTime.now(),
      byteLength: frag.length,
    ));
    notifyListeners();
  }

  void _onSourceDone() {
    // Source closed — treat like stop() so the panel reflects it.
    if (_state == WireRecorderState.recording) {
      _stoppedAt = DateTime.now();
      _state = WireRecorderState.stopped;
      notifyListeners();
    }
  }
}
