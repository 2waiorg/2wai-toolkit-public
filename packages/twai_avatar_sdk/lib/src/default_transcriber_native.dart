import 'speech_to_text/speech_to_text_transcriber.dart';

/// Native build (Android / iOS / macOS / Windows): the default
/// [Transcriber] wraps the `speech_to_text` plugin against the
/// platform-native STT services.
///
/// Identical class name across platforms (the conditional barrel
/// picks `default_transcriber_web.dart` on web and this on native),
/// so customers write `DefaultTranscriber()` once and the SDK picks
/// the right implementation per build.
///
/// Requires per-platform mic permissions in the host app:
///   - iOS / macOS: `NSMicrophoneUsageDescription` +
///     `NSSpeechRecognitionUsageDescription` in `Info.plist`
///   - Android: `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
///     in `AndroidManifest.xml`
class DefaultTranscriber extends SpeechToTextTranscriber {
  DefaultTranscriber({super.languageCode});
}
