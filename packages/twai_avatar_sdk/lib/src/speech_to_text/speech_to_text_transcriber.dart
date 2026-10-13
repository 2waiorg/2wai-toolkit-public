// Conditional-import barrel for the native [Transcriber].
//
//   Native build (no dart.library.html)    → speech_to_text_transcriber_native.dart
//   Web build (dart.library.html present)  → speech_to_text_transcriber_stub.dart
//
// Web targets should use BrowserSpeechTranscriber directly — the
// speech_to_text plugin's own web implementation failed silently in
// our embedded-Flutter-in-custom-element host even though Chrome
// exposed the SpeechRecognition API. Direct dart:js_interop wrap
// works around that. On web, this barrel returns a stub that simply
// reports unavailable.
//
// Customers normally don't instantiate this class directly — they use
// DefaultTranscriber() which picks BrowserSpeechTranscriber on web
// and SpeechToTextTranscriber on native.
export 'speech_to_text_transcriber_native.dart'
    if (dart.library.html) 'speech_to_text_transcriber_stub.dart';
