import 'dart:async';

import '../transcriber.dart';

/// Web stub for [SpeechToTextTranscriber]. Web targets should use
/// [BrowserSpeechTranscriber] directly (the speech_to_text plugin's
/// web implementation has known issues in our hostElement-embedded
/// setup). This stub exists only so the conditional barrel compiles
/// on web — if you instantiate it there, [initialize] returns false
/// and the mic UI is hidden.
class SpeechToTextTranscriber implements Transcriber {
  SpeechToTextTranscriber({String languageCode = 'en-US'});

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
