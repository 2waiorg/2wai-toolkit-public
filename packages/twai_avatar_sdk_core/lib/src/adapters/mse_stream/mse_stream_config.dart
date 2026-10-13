import 'dart:convert';
import 'dart:math';

/// twai-protocol version this SDK conforms to. Sent on the handshake
/// (`toJson.protocolVersion`) so a future health-preflight can catch
/// codec-mismatch before we hang at HAVE_METADATA.
///
/// Canonical source: `c:\Dev\twai-protocol\schema\constants.json`
/// (also `twai-protocol/VERSION`, though those two drift today —
/// pinged Mason 2026-07-28). Bump when we adopt a new upstream
/// version and reverify against `conformance/vectors/`.
const String _kProtocolVersion = '1.1.0';

/// Handshake configuration for the `/ext-api/mse_stream` WebSocket.
///
/// Sent as the first (and only) text frame within 15 seconds of connection
/// open. See `docs/protocol.md` §1 "Handshake".
class MseStreamConfig {
  /// Session id correlating this WS with `POST /ext-api/human`.
  /// Required; server closes with code 1002 if missing.
  /// Format per protocol: `mse-<epoch_ms>-<rand6>`.
  final String sessionId;

  /// Pipeline avatar variant. Server default is `'default'`.
  final String avatarId;

  /// TTS provider slot. Server default is `'tts5'` (Qwen3 voicelab).
  /// Known values: `tts4` (IndexTTS), `tts5`, `tts6` (XTTSv2), `tts7`
  /// (StyleTTS2), `tts8` (eSpeak).
  final String ttsSelection;

  /// Voice reference UUID. Server default is `'default'`.
  final String avatarVoice;

  /// Stream type. Currently only `'AV'` (audio+video muxed) is documented.
  final String streamType;

  const MseStreamConfig({
    required this.sessionId,
    this.avatarId = 'default',
    this.ttsSelection = 'tts5',
    this.avatarVoice = 'default',
    this.streamType = 'AV',
  });

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'avatar_id': avatarId,
        'ttsSelection': ttsSelection,
        'avatarVoice': avatarVoice,
        'stream_type': streamType,
        // twai-protocol v1.1.0 handshake tolerated field. Server
        // echoes it back so downstream health-preflight can detect
        // codec mismatch before the client hangs at HAVE_METADATA.
        // Source of truth: c:\Dev\twai-protocol\schema\constants.json.
        'protocolVersion': _kProtocolVersion,
      };

  String toJsonString() => jsonEncode(toJson());

  /// Generate a session id in the documented `mse-<epoch_ms>-<rand6>` format.
  static String newSessionId([Random? rng]) {
    final r = rng ?? Random();
    final epoch = DateTime.now().millisecondsSinceEpoch;
    final rand6 = 100000 + r.nextInt(900000);
    return 'mse-$epoch-$rand6';
  }
}

/// Speaking-state events emitted by the server as JSON text frames.
class SpeakingEvent {
  final SpeakingState value;

  /// Video presentation timestamp (seconds) at which the transition takes
  /// effect. **UI must gate on `playbackTime >= pts`**, not event receipt
  /// time — fragments lag the playback head by 0.5–1.5s. See
  /// `docs/protocol.md` §1b "Critical".
  ///
  /// **Nullable per twai-protocol spec**
  /// (`c:\Dev\twai-protocol\schema\speaking-event.schema.json:16-20`):
  /// pre-2026-05 workers omit `pts`. Conforming clients fall back to
  /// firing on receipt when pts is absent. [SpeakingGate] handles the
  /// null case; consumers reading `pts` directly must too.
  final double? pts;

  const SpeakingEvent({required this.value, this.pts});

  factory SpeakingEvent.fromJson(Map<String, dynamic> json) {
    final raw = json['value'];
    final state = switch (raw) {
      'start' => SpeakingState.start,
      'stop' => SpeakingState.stop,
      _ => throw FormatException('Unknown speaking value: $raw'),
    };
    // pts is optional per spec — absent / null is a legacy no-pts
    // event. A non-null non-numeric value is malformed, though.
    final raw2 = json['pts'];
    final double? pts = switch (raw2) {
      null => null,
      final num n => n.toDouble(),
      _ => throw FormatException('Non-numeric pts: $raw2'),
    };
    return SpeakingEvent(value: state, pts: pts);
  }

  @override
  String toString() =>
      pts == null ? 'SpeakingEvent($value @ no-pts)' : 'SpeakingEvent($value @ ${pts}s)';
}

enum SpeakingState { start, stop }
