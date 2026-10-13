import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

/// Native stub for [VideoPlayerMseLiveSink]. The real implementation
/// lives in `mse_live_sink_web.dart` and requires browser-only APIs
/// (`MediaSource`, `SourceBuffer`, `HTMLVideoElement`,
/// `URL.createObjectURL`). On native targets, every entry point throws
/// `UnsupportedError` with a hint to use `VideoPlayerMseStreamSink`
/// (the buffer-and-play sink) instead.
class VideoPlayerMseLiveSink implements VideoSink {
  VideoPlayerMseLiveSink({bool debugLog = false}) {
    throw UnsupportedError(
      'VideoPlayerMseLiveSink is web-only. On native targets use '
      'VideoPlayerMseStreamSink (buffer-and-play) or '
      'MediaKitMseStreamSink instead.',
    );
  }

  @override
  Future<void> attach(ChatSession session) =>
      throw UnsupportedError('VideoPlayerMseLiveSink is web-only');

  @override
  Widget buildWidget() =>
      throw UnsupportedError('VideoPlayerMseLiveSink is web-only');

  @override
  Future<void> dispose() async {}

  @override
  ValueListenable<bool> get isRenderingContent => alwaysNotRendering;
}
