import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../transcriber.dart';

/// Native [Transcriber] — wraps `package:speech_to_text` for Android /
/// iOS / macOS / Windows. Mirrors [BrowserSpeechTranscriber]'s shape
/// so the same UI code (chat widget, Jesus app) works across web and
/// native: tap-to-toggle, `continuous: false`, interim transcripts
/// stream as `isFinal: false`, final transcript fires once on commit.
///
/// **Platform support** (via `speech_to_text` plugin 7.x):
///   - Android: native `SpeechRecognizer` service
///   - iOS / macOS: native `Speech` framework
///   - Windows: beta support per plugin docs
///   - Linux: not supported — [initialize] returns false; UI hides
///     the mic button automatically
///
/// **Permissions** (set up by the app, not the SDK):
///   - iOS / macOS: `NSMicrophoneUsageDescription` +
///     `NSSpeechRecognitionUsageDescription` in Info.plist
///   - Android: `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`
///     in `AndroidManifest.xml`
///
/// **iOS + LiveKit coexistence** (load-bearing for Transport 0 apps):
/// upstream `speech_to_text` calls `AVAudioSession.setActive(false)` on
/// stop, which tears down LiveKit's process-wide playout unit. This
/// transcriber's iOS behavior depends on the workspace's vendored patch
/// at `packages/twai_speech_to_text_patched/` — the root `pubspec.yaml`
/// `dependency_overrides.speech_to_text` swaps it in for every workspace
/// member. External SDK consumers must add the same override in their
/// own `pubspec.yaml` (see `docs/mic_lifecycle_ios_livekit.md`). Without
/// it, the avatar goes silent after the first mic turn.
///
/// **Android status** (2026-09-19): mic capture visually engages but
/// transcripts silently miss in some LiveKit-active contexts. Diagnostic
/// pending; see `docs/mic_android_pending.md` for the current known-gap
/// note and the adb-logcat recipe to help reproduce.
///
/// Customers normally don't instantiate this directly — they use
/// [DefaultTranscriber] which picks this on native and
/// [BrowserSpeechTranscriber] on web.
class SpeechToTextTranscriber implements Transcriber {
  SpeechToTextTranscriber({this.languageCode = 'en-US'});

  /// BCP-47 locale (e.g. `'en-US'`). Passed to `listen()` per session.
  final String languageCode;

  final _stt = stt.SpeechToText();
  final _transcripts = StreamController<TranscriptEvent>.broadcast();
  final _errors = StreamController<TranscriberError>.broadcast();

  bool _initialized = false;
  bool _initFailed = false;
  bool _listening = false;
  // Final-transcript guard: speech_to_text fires onResult with
  // result.finalResult=true once per session. We track it so stop()
  // can synthesize a final event if the plugin's auto-end path
  // doesn't fire one (rare, platform-dependent).
  bool _emittedFinal = false;
  String _lastText = '';

  @override
  bool get isAvailable => _initialized && !_initFailed;

  @override
  Stream<TranscriptEvent> get transcripts => _transcripts.stream;

  @override
  Stream<TranscriberError> get errors => _errors.stream;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    if (_initFailed) return false;
    try {
      _initialized = await _stt.initialize(
        onError: (e) {
          _errors.add(_mapError(e.errorMsg));
        },
        onStatus: (_) {/* status hooks not used in V1 */},
      );
      if (!_initialized) _initFailed = true;
      debugPrint('[SpeechToTextTranscriber] initialized=$_initialized');
    } catch (e) {
      _initFailed = true;
      _errors.add(TranscriberError.notSupported);
      debugPrint('[SpeechToTextTranscriber] initialize threw: $e');
    }
    return _initialized;
  }

  @override
  Future<void> start() async {
    if (!isAvailable) {
      throw StateError(
        'SpeechToTextTranscriber.initialize() must succeed before start()',
      );
    }
    if (_listening) return;
    _lastText = '';
    _emittedFinal = false;
    _listening = true;
    try {
      await _stt.listen(
        onResult: (r) {
          _lastText = r.recognizedWords;
          if (r.finalResult) {
            _emittedFinal = true;
            _listening = false;
            _transcripts.add(TranscriptEvent(text: _lastText, isFinal: true));
          } else {
            _transcripts.add(TranscriptEvent(text: _lastText, isFinal: false));
          }
        },
        // SpeechListenOptions matches BrowserSpeechTranscriber's
        // continuous=false UX — engine's own VAD auto-stops on a
        // natural pause, then we get a finalResult callback. The user
        // can also tap mic again to force-stop early.
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.confirmation,
          localeId: languageCode,
        ),
      );
    } catch (e) {
      _listening = false;
      _errors.add(TranscriberError.other);
      debugPrint('[SpeechToTextTranscriber] start threw: $e');
    }
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    try {
      await _stt.stop();
    } catch (e) {
      debugPrint('[SpeechToTextTranscriber] stop threw: $e');
    }
    // If the plugin didn't already fire a finalResult (e.g. user
    // stopped before the engine's VAD did), commit the most recent
    // interim text as final.
    if (!_emittedFinal) {
      _emittedFinal = true;
      _transcripts.add(TranscriptEvent(text: _lastText, isFinal: true));
    }
  }

  @override
  Future<void> cancel() async {
    if (!_listening) return;
    _listening = false;
    _lastText = '';
    try {
      await _stt.cancel();
    } catch (e) {
      debugPrint('[SpeechToTextTranscriber] cancel threw: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _transcripts.close();
    await _errors.close();
  }

  TranscriberError _mapError(String msg) {
    final lower = msg.toLowerCase();
    if (lower.contains('permission') || lower.contains('not-allowed')) {
      return TranscriberError.permissionDenied;
    }
    if (lower.contains('no_match') ||
        lower.contains('no-speech') ||
        lower.contains('speech_timeout')) {
      return TranscriberError.noSpeech;
    }
    if (lower.contains('network')) return TranscriberError.networkError;
    return TranscriberError.other;
  }
}
