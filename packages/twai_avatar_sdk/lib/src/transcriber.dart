import 'dart:async';

/// Pluggable speech-to-text backend. The SDK provides a default web
/// implementation ([BrowserSpeechTranscriber]) that uses the browser's
/// built-in `SpeechRecognition` API (free, Chrome / Edge / Safari).
/// Customers swap in their own [Transcriber] to point at a hosted
/// service — Qwen3, ElevenLabs Scribe, Deepgram, OpenAI Whisper, or
/// any backend that converts audio to text.
///
/// Lifecycle:
///   1. Customer constructs a Transcriber and (typically) passes it to
///      the embed widget / Jesus chat UI.
///   2. UI calls [initialize] once at mount — capability probe, no
///      permission prompt yet. The mic button only renders if this
///      returns true.
///   3. On user tap, UI calls [start]. This is the gesture-context call
///      that prompts the OS / browser for microphone permission on
///      first use.
///   4. Interim transcripts stream on [transcripts] with
///      `isFinal: false` as the user speaks.
///   5. On second tap (tap-to-toggle UX), UI calls [stop]. Recognizer
///      commits whatever's in progress and fires a final
///      [TranscriptEvent] with `isFinal: true`.
///   6. [cancel] discards the current session without committing — for
///      explicit "scratch that" buttons.
///   7. UI calls [dispose] when its lifecycle ends.
abstract class Transcriber {
  /// Capability probe + warm-up. Returns false on platforms / browsers
  /// without STT support — UI hides the mic button in that case. Idempotent.
  Future<bool> initialize();

  /// True after a successful [initialize]. Sync read for build()-time
  /// conditional rendering.
  bool get isAvailable;

  /// Begin a capture session. First call typically prompts for mic
  /// permission (must be invoked from a user gesture for browser
  /// autoplay policies).
  Future<void> start();

  /// End the current session and commit any pending transcript. A
  /// final [TranscriptEvent] (`isFinal: true`) will fire on
  /// [transcripts] before this completes (or shortly after, depending
  /// on the backend's own commit latency).
  Future<void> stop();

  /// Abandon the current session WITHOUT committing the transcript.
  /// Use for explicit cancel/discard UI.
  Future<void> cancel();

  /// Transcript stream — interim updates with `isFinal: false`, then a
  /// final event with `isFinal: true` when the session commits. The
  /// final event's `text` is the authoritative transcript for that
  /// utterance.
  Stream<TranscriptEvent> get transcripts;

  /// Typed errors (permission denied, no speech, network failure).
  /// UI usually surfaces these in an error banner or chat bubble.
  Stream<TranscriberError> get errors;

  /// Release resources. Safe to call multiple times.
  Future<void> dispose();
}

/// One transcript snapshot. The same session typically emits many
/// `isFinal: false` events (one per word/phrase as recognition
/// progresses) followed by a single `isFinal: true` event when the
/// session commits.
class TranscriptEvent {
  const TranscriptEvent({required this.text, required this.isFinal});
  final String text;
  final bool isFinal;
}

/// Categories for transcriber failures. UI switches on this to decide
/// whether to prompt for permission, retry, or show an unavailable
/// message.
enum TranscriberError {
  /// Mic permission denied by the user or the platform.
  permissionDenied,

  /// Recognizer activated but heard nothing intelligible. Usually
  /// benign — UI just resets the listening indicator.
  noSpeech,

  /// Cloud-backed recognizer couldn't reach its service. Transient;
  /// retry can succeed.
  networkError,

  /// Platform doesn't ship a recognizer (Windows / Linux native,
  /// Firefox web for built-in SpeechRecognition). UI should hide the
  /// mic button.
  notSupported,

  /// Anything else. Inspect the backend's logs / debugPrint output.
  other,
}
