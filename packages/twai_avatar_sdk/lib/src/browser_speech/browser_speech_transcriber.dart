// Conditional-import barrel for the default web Transcriber.
//
//   Web build (dart.library.html present)  → browser_speech_transcriber_web.dart
//   Native/IO build                         → browser_speech_transcriber_stub.dart
//
// The native stub returns false from initialize() so the UI's
// availability check naturally hides the mic button on platforms
// without browser SpeechRecognition. Customers who want native voice
// input on Android/iOS/Windows should pass a different Transcriber
// implementation (their own backend, or a hosted service like Qwen3
// / ElevenLabs Scribe / Deepgram / etc).
export 'browser_speech_transcriber_stub.dart'
    if (dart.library.html) 'browser_speech_transcriber_web.dart';
