/// Closure outcome for an MSE stream connection. Sealed — pattern-match
/// on the concrete subtype to decide how to surface to the UI.
sealed class MseStreamCloseReason {
  final int code;
  final String reason;
  const MseStreamCloseReason(this.code, this.reason);

  /// Per `docs/protocol.md` §1 "Session teardown": clients should NOT
  /// auto-reconnect on 1002 or 1011 — those are configuration / server
  /// bugs and reconnecting will just fail again.
  bool get canReconnect;

  @override
  String toString() => '$runtimeType(code: $code, reason: "$reason")';
}

/// Normal close (code 1000) — clean session end.
class NormalClose extends MseStreamCloseReason {
  const NormalClose([String reason = '']) : super(1000, reason);
  @override
  bool get canReconnect => true;
}

/// Configuration error (close code 1002). Server sends this when the
/// handshake fails: missing `session_id`, bad JSON, or 15s timeout
/// with no handshake frame.
class ConfigError extends MseStreamCloseReason {
  const ConfigError(String reason) : super(1002, reason);
  @override
  bool get canReconnect => false;
}

/// Server-side error (close code 1011) — codec error, internal failure.
class ServerError extends MseStreamCloseReason {
  const ServerError(String reason) : super(1011, reason);
  @override
  bool get canReconnect => false;
}

/// Auth-related close: the server rejected the handshake's
/// `publishableKey` (either missing, invalid, or out of scope/quota).
///
/// WebSocket has no inherent 401/403, so 2wai pipeline uses three
/// codes here:
///   - 1008 (policy violation) — RFC-standard "key was invalid"
///   - 4401 — custom: invalid / missing publishable key
///   - 4403 — custom: key valid but lacks scope for this avatar
///   - 4429 — custom: key over quota
///
/// All four map to this single class so callers can `is Unauthorized`
/// without enumerating codes. Reconnect attempts won't succeed until
/// the customer fixes the key.
class Unauthorized extends MseStreamCloseReason {
  const Unauthorized(super.code, super.reason);
  @override
  bool get canReconnect => false;
}

/// Any other close code (including transport-level failures with no code).
class OtherClose extends MseStreamCloseReason {
  const OtherClose(super.code, super.reason);
  @override
  bool get canReconnect =>
      code != 1002 && code != 1011 && code != 1008 && code != 4401 &&
      code != 4403 && code != 4429;
}

/// Map a raw WebSocket close (code, reason) pair to the right subtype.
MseStreamCloseReason mseStreamCloseFor(int? code, String? reason) {
  final r = reason ?? '';
  return switch (code) {
    1000 => NormalClose(r),
    1002 => ConfigError(r),
    1008 || 4401 || 4403 || 4429 => Unauthorized(code!, r),
    1011 => ServerError(r),
    _ => OtherClose(code ?? -1, r),
  };
}
