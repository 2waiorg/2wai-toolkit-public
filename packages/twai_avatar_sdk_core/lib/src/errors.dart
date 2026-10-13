/// Typed error ladder shared across the whole SDK — the Flutter
/// counterpart to `twai-web-sdk`'s `TwaiError` hierarchy. Consumers
/// switch on [TwaiError.kind] to write once cross-language error
/// handlers.
///
/// # Why an interface (not another sealed base class)
///
/// The SDK already ships fine-grained exception hierarchies per
/// method — `ChatSessionException`, `ChatGatewayException`,
/// `PipelineV13Exception`, `AvatarAdminException`,
/// `GenApiException` — each with detailed subclasses. Reworking
/// them into one class tree would break every consumer catching a
/// specific type today.
///
/// Instead: [TwaiError] is a *marker interface* the existing
/// exception hierarchies implement. `catch (TwaiError e) switch (e.kind)`
/// works uniformly across all of them; existing `catch
/// (ChatSessionSendException e)` code keeps working.
///
/// Three new concrete exceptions land here for full web-SDK parity —
/// pipeline transport surfaces that didn't have a Flutter equivalent:
///
/// - [TwaiCodecError] — the platform can't decode the pipeline codec
///   (iOS Safari + plain `MediaSource`, misconfigured Windows sink).
/// - [TwaiHandshakeError] — the WS server rejected the handshake
///   frame or the client didn't send one in time (close 1002/1011).
/// - [TwaiTransportError] — mid-stream transport failure
///   (`appendBuffer` failure, WS error mid-flight, unexpected close).
abstract interface class TwaiError {
  TwaiErrorKind get kind;
  String get message;
  Object? get cause;
}

/// The discriminator on [TwaiError.kind]. Matches the string values
/// in `twai-web-sdk`'s `TwaiErrorKind` so logs read the same across
/// languages.
enum TwaiErrorKind {
  /// Platform can't play the pipeline's codec.
  codec,

  /// WS or MediaSource failed to open (network unreachable, DNS,
  /// TLS, or MediaSource unsupported).
  connect,

  /// Server rejected the handshake frame, or the client didn't send
  /// one in the handshake window. WS close 1002 (protocol error) or
  /// 1011 (server internal), or a timeout.
  handshake,

  /// Mid-stream transport failure — `appendBuffer` threw, WS error
  /// mid-flight, unexpected close.
  transport,

  /// `POST /ext-api/human` or equivalent chat send failed
  /// (network error, non-2xx status, backend rejection).
  chat,

  /// Missing / invalid credential (401 / 403). Retrying with the
  /// same credential won't help; the caller must rotate.
  unauthorized,

  /// Anything that doesn't fit the above — caller misuse, unknown
  /// server state, etc.
  unknown,
}

/// Platform can't play the pipeline codec. Common causes:
/// - iOS Safari 17.1+ with plain `MediaSource` (needs
///   `ManagedMediaSource`).
/// - Browser that returns `false` from `isTypeSupported` for the
///   avc1.42C01F baseline codec.
/// - Windows sink misconfigured (video_player_win vs media_kit).
class TwaiCodecError implements Exception, TwaiError {
  const TwaiCodecError(this.message, [this.cause]);

  @override
  final String message;
  @override
  final Object? cause;
  @override
  TwaiErrorKind get kind => TwaiErrorKind.codec;

  @override
  String toString() =>
      cause == null ? 'TwaiCodecError: $message' : 'TwaiCodecError: $message ($cause)';
}

/// Server rejected the WS handshake, or the client didn't send one
/// in the handshake window. Carries the close code when known so
/// consumers can distinguish 1002 (client sent bad frame) from 1011
/// (server internal error).
class TwaiHandshakeError implements Exception, TwaiError {
  const TwaiHandshakeError(this.message, {this.closeCode, this.cause});

  @override
  final String message;
  @override
  final Object? cause;
  final int? closeCode;
  @override
  TwaiErrorKind get kind => TwaiErrorKind.handshake;

  @override
  String toString() {
    final code = closeCode == null ? '' : ' (close=$closeCode)';
    return cause == null
        ? 'TwaiHandshakeError: $message$code'
        : 'TwaiHandshakeError: $message$code (cause: $cause)';
  }
}

/// Mid-stream transport failure — the stream was healthy but broke.
/// `appendBuffer` threw, WS errored mid-flight, or the connection
/// closed unexpectedly without a clean shutdown.
class TwaiTransportError implements Exception, TwaiError {
  const TwaiTransportError(this.message, [this.cause]);

  @override
  final String message;
  @override
  final Object? cause;
  @override
  TwaiErrorKind get kind => TwaiErrorKind.transport;

  @override
  String toString() => cause == null
      ? 'TwaiTransportError: $message'
      : 'TwaiTransportError: $message ($cause)';
}
