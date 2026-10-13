// Conditional-import barrel for [DefaultTranscriber].
//
//   Web build (dart.library.html present)  → default_transcriber_web.dart
//   Native build                            → default_transcriber_native.dart
//
// Customers get one cross-platform handle:
//
//   final transcriber = DefaultTranscriber();
//
// Resolves to:
//   - [BrowserSpeechTranscriber] on web (direct dart:js_interop wrap
//     of the browser's SpeechRecognition API — free, zero setup)
//   - [SpeechToTextTranscriber] on Android / iOS / macOS / Windows
//     (wraps the speech_to_text plugin — uses platform-native STT
//     services, requires the per-platform mic permission to be
//     declared in the host app)
//
// Customers who want a non-default backend (Qwen3, Deepgram,
// ElevenLabs Scribe, their own /stt-api/transcribe endpoint) implement
// the [Transcriber] interface themselves and pass that instead.
export 'default_transcriber_native.dart'
    if (dart.library.html) 'default_transcriber_web.dart';
