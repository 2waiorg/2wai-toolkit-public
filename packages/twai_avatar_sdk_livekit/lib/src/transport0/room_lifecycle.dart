/// Host-side room-lifecycle policy — Dart port of
/// `packages/core/src/roomLifecycle.ts`, itself ported verbatim from PP
/// (`clg_pp_payment frontend/src/lean/livekit_lifecycle.ts`,
/// origin/staging).
///
/// This is a **helper, not engine behaviour**. Per spec §10 the engine
/// performs no retries of any kind: `LiveKitEngine.connect()`
/// classifies a terminal ending, emits `ended {cause}`, and stops.
/// Retry, backoff, and reconnect policy is host code, so a policy bug
/// is fixed in one host without a package release and the server-side
/// guards see honest client behaviour. This class is the policy PP
/// settled on after an auto-reconnecting client opened 864 sessions in
/// 48 hours; it is offered to hosts, never run on their behalf.
///
/// Hosts drive it from their own `onEnded` handlers: feed the cause to
/// [noteTerminalFailure] and obey the returned [LiveKitTerminalAction],
/// take the old room down through [release] and await
/// [waitForDisconnect] before minting a replacement, and call
/// [noteRendererReady] once the new room actually renders so the retry
/// episode resets.
///
/// **Wiring contract, in the order it bites:**
///
///   - [install] FIRST, or the class is silently inert: every method
///     is owner-gated, so [release] no-ops and [noteRendererReady]
///     returns false.
///   - `release(s, () => s.disconnect())` composes with the engine
///     because the engine's `disconnect()` on an ALREADY-CLOSED
///     session awaits its in-flight disconnect instead of returning
///     early. That is what makes the barrier gate on real teardown
///     after an `ended`, rather than on a no-op that resolves
///     instantly.
///   - `rateLimited` never arrives on `ended`, which carries only
///     `agent-ended` / `transport-ended`. It comes from catching
///     [MintRateLimited] thrown by `connect()` — engine
///     `mint-rate-limited` → this class's `rateLimited`. The
///     countdown is yours to hold; `retryAfterSeconds` is not stored
///     here.
///   - [beginExplicitEpisode] is the way out of `blocked` /
///     `awaitUser`. Call it from a real user gesture.
///   - **Admission control only**: a counter and a latch, no backoff
///     and no timers. Pacing a retry is host code.
library;

enum LiveKitTerminalCause { agentEnded, transportEnded, rateLimited }

enum LiveKitTerminalAction { retry, awaitUser, blocked }

/// Pure room-ownership and retry state for one client chat mount.
///
/// LiveKit handles transient signaling recovery inside a room. This
/// class owns only terminal fresh-room replacement, where strict
/// disconnect ordering and a bounded retry episode protect the shared
/// participant-minute budget.
class LiveKitRoomLifecycle<Owner extends Object> {
  Owner? _owner;
  Future<void> _disconnectBarrier = Future.value();
  int _attempts = 0;
  bool _rateLimited = false;
  final int maxAutomaticRetries;

  LiveKitRoomLifecycle({this.maxAutomaticRetries = 3});

  int get automaticAttempts => _attempts;
  bool get isRateLimited => _rateLimited;

  void install(Owner owner) {
    _owner = owner;
  }

  bool isCurrent(Owner owner) => identical(_owner, owner);

  Future<void> waitForDisconnect() => _disconnectBarrier;

  Future<void> release(Owner owner, Future<void> Function() disconnect) {
    if (!identical(_owner, owner)) return _disconnectBarrier;
    _owner = null;
    // Await the barrier (swallowing its error), then run the caller's
    // disconnect. That composed future becomes the new barrier for the
    // NEXT release — so multiple in-flight tear-downs serialise in the
    // order they were requested rather than racing each other.
    final Future<void> closing =
        _disconnectBarrier.catchError((_) {}).then((_) => disconnect());
    _disconnectBarrier = closing.catchError((_) {});
    return closing;
  }

  void beginExplicitEpisode() {
    _attempts = 0;
    _rateLimited = false;
  }

  bool noteRendererReady(Owner owner) {
    if (!identical(_owner, owner)) return false;
    _attempts = 0;
    _rateLimited = false;
    return true;
  }

  LiveKitTerminalAction noteTerminalFailure(LiveKitTerminalCause cause) {
    if (cause == LiveKitTerminalCause.agentEnded) {
      return LiveKitTerminalAction.awaitUser;
    }
    if (cause == LiveKitTerminalCause.rateLimited) {
      _rateLimited = true;
      return LiveKitTerminalAction.blocked;
    }
    if (_rateLimited || _attempts >= maxAutomaticRetries) {
      return LiveKitTerminalAction.blocked;
    }
    _attempts += 1;
    return LiveKitTerminalAction.retry;
  }
}
