// Conditional-import barrel for [HttpSttTranscriber].
//
//   Web build (dart.library.html present)  → http_stt_transcriber_web.dart
//   Native build                            → http_stt_transcriber_stub.dart
//
// Web-only in V1 (uses browser MediaRecorder + POST to the STT endpoint).
// Native builds get a stub that throws a descriptive error at
// initialize() — customers should use [SpeechToTextTranscriber] for
// native today, or bring their own [Transcriber] impl backed by the
// `record` package + the same endpoint. Native support here is deferred
// pending native audio-session coexistence with livekit_client's own
// AVAudioSession ownership (see docs/livekit_ios_receive_only_audio.md).
export 'http_stt_transcriber_stub.dart'
    if (dart.library.html) 'http_stt_transcriber_web.dart';
