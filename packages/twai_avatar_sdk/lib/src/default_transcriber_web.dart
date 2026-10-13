import 'browser_speech/browser_speech_transcriber.dart';

/// Web build: the default [Transcriber] is the direct
/// `dart:js_interop` wrap of the browser's `SpeechRecognition` API.
/// Free, zero-config, works in Chrome / Edge / Safari 14.5+.
///
/// Identical class name across platforms (the conditional barrel
/// picks this on web and `default_transcriber_native.dart` on
/// native), so customers write `DefaultTranscriber()` once and the
/// SDK picks the right implementation per build.
class DefaultTranscriber extends BrowserSpeechTranscriber {
  DefaultTranscriber({super.languageCode});
}
