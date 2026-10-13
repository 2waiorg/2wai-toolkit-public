import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../transcriber.dart';

/// Default web [Transcriber] — direct `dart:js_interop` wrap of the
/// browser's built-in `SpeechRecognition` / `webkitSpeechRecognition`
/// API. Free, zero-config, works in Chrome / Edge / Safari (14.5+).
///
/// Matches penthouse `lean/mic.ts` semantics for the iOS path:
/// `continuous: true` + `interimResults: true`, tap-to-toggle, locale
/// from caller (default `'en-US'`).
///
/// Why a direct wrap rather than the `speech_to_text` plugin:
/// the plugin's `initialize()` returned false in our Flutter-in-
/// custom-element setup even though Chrome exposed both
/// `SpeechRecognition` and `webkitSpeechRecognition` as functions.
/// Pattern-matched against `MediaSource` / `URL.createObjectURL`
/// (already direct-wrapped in `mse_live_sink_web.dart`) — going
/// straight to the browser API sidesteps plugin-registration
/// edge cases.
class BrowserSpeechTranscriber implements Transcriber {
  BrowserSpeechTranscriber({this.languageCode = 'en-US'});

  /// BCP-47 locale (e.g. `'en-US'`, `'es-MX'`). Passed straight to
  /// `recognition.lang`.
  final String languageCode;

  final _transcripts = StreamController<TranscriptEvent>.broadcast();
  final _errors = StreamController<TranscriberError>.broadcast();

  web.SpeechRecognition? _recognition;
  bool _initialized = false;
  bool _initFailed = false;
  bool _listening = false;
  // Baseline transcript stitched across multi-result sessions. The
  // browser fires `onresult` with the FULL results list each event;
  // we concatenate finals into _committed and emit (committed + interim)
  // so the consumer sees a monotonic transcript across pauses.
  String _committed = '';

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

    // Prefer the standard name; fall back to the webkit prefix.
    // Chrome / Edge expose both; Safari only `webkitSpeechRecognition`.
    final ctor = _pickConstructor();
    if (ctor == null) {
      _initFailed = true;
      debugPrint(
        '[BrowserSpeechTranscriber] neither SpeechRecognition nor '
        'webkitSpeechRecognition exists on window — STT unavailable',
      );
      return false;
    }

    try {
      // ignore: unused_local_variable
      final probe = ctor.callAsConstructor<web.SpeechRecognition>();
      // Probe succeeded — release immediately; real instance is built
      // on each start() so we don't hold mic state across idle periods.
      _initialized = true;
      debugPrint(
        '[BrowserSpeechTranscriber] initialized (lang=$languageCode)',
      );
      return true;
    } catch (e) {
      _initFailed = true;
      debugPrint('[BrowserSpeechTranscriber] constructor threw: $e');
      return false;
    }
  }

  /// Picks the right constructor: `window.SpeechRecognition` if
  /// available, else `window.webkitSpeechRecognition`, else null.
  JSFunction? _pickConstructor() {
    final win = web.window as JSObject;
    final std = win.getProperty('SpeechRecognition'.toJS);
    if (std != null && std.isA<JSFunction>()) return std as JSFunction;
    final webkit = win.getProperty('webkitSpeechRecognition'.toJS);
    if (webkit != null && webkit.isA<JSFunction>()) return webkit as JSFunction;
    return null;
  }

  @override
  Future<void> start() async {
    if (!isAvailable) {
      throw StateError(
        'BrowserSpeechTranscriber.initialize() must succeed before start()',
      );
    }
    if (_listening) return;

    final ctor = _pickConstructor();
    if (ctor == null) {
      _errors.add(TranscriberError.notSupported);
      return;
    }

    final r = ctor.callAsConstructor<web.SpeechRecognition>();
    _recognition = r;
    _committed = '';
    _listening = true;

    r.lang = languageCode;
    // continuous=false so Chrome's built-in VAD auto-stops on a
    // natural pause and fires onend. UX: tap mic → speak → recognizer
    // auto-commits → user reviews + taps Send. Matches the user's
    // requested flow ("tap mic, speak, tap send"). Tap mic during
    // recording still works as an explicit early-stop via stop().
    r.continuous = false;
    r.interimResults = true;
    r.maxAlternatives = 1;

    r.onresult = ((web.SpeechRecognitionEvent event) {
      // event.results carries ALL results so far this session — both
      // finals (frozen) and the trailing interim. We REPLACE the
      // baseline each event by walking the full list, rather than
      // stitching/appending, so duplicate fires of the same final
      // result can't double-add to the transcript.
      var committed = '';
      var interim = '';
      final results = event.results;
      for (var i = 0; i < results.length; i++) {
        final result = results.item(i);
        if (result.length == 0) continue;
        final text = result.item(0).transcript;
        if (result.isFinal) {
          committed = _stitch(committed, text);
        } else {
          interim = _stitch(interim, text);
        }
      }
      _committed = committed;
      final full = _stitch(committed, interim);
      _transcripts.add(TranscriptEvent(text: full, isFinal: false));
    }).toJS;

    r.onerror = ((web.SpeechRecognitionErrorEvent event) {
      _errors.add(_mapError(event.error));
      // 'no-speech' / 'aborted' aren't fatal; others end the session.
      if (event.error != 'no-speech' && event.error != 'aborted') {
        _listening = false;
      }
    }).toJS;

    r.onend = ((web.Event _) {
      _listening = false;
      // Browser ended the session (either user-initiated stop, silence
      // timeout, or natural end). Commit the final transcript.
      final finalText = _committed.trim();
      _transcripts.add(TranscriptEvent(text: finalText, isFinal: true));
    }).toJS;

    try {
      r.start();
      debugPrint('[BrowserSpeechTranscriber] start() — recognizer running');
    } catch (e) {
      _listening = false;
      _errors.add(TranscriberError.other);
      debugPrint('[BrowserSpeechTranscriber] start threw: $e');
    }
  }

  @override
  Future<void> stop() async {
    final r = _recognition;
    if (r == null || !_listening) return;
    try {
      r.stop();
    } catch (e) {
      debugPrint('[BrowserSpeechTranscriber] stop threw: $e');
    }
    // _listening flips to false in onend; the final TranscriptEvent
    // fires there too.
  }

  @override
  Future<void> cancel() async {
    final r = _recognition;
    if (r == null) return;
    try {
      r.abort();
    } catch (e) {
      debugPrint('[BrowserSpeechTranscriber] abort threw: $e');
    }
    _listening = false;
    _committed = '';
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _transcripts.close();
    await _errors.close();
  }

  /// Joins two transcript fragments with a single space separator,
  /// avoiding double spaces or stray leading/trailing space.
  String _stitch(String a, String b) {
    final ta = a.trim();
    final tb = b.trim();
    if (ta.isEmpty) return tb;
    if (tb.isEmpty) return ta;
    return '$ta $tb';
  }

  TranscriberError _mapError(String code) {
    switch (code) {
      case 'not-allowed':
      case 'service-not-allowed':
        return TranscriberError.permissionDenied;
      case 'no-speech':
      case 'speech-timeout':
        return TranscriberError.noSpeech;
      case 'network':
        return TranscriberError.networkError;
      default:
        return TranscriberError.other;
    }
  }
}
