import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:record/record.dart';

import 'record_stt_transcriber_wav.dart';
import 'transcriber.dart';

/// Cross-platform [Transcriber] that captures raw PCM via the `record`
/// package, wraps it in a WAV header, and POSTs to a Whisper-shaped
/// server STT endpoint. Uses `audio_session` to configure the platform
/// audio session explicitly so it coexists with an active LiveKit
/// (or other WebRTC) session.
///
/// **Status (2026-10-01): live in SDK, not used by any shipped demo.**
///
/// Shipped with a 7-app wire-up (943e13a), then unwired from the demos
/// (a6b565b + 35ceb98) once the actual Android regression consumers were
/// hitting turned out to be a compositor issue in [TwaiTransport0Player]
/// rather than a transcriber issue — see `docs/mic_android_pending.md`
/// and `architecture.md#android-status`.
///
/// Retained in the SDK as a live, tested, dependency-complete transcriber
/// for the near-term 2wai `POST /v1/transcribe` path (a thin forwarding
/// route on `twai-api` → the existing `stt-2wai` Container App). When
/// that endpoint lands, consumer apps swap in by construction:
///
///     final transcriber = _kSttUrl.isNotEmpty
///         ? RecordSttTranscriber(endpoint: Uri.parse(_kSttUrl))
///         : DefaultTranscriber();
///
/// Also usable today by consumers who have their own Whisper-shaped
/// endpoint (OpenAI, Deepgram, self-hosted whisper.cpp, etc.) and want
/// cross-platform reliability including Android + LiveKit coexistence
/// (sidesteps `SpeechRecognizer`).
///
/// **Motivation.** The default [SpeechToTextTranscriber] wraps the
/// `speech_to_text` plugin → native `SpeechRecognizer` on Android. In
/// LiveKit-active contexts something in the audio init path flips
/// Android `AudioManager.mode` to a state where `SpeechRecognizer`
/// silently drops results — see `docs/mic_android_pending.md` for the
/// full picture. This transcriber avoids the failure class entirely by
/// capturing at a lower level (`AudioRecord` on Android via `record`)
/// and delegating STT to a server. Production-proven pattern: QAI's
/// shipping medical app + Mason's `@twai/mic` (blob-per-turn) + gen-2wai
/// `POST /api/gen/dictation/transcribe` — see the design doc at
/// `docs/audio_stream_transcriber_design.md`.
///
/// **Wire contract:**
///
///   POST <endpoint> multipart/form-data
///     Content-Type: multipart/form-data; boundary=...
///     part 'audio' — WAV blob (44-byte header + PCM16 LE, mono, 16 kHz
///       by default). Filename `audio.wav`, Content-Type `audio/wav`.
///     part 'language' — BCP-47 [languageCode].
///   Response: { "text": "..." } JSON. Empty text → [TranscriberError.noSpeech].
///   Non-2xx → [TranscriberError.networkError].
///
/// **Consumer wiring** (mirrors any other [Transcriber]):
///
///     final t = RecordSttTranscriber(
///       endpoint: Uri.parse('https://stt.example.com/transcribe'),
///       headers: {'Authorization': 'Bearer <token>'},
///     );
///     TwaiMicButton(transcriber: t, ...);
///
/// **Session management:** on `start`, configures the platform audio
/// session with a speech-friendly, LiveKit-compatible profile (iOS
/// `.playAndRecord` + `.spokenAudio` + `.defaultToSpeaker`; Android
/// `voiceCommunication` usage + `speech` content type). Consumer can
/// override via [audioSessionConfig].
///
/// **iOS interruption handling:** phone calls / Siri / alarms pause the
/// recorder and route to [TranscriberError.other] with a resumable
/// state (Consumer sees the recording cancel; the next `start` proceeds
/// normally after the interruption ends).
///
/// **Android interruption handling:** deliberately does NOT listen to
/// `interruptionEventStream` — Android's stream piggybacks on
/// `AudioManager.requestAudioFocus()` callbacks that fire for many
/// non-interruption events (foreground service notifications, SCO
/// handshakes, momentary system ducks). The OS handles real phone
/// calls; the recorder captures silence during the actual call.
class RecordSttTranscriber implements Transcriber {
  RecordSttTranscriber({
    required this.endpoint,
    this.headers,
    this.languageCode = 'en-US',
    this.fieldName = 'audio',
    this.sampleRate = 16000,
    this.numChannels = 1,
    this.audioSessionConfig,
    RecordConfig? recordConfig,
    AudioRecorder? recorder,
    http.Client? httpClient,
  })  : _recordConfig = recordConfig ??
            RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: sampleRate,
              numChannels: numChannels,
            ),
        _recorder = recorder ?? AudioRecorder(),
        _httpClient = httpClient ?? http.Client();

  /// Where the recorded blob is POSTed on `stop`.
  final Uri endpoint;

  /// Optional headers (auth, tenant scoping) sent with the POST.
  final Map<String, String>? headers;

  /// BCP-47 tag included in the multipart form under `language`. Server
  /// may honour or ignore; when server ignores, this field carries
  /// intent that customer logs can pin.
  final String languageCode;

  /// Multipart form field name for the audio blob. Default `audio`
  /// matches gen-2wai's dictation endpoint and Mason's `@twai/mic`.
  final String fieldName;

  /// PCM sample rate in Hz. Default 16 kHz — the Whisper input target.
  final int sampleRate;

  /// PCM channel count. Default 1 (mono) — the Whisper input target.
  final int numChannels;

  /// Optional audio-session configuration override. Default:
  /// [_kDefaultAudioSessionConfig] — speech-friendly, LiveKit-compatible.
  final AudioSessionConfiguration? audioSessionConfig;

  final RecordConfig _recordConfig;
  final AudioRecorder _recorder;
  final http.Client _httpClient;

  final _transcripts = StreamController<TranscriptEvent>.broadcast();
  final _errors = StreamController<TranscriberError>.broadcast();

  bool _isAvailable = false;
  bool _isRecording = false;
  StreamSubscription<Uint8List>? _pcmSub;
  final _pcmChunks = <Uint8List>[];
  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;

  @override
  bool get isAvailable => _isAvailable;

  @override
  Stream<TranscriptEvent> get transcripts => _transcripts.stream;

  @override
  Stream<TranscriberError> get errors => _errors.stream;

  @override
  Future<bool> initialize() async {
    if (_isAvailable) return true;
    try {
      // Capability probe — no permission prompt yet. `record` returns
      // whether the recording pipeline is available on this platform;
      // permission-denied is a runtime error at start(), not here.
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        // Permission may not have been requested yet. Do NOT probe here
        // — start() is the user-gesture context where the OS will
        // prompt. Return available; if the user denies, start() surfaces
        // TranscriberError.permissionDenied.
      }
      _session = await AudioSession.instance;
      _isAvailable = true;
      return true;
    } catch (e) {
      debugPrint('[RecordSttTranscriber] initialize failed: $e');
      _isAvailable = false;
      return false;
    }
  }

  @override
  Future<void> start() async {
    if (_isRecording) return;
    if (!_isAvailable) {
      _errors.add(TranscriberError.notSupported);
      throw StateError(
        'RecordSttTranscriber not initialized. Call initialize() first.',
      );
    }

    // Session configure + interruption wiring.
    final session = _session;
    if (session != null) {
      try {
        await session.configure(
          audioSessionConfig ?? _kDefaultAudioSessionConfig,
        );
        await session.setActive(true);
      } catch (e) {
        debugPrint('[RecordSttTranscriber] session configure failed: $e');
        // Non-fatal: record may still work without explicit session
        // configuration on some platforms.
      }
      _wireInterruptions(session);
    }

    // Permission check — start() is a user-gesture context, so this is
    // where iOS/Android prompt on first use.
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _errors.add(TranscriberError.permissionDenied);
      await _teardownSession();
      throw StateError('Microphone permission denied');
    }

    _pcmChunks.clear();
    try {
      final stream = await _recorder.startStream(_recordConfig);
      _pcmSub = stream.listen(
        _pcmChunks.add,
        onError: (Object err) {
          debugPrint('[RecordSttTranscriber] pcm stream error: $err');
          _errors.add(TranscriberError.other);
        },
      );
      _isRecording = true;
    } catch (e) {
      debugPrint('[RecordSttTranscriber] startStream failed: $e');
      _errors.add(_classifyStartError(e));
      await _teardownSession();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRecording) return;
    _isRecording = false;

    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[RecordSttTranscriber] stop failed: $e');
    }
    await _pcmSub?.cancel();
    _pcmSub = null;

    final pcm = _flattenChunks();
    _pcmChunks.clear();
    await _teardownSession();

    if (pcm.isEmpty) {
      _errors.add(TranscriberError.noSpeech);
      return;
    }

    // Wrap + POST + emit.
    final wav = wrapPcmAsWav(
      pcm: pcm,
      sampleRate: sampleRate,
      numChannels: numChannels,
    );

    try {
      final text = await _postForTranscript(wav);
      if (text.isEmpty) {
        _errors.add(TranscriberError.noSpeech);
      } else {
        _transcripts.add(TranscriptEvent(text: text, isFinal: true));
      }
    } catch (e) {
      debugPrint('[RecordSttTranscriber] POST failed: $e');
      _errors.add(TranscriberError.networkError);
    }
  }

  @override
  Future<void> cancel() async {
    if (!_isRecording) return;
    _isRecording = false;

    try {
      await _recorder.cancel();
    } catch (_) {
      // Best-effort: cancel may not be supported on every platform.
      try {
        await _recorder.stop();
      } catch (_) {
        // Ignore secondary teardown errors.
      }
    }
    await _pcmSub?.cancel();
    _pcmSub = null;
    _pcmChunks.clear();
    await _teardownSession();
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    try {
      await _recorder.dispose();
    } catch (_) {
      /* ignore */
    }
    _httpClient.close();
    await _transcripts.close();
    await _errors.close();
  }

  // ─── Internals ─────────────────────────────────────────────────────

  void _wireInterruptions(AudioSession session) {
    // iOS-only: on Android, `interruptionEventStream` piggybacks on
    // `AudioManager.requestAudioFocus()` callbacks that fire for many
    // non-interruption events (foreground service notifications, SCO
    // handshakes, momentary system ducks). Rely on the OS to handle
    // real phone calls (audio focus is revoked; the recorder captures
    // silence during the call).
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) return;

    _interruptionSub?.cancel();
    _interruptionSub = session.interruptionEventStream.listen((event) async {
      if (!event.begin) return;
      // Interruption began (call, Siri, alarm). Cancel the recording;
      // consumer's UI transitions the mic button back to idle.
      if (_isRecording) {
        debugPrint(
          '[RecordSttTranscriber] iOS interruption began (type=${event.type}) — canceling',
        );
        await cancel();
      }
    });
  }

  Future<void> _teardownSession() async {
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    try {
      // NOTE: we do NOT `setActive(false)` on the shared audio session.
      // Doing so would tear down a concurrent LiveKit playout unit —
      // the exact class of bug the iOS + LiveKit coexistence patch on
      // `speech_to_text` was written to avoid. Leaving the session
      // active is safe: `livekit_client` (or whoever borrowed it first)
      // owns lifecycle.
    } catch (_) {
      /* ignore */
    }
  }

  Uint8List _flattenChunks() {
    if (_pcmChunks.isEmpty) return Uint8List(0);
    final total = _pcmChunks.fold<int>(0, (n, c) => n + c.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final chunk in _pcmChunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }

  Future<String> _postForTranscript(Uint8List wav) async {
    final request = http.MultipartRequest('POST', endpoint)
      ..fields['language'] = languageCode
      ..files.add(
        http.MultipartFile.fromBytes(
          fieldName,
          wav,
          filename: 'audio.wav',
          contentType: MediaType.parse('audio/wav'),
        ),
      );
    if (headers != null) request.headers.addAll(headers!);

    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('STT endpoint returned ${response.statusCode}');
    }
    // Standard shape: { "text": "..." }. Empty match returns '' — caller
    // classifies that as noSpeech, not networkError.
    final match = RegExp(r'"text"\s*:\s*"((?:\\.|[^"\\])*)"')
        .firstMatch(response.body);
    if (match == null) return '';
    return match
        .group(1)!
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\')
        .replaceAll(r'\n', '\n');
  }

  static TranscriberError _classifyStartError(Object e) {
    final msg = e.toString();
    if (msg.contains('NotAllowed') ||
        msg.contains('Permission') ||
        msg.contains('permission')) {
      return TranscriberError.permissionDenied;
    }
    if (msg.contains('NotFound') || msg.contains('UnsupportedType')) {
      return TranscriberError.notSupported;
    }
    return TranscriberError.other;
  }
}

/// Speech-friendly, LiveKit-compatible default. Adapted from QAI's
/// production `AudioSessionService` config: `.playAndRecord` +
/// `.spokenAudio` on iOS keeps the session compatible with an active
/// LiveKit playout unit; Android `voiceCommunication` usage +
/// `speech` content type + `gain` focus signals speech intent.
///
/// `final`, not `const`: `AVAudioSessionCategoryOptions.|` is not
/// const-eval-able (the value type wraps a bit field but overrides `|`
/// as an instance method rather than exposing an int constant).
final _kDefaultAudioSessionConfig = AudioSessionConfiguration(
  avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
  avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
      AVAudioSessionCategoryOptions.allowBluetoothA2dp |
      AVAudioSessionCategoryOptions.defaultToSpeaker |
      AVAudioSessionCategoryOptions.mixWithOthers,
  avAudioSessionMode: AVAudioSessionMode.spokenAudio,
  avAudioSessionRouteSharingPolicy:
      AVAudioSessionRouteSharingPolicy.defaultPolicy,
  avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
  androidAudioAttributes: const AndroidAudioAttributes(
    contentType: AndroidAudioContentType.speech,
    flags: AndroidAudioFlags.none,
    usage: AndroidAudioUsage.voiceCommunication,
  ),
  androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  androidWillPauseWhenDucked: true,
);
