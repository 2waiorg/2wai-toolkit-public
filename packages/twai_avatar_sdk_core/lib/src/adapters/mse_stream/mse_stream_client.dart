import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'mse_stream_config.dart';
import 'mse_stream_errors.dart';

/// Factory that produces a [WebSocketChannel] for a given URL. Real code
/// uses [WebSocketChannel.connect]; tests inject a fake pointing at an
/// in-process server.
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri url);

/// Dart-native client for the 2wai `/ext-api/mse_stream` WebSocket.
///
/// Opens the WS, sends the handshake JSON within the 15s window, and
/// demuxes server frames into two streams:
///
/// - [binaryFrames] — fragmented MP4 (`ftyp`+`moov` init seg first, then
///   `moof`+`mdat` media segs).
/// - [speakingEvents] — `{"type":"speaking","value":"start|stop","pts":...}`
///   JSON text frames, parsed into [SpeakingEvent].
///
/// Does **not** auto-reconnect. Close codes 1002 (config) and 1011 (server)
/// are surfaced as typed [MseStreamCloseReason] via [done] for the caller
/// to handle.
class MseStreamClient {
  MseStreamClient({WebSocketChannelFactory? channelFactory})
      : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final WebSocketChannelFactory _channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _connected = false;

  final _binaryFrames = StreamController<Uint8List>();
  final _speakingEvents = StreamController<SpeakingEvent>();
  final _done = Completer<MseStreamCloseReason>();

  Stream<Uint8List> get binaryFrames => _binaryFrames.stream;
  Stream<SpeakingEvent> get speakingEvents => _speakingEvents.stream;

  /// Resolves when the WebSocket closes (cleanly via [close], by the
  /// server, or due to transport error).
  Future<MseStreamCloseReason> get done => _done.future;

  /// Open the WebSocket, send the handshake, and start demuxing.
  ///
  /// Throws [StateError] if called twice on the same instance.
  /// Throws on transport-level connection failure; later closures
  /// arrive via [done].
  Future<void> connect(Uri url, MseStreamConfig config) async {
    if (_connected) {
      throw StateError('MseStreamClient.connect called twice');
    }
    _connected = true;

    final ch = _channelFactory(url);
    _channel = ch;

    await ch.ready;
    ch.sink.add(config.toJsonString());

    _sub = ch.stream.listen(
      _onFrame,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic frame) {
    if (frame is Uint8List) {
      _binaryFrames.add(frame);
    } else if (frame is List<int>) {
      _binaryFrames.add(Uint8List.fromList(frame));
    } else if (frame is String) {
      _handleText(frame);
    }
  }

  void _handleText(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['type'] != 'speaking') return;
    try {
      _speakingEvents.add(SpeakingEvent.fromJson(decoded));
    } on FormatException {
      // Malformed speaking event — drop silently.
    }
  }

  void _onError(Object error, StackTrace st) {
    if (!_done.isCompleted) {
      _done.complete(OtherClose(-1, error.toString()));
    }
    if (!_binaryFrames.isClosed) _binaryFrames.addError(error, st);
    if (!_speakingEvents.isClosed) _speakingEvents.addError(error, st);
  }

  void _onDone() {
    final ch = _channel;
    final reason = mseStreamCloseFor(ch?.closeCode, ch?.closeReason);
    if (!_done.isCompleted) _done.complete(reason);
    if (!_binaryFrames.isClosed) _binaryFrames.close();
    if (!_speakingEvents.isClosed) _speakingEvents.close();
  }

  /// Close the WebSocket cleanly (close code 1000).
  ///
  /// Sends the close frame but does not block on the close handshake —
  /// `WebSocketSink.close` on some platforms (notably dart:io) only
  /// resolves after the remote echoes the close frame, which can hang
  /// indefinitely if the server is unresponsive or already gone.
  Future<void> close() async {
    // Mark intent first so _onDone (triggered by the cancel below) can't
    // race us and report OtherClose(-1) for an intentional close.
    if (!_done.isCompleted) _done.complete(const NormalClose());

    final ch = _channel;
    if (ch != null) {
      unawaited(ch.sink.close(1000).catchError((_) {}));
    }
    await _sub?.cancel();
    if (!_binaryFrames.isClosed) await _binaryFrames.close();
    if (!_speakingEvents.isClosed) await _speakingEvents.close();
  }
}
