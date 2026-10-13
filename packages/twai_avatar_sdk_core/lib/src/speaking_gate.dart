/// The pts speaking-gate — the single most bug-prone client behavior,
/// isolated as pure, DOM-free, conformance-tested logic.
///
/// Speaking events arrive over the WS near-instantly, but the player's
/// playback head lags the newest appended fragment by 0.5–1.5s. The
/// idle↔speaking UI transition MUST fire when `playbackTime >= pts`, in
/// event order, NOT on receipt. Legacy workers omit `pts` — a conforming
/// client falls back to firing on the next tick.
///
/// Ported bit-for-bit from `twai-web-sdk/packages/core/src/speakingGate.ts`
/// so both SDKs pass the same conformance vectors
/// (`test/conformance/speaking-timeline.json`, mirror of
/// `twai-web-sdk/conformance/vectors/speaking-timeline.json`).
library;

import 'adapters/mse_stream/mse_stream_config.dart' show SpeakingEvent, SpeakingState;

/// Stateful gate used by the player. Enqueue events as they arrive; call
/// [tick] with the current playback time on every video-position update
/// (and right after enqueue) so any events whose pts the playhead has
/// already reached fire immediately in event order.
///
/// The [onFire] callback is called at most once per queued event. If it
/// throws, the exception is caught and dropped — a consumer callback
/// must not wedge the gate.
class SpeakingGate {
  SpeakingGate({required this.onFire});

  /// Called each time the gate releases a pending event. Value is the
  /// same `start` / `stop` that arrived from the server.
  final void Function(SpeakingState value) onFire;

  final _queue = <_Pending>[];
  int _seq = 0;

  /// Enqueue a fully-parsed [SpeakingEvent]. The event's [SpeakingEvent.pts]
  /// is used as the gate condition; [tick] releases it once
  /// `currentTime >= pts`.
  ///
  /// A null pts (legacy no-pts event, per
  /// twai-protocol `schema/speaking-event.schema.json:16-20`) is
  /// coerced to `-Infinity` so the next [tick] fires it immediately —
  /// matches the pure `gateSpeaking()` reference.
  void enqueueEvent(SpeakingEvent event) {
    _queue.add(_Pending(
      value: event.value,
      pts: event.pts ?? double.negativeInfinity,
      seq: _seq++,
    ));
  }

  /// Lower-level enqueue that accepts a null [pts] for legacy /
  /// conformance-vector parity (pre-2026-05 servers omit pts). A null
  /// pts fires on the next [tick] regardless of `currentTime`.
  void enqueue({required SpeakingState value, double? pts}) {
    _queue.add(_Pending(
      value: value,
      pts: pts ?? double.negativeInfinity,
      seq: _seq++,
    ));
  }

  /// Fire any queued transitions whose pts the playhead has reached, in
  /// enqueue order. Call from a video-position listener AND right after
  /// enqueue.
  void tick(double currentTime) {
    while (_queue.isNotEmpty && _queue.first.pts <= currentTime) {
      final ev = _queue.removeAt(0);
      try {
        onFire(ev.value);
      } catch (_) {
        // A consumer callback must not wedge the gate. Swallow — the
        // caller can log via its own boundary if it needs to.
      }
    }
  }

  /// Drop all pending events (e.g. on session reset / reconnect). The
  /// [_seq] counter also resets so the next event goes to the head.
  void reset() {
    _queue.clear();
    _seq = 0;
  }

  /// Number of events currently waiting for the playhead. Exposed for
  /// diagnostics; the gate manages its own draining.
  int get pending => _queue.length;

  /// Snapshot of pending events as `(value, pts)` records, in enqueue
  /// order. Read-only view; safe to iterate. Consumers that need to
  /// reason about upcoming transitions (e.g. clamping a seek so it
  /// doesn't jump past a queued `speaking:start`) use this. The gate
  /// itself stays the sole owner of the queue.
  Iterable<({SpeakingState value, double pts})> get pendingEvents =>
      _queue.map((e) => (value: e.value, pts: e.pts));
}

class _Pending {
  const _Pending({required this.value, required this.pts, required this.seq});
  final SpeakingState value;
  final double pts;
  final int seq;
}

/// Pure reference form used by the conformance harness. Given [events]
/// (in `seq` order) and a [playback] progression of `currentTime`
/// samples, return the fires that would happen. Identical semantics to
/// [SpeakingGate].
///
/// Each event must be a map with keys:
///   - `value`: `'start'` | `'stop'`
///   - `pts` (optional): number
///   - `seq` (optional): number — used to sort input into a canonical order
///
/// Returned list matches the conformance vector's `expectedFires` shape:
/// `[{'value': 'start'|'stop', 'firedAtCurrentTime': double}, ...]`.
List<Map<String, Object>> gateSpeaking(
  List<Map<String, Object?>> events,
  List<double> playback,
) {
  final sorted = [...events]..sort((a, b) {
      final sa = a['seq'];
      final sb = b['seq'];
      final na = sa is num ? sa.toInt() : 0;
      final nb = sb is num ? sb.toInt() : 0;
      return na.compareTo(nb);
    });
  final queue = List<Map<String, Object?>>.of(sorted);
  final fires = <Map<String, Object>>[];
  for (final currentTime in playback) {
    while (queue.isNotEmpty) {
      final ev = queue.first;
      final ptsRaw = ev['pts'];
      final pts = ptsRaw is num ? ptsRaw.toDouble() : double.negativeInfinity;
      if (pts <= currentTime) {
        fires.add({
          'value': ev['value'] as Object,
          'firedAtCurrentTime': currentTime,
        });
        queue.removeAt(0);
      } else {
        break;
      }
    }
  }
  return fires;
}
