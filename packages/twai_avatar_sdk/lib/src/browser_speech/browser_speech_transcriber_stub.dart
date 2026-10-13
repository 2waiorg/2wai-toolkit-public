import 'dart:async';

import '../transcriber.dart';

/// Native stub for [BrowserSpeechTranscriber]. The real implementation
/// lives in `browser_speech_transcriber_web.dart` and requires browser-
/// only APIs (`SpeechRecognition` / `webkitSpeechRecognition`).
///
/// On native targets, [initialize] returns false. UI components that
/// conditionally render the mic button on `transcriber.isAvailable`
/// simply won't show one — no customer-side platform check needed.
///
/// Customers who want native voice input should pass a different
/// [Transcriber] implementation (their own backend, or a hosted
/// service like Qwen3 / ElevenLabs Scribe / Deepgram / etc).
class BrowserSpeechTranscriber implements Transcriber {
  BrowserSpeechTranscriber({String languageCode = 'en-US'});

  @override
  bool get isAvailable => false;

  @override
  Future<bool> initialize() async => false;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Stream<TranscriptEvent> get transcripts => const Stream.empty();

  @override
  Stream<TranscriberError> get errors => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
