/// The four visible states of the avatar player. Directly maps to the
/// reference controller's `Status` type + drives the pill UI in the
/// production player.
///
/// See port spec §2.1 for the state-machine diagram and transitions.
///
/// **Transitions (single-flight, gated by [TwaiAvatarPlayerController]):**
///
/// ```
/// [initial] ─connect──► connecting
///                          │
///                          │  sourceopen + WS open + first frame
///                          ▼
///                        ready ◄─────────┐
///                          │             │
///                          │ send        │ {speaking:stop}
///                          ▼             │
///                        speaking ───────┘
///                          │
///                          │ WS close / silence >WS_SILENCE / watchdog
///                          ▼
///                        failed ─scheduleReconnect─► connecting
/// ```
///
/// The `failed` state is not terminal — it's the "we hit an error and
/// have a reconnect in flight" state. Only after `maxReconnectAttempts`
/// backoff-then-retry cycles does the player surface the gesture-backed
/// "tap to reconnect" overlay, at which point [PlayerStatus.failed]
/// still holds but no automatic recovery is pending.
enum PlayerStatus {
  /// Initial state + every reconnect attempt. Composer disabled.
  connecting,

  /// Session is live and idle. Composer enabled. Idle video showing.
  ready,

  /// Avatar is delivering a reply. Composer disabled during speech
  /// (mirrors the reference; user cannot interrupt mid-speech).
  speaking,

  /// Session terminated (transient or permanent). A reconnect is
  /// either in flight or awaiting a user tap (after
  /// [PlayerConfig.maxReconnectAttempts]).
  failed,
}

/// Terminal disposition for a session that ended. Emitted on the
/// [TwaiAvatarPlayerController.done] future.
sealed class PlayerEndReason {
  const PlayerEndReason(this.message);
  final String message;

  /// Should the caller expect the player to attempt reconnecting on
  /// its own, or has automatic recovery been exhausted?
  bool get autoRecoveryInFlight;

  @override
  String toString() => '$runtimeType($message)';
}

/// The caller called [TwaiAvatarPlayerController.dispose] — expected
/// end of session, no recovery.
class PlayerDisposed extends PlayerEndReason {
  const PlayerDisposed([super.message = 'disposed']);
  @override
  bool get autoRecoveryInFlight => false;
}

/// The remote closed cleanly (WS close code 1000). Player may still
/// attempt reconnect depending on lifecycle context.
class PlayerRemoteClosed extends PlayerEndReason {
  const PlayerRemoteClosed([super.message = 'remote closed']);
  @override
  bool get autoRecoveryInFlight => true;
}

/// Transport failed but automatic reconnect is still in flight
/// (attempts < [PlayerConfig.maxReconnectAttempts]).
class PlayerTransientFailure extends PlayerEndReason {
  const PlayerTransientFailure(super.message, {this.cause});
  final Object? cause;
  @override
  bool get autoRecoveryInFlight => true;
}

/// Automatic reconnect attempts exhausted. Player is now waiting for
/// the user to tap the "reconnect" gesture overlay (see reference
/// controller.ts:993 + port spec §2.3).
class PlayerExhausted extends PlayerEndReason {
  const PlayerExhausted([super.message = 'auto-recovery exhausted']);
  @override
  bool get autoRecoveryInFlight => false;
}

/// Snapshot event emitted every time the player's status changes.
/// Consumers use these on the [TwaiAvatarPlayerController.status]
/// broadcast stream to drive UI + telemetry without pulling.
class PlayerStatusEvent {
  const PlayerStatusEvent({
    required this.status,
    required this.attempt,
    this.reconnectDelay,
    this.cause,
  });

  /// Current player status.
  final PlayerStatus status;

  /// Reconnect attempt number this event was emitted under (0 for the
  /// initial connect; 1..[PlayerConfig.maxReconnectAttempts] for
  /// retries).
  final int attempt;

  /// When [status] is [PlayerStatus.connecting] as part of a backoff
  /// retry, the delay we're waiting through before firing the next
  /// connect. Null on the initial connect or steady-state transitions.
  final Duration? reconnectDelay;

  /// Cause of the last transition into [PlayerStatus.failed], if any.
  /// Cleared on next `ready` transition.
  final Object? cause;

  @override
  String toString() {
    final parts = <String>[
      status.name,
      'attempt=$attempt',
      if (reconnectDelay != null) 'delay=${reconnectDelay!.inMilliseconds}ms',
      if (cause != null) 'cause=$cause',
    ];
    return 'PlayerStatusEvent(${parts.join(", ")})';
  }
}
