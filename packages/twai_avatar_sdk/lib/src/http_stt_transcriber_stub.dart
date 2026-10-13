import 'dart:async';

import 'transcriber.dart';

/// Native-target stub for [HttpSttTranscriber].
///
/// The web impl (`http_stt_transcriber_web.dart`) uses the browser's
/// `MediaRecorder` — no equivalent zero-cost cross-platform path exists
/// on Flutter native without either the `record` plugin (which competes
/// for AVAudioSession on iOS with livekit_client 2.8.1) or a fork of
/// flutter_webrtc that exposes its capture pipeline.
///
/// Customers wanting server-side STT on native today have two options:
///   - Use [SpeechToTextTranscriber] via [DefaultTranscriber] (native STT
///     via speech_to_text plugin — good enough for most demos).
///   - Implement a custom [Transcriber] that owns audio capture and
///     POSTs the blob to their STT endpoint. This stub is a placeholder
///     for a future shared impl.
class HttpSttTranscriber implements Transcriber {
  HttpSttTranscriber({
    required this.endpoint,
    this.headers,
    this.languageCode = 'en-US',
  });

  final Uri endpoint;
  final Map<String, String>? headers;
  final String languageCode;

  final _transcripts = StreamController<TranscriptEvent>.broadcast();
  final _errors = StreamController<TranscriberError>.broadcast();

  bool _initialized = false;

  @override
  bool get isAvailable => false;

  @override
  Future<bool> initialize() async {
    // Deliberate: signal "unavailable" instead of throwing at ctor. UI
    // hides the mic button when Transcriber.isAvailable is false, so
    // the sample degrades gracefully to text-only on native.
    _initialized = true;
    return false;
  }

  @override
  Future<void> start() {
    throw UnsupportedError(
      'HttpSttTranscriber is web-only in this SDK release. On native '
      "targets, use SpeechToTextTranscriber (via DefaultTranscriber) or "
      'implement a custom Transcriber that owns audio capture. Endpoint '
      'was configured but capture is not wired: $endpoint',
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Stream<TranscriptEvent> get transcripts => _transcripts.stream;

  @override
  Stream<TranscriberError> get errors => _errors.stream;

  @override
  Future<void> dispose() async {
    if (!_initialized) return;
    await _transcripts.close();
    await _errors.close();
  }
}
