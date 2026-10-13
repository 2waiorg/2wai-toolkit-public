import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:web/web.dart' as web;

import 'transcriber.dart';

/// Server-side STT [Transcriber] for Flutter web.
///
/// Records mic audio via the browser's `MediaRecorder`, POSTs the blob
/// to a configurable endpoint on `stop()`, and emits the returned text
/// as a single final [TranscriptEvent]. No interim results — the endpoint
/// receives a completed utterance, one round-trip per press.
///
/// Design rationale: gen-2wai moved off browser SpeechRecognition on
/// 2026-09-04 because Brave silently strips transcription keys and
/// Chrome treats network blips as resumable pauses; the exit note
/// (Studio `dictation.ts`) is that server-side Whisper is the honest
/// path. Mason's `@twai/mic` package ships the same shape. This is the
/// Dart equivalent, matching that endpoint contract:
///   POST <endpoint> multipart/form-data field "audio"
///   response: { "text": "..." }
class HttpSttTranscriber implements Transcriber {
  HttpSttTranscriber({
    required this.endpoint,
    this.headers,
    this.languageCode = 'en-US',
    this.fieldName = 'audio',
  });

  /// Where the recorded blob is POSTed on `stop()`.
  final Uri endpoint;

  /// Optional headers (auth, tenant scoping) sent with the POST.
  final Map<String, String>? headers;

  /// Optional BCP-47 tag sent in the same multipart form under
  /// `language`. Server may honour or ignore.
  final String languageCode;

  /// Multipart form field name for the blob. Default `audio` matches
  /// gen-2wai's `/api/gen/dictation/transcribe` and `@twai/mic`.
  final String fieldName;

  final _transcripts = StreamController<TranscriptEvent>.broadcast();
  final _errors = StreamController<TranscriberError>.broadcast();

  web.MediaRecorder? _recorder;
  web.MediaStream? _stream;
  final List<web.Blob> _chunks = <web.Blob>[];
  String _mimeType = '';
  bool _isAvailable = false;
  bool _isRecording = false;

  @override
  bool get isAvailable => _isAvailable;

  @override
  Future<bool> initialize() async {
    // Capability probe — MediaRecorder + getUserMedia. No permission
    // prompt until start().
    final win = web.window as JSObject;
    final hasRecorder = win.has('MediaRecorder');
    final hasGum = win.has('navigator') &&
        (win.getProperty('navigator'.toJS) as JSObject).has('mediaDevices');
    _isAvailable = hasRecorder && hasGum;
    if (!_isAvailable) {
      debugPrint(
        '[HttpSttTranscriber] MediaRecorder or getUserMedia missing — '
        'unavailable on this browser',
      );
    }
    return _isAvailable;
  }

  @override
  Future<void> start() async {
    if (_isRecording) return;
    if (!_isAvailable) {
      _errors.add(TranscriberError.notSupported);
      throw StateError('HttpSttTranscriber not initialized or unsupported');
    }
    _chunks.clear();

    // Ordered mime-type fallback matches @twai/mic (avatar-player parity):
    // opus is smallest, mp4 is Safari's format, ogg the last-resort. First
    // one the browser accepts wins.
    const candidates = <String>[
      'audio/webm;codecs=opus',
      'audio/webm',
      'audio/mp4',
      'audio/ogg',
    ];
    _mimeType = candidates.firstWhere(
      (m) => web.MediaRecorder.isTypeSupported(m),
      orElse: () => '',
    );

    try {
      final constraints = web.MediaStreamConstraints(audio: true.toJS);
      _stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
    } catch (e) {
      _errors.add(_classifyGumError(e));
      rethrow;
    }

    final opts = _mimeType.isEmpty
        ? web.MediaRecorderOptions()
        : (web.MediaRecorderOptions()..mimeType = _mimeType);
    final recorder = web.MediaRecorder(_stream!, opts);

    recorder.ondataavailable = ((web.BlobEvent event) {
      if (event.data.size > 0) _chunks.add(event.data);
    }).toJS;

    // Timeslice: 1s chunks. Matches gen-2wai VoiceRecorder's rec.start(1000)
    // — protects against a single dropped final ondataavailable losing the
    // whole recording (a documented Safari flake).
    recorder.start(1000);
    _recorder = recorder;
    _isRecording = true;
  }

  @override
  Future<void> stop() async {
    if (!_isRecording || _recorder == null) return;
    _isRecording = false;

    final done = Completer<Uint8List>();
    _recorder!.onstop = ((web.Event _) {
      final mime = _mimeType.isEmpty ? 'audio/webm' : _mimeType;
      // Merge all blobs into a single one — the Blob ctor accepts an
      // array of BlobParts (Blob | BufferSource | string). Keep the raw
      // Blobs we captured; the browser handles concat efficiently.
      final parts = _chunks.map((b) => b as web.BlobPart).toList().toJS;
      final blob = web.Blob(parts, web.BlobPropertyBag(type: mime));
      _blobToBytes(blob).then(done.complete, onError: done.completeError);
    }).toJS;
    _recorder!.stop();
    // Stop the stream tracks so the browser's mic-in-use indicator clears.
    _stream?.getTracks().toDart.forEach((t) => t.stop());
    _stream = null;

    Uint8List bytes;
    try {
      bytes = await done.future;
    } catch (e) {
      _errors.add(TranscriberError.other);
      return;
    }

    try {
      final text = await _postForTranscript(bytes);
      if (text.isEmpty) {
        _errors.add(TranscriberError.noSpeech);
      } else {
        _transcripts.add(TranscriptEvent(text: text, isFinal: true));
      }
    } catch (e) {
      debugPrint('[HttpSttTranscriber] POST failed: $e');
      _errors.add(TranscriberError.networkError);
    }
    _recorder = null;
    _chunks.clear();
  }

  @override
  Future<void> cancel() async {
    if (!_isRecording || _recorder == null) return;
    _isRecording = false;
    _recorder!.onstop = ((web.Event _) {}).toJS;
    _recorder!.stop();
    _stream?.getTracks().toDart.forEach((t) => t.stop());
    _stream = null;
    _recorder = null;
    _chunks.clear();
  }

  @override
  Stream<TranscriptEvent> get transcripts => _transcripts.stream;

  @override
  Stream<TranscriberError> get errors => _errors.stream;

  @override
  Future<void> dispose() async {
    await cancel();
    await _transcripts.close();
    await _errors.close();
  }

  Future<String> _postForTranscript(Uint8List bytes) async {
    final mime = _mimeType.isEmpty ? 'audio/webm' : _mimeType;
    final filename = 'audio.${_extForMime(mime)}';
    final request = http.MultipartRequest('POST', endpoint)
      ..fields['language'] = languageCode
      ..files.add(
        http.MultipartFile.fromBytes(
          fieldName,
          bytes,
          filename: filename,
          contentType: MediaType.parse(mime),
        ),
      );
    if (headers != null) request.headers.addAll(headers!);
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('STT endpoint returned ${response.statusCode}');
    }
    // Standard shape: { "text": "..." }. If the server returns something
    // else, callers know because there's no default field to guess at.
    final body = response.body;
    final match = RegExp(r'"text"\s*:\s*"((?:\\.|[^"\\])*)"').firstMatch(body);
    if (match == null) return '';
    // Unescape common JSON escapes for readability. Empty is fine.
    return match
        .group(1)!
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\')
        .replaceAll(r'\n', '\n');
  }

  static String _extForMime(String mime) {
    if (mime.startsWith('audio/webm')) return 'webm';
    if (mime.startsWith('audio/mp4')) return 'm4a';
    if (mime.startsWith('audio/ogg')) return 'ogg';
    return 'bin';
  }

  static TranscriberError _classifyGumError(Object e) {
    final msg = e.toString();
    if (msg.contains('NotAllowed') || msg.contains('Permission')) {
      return TranscriberError.permissionDenied;
    }
    if (msg.contains('NotFound')) return TranscriberError.notSupported;
    return TranscriberError.other;
  }

  static Future<Uint8List> _blobToBytes(web.Blob blob) async {
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }
}

