import 'package:flutter/widgets.dart';

/// Non-web stub for the MSE platform impl.
///
/// [WebMseStreamSink] uses this via conditional import when
/// `dart.library.js_interop` is unavailable (i.e. everywhere except
/// Flutter web). Construction throws with a clear message so a
/// misconfigured multi-platform app fails loud instead of silently
/// producing a broken player.
///
/// Multi-platform apps should conditional-import a fallback sink
/// (e.g. `VideoPlayerMseStreamSink` from `twai_avatar_sdk_video_player`
/// or `MediaKitMseStreamSink` from `twai_avatar_sdk_media_kit`) and
/// dispatch by platform at construction time.
class MseImpl {
  MseImpl({
    required this.codec,
    required this.evictKeepBehindSec,
    required this.onFirstFrame,
    required this.onWaiting,
    required this.onTimeUpdate,
  }) {
    throw UnsupportedError(
      'twai_avatar_sdk_web_mse is Flutter web only. On non-web platforms '
      'construct a fallback sink (VideoPlayerMseStreamSink or '
      'MediaKitMseStreamSink) via conditional import. See '
      'docs/sink_streaming_scoping.md §4.',
    );
  }

  final String codec;
  final int evictKeepBehindSec;
  final void Function() onFirstFrame;
  final void Function() onWaiting;
  final void Function(double seconds) onTimeUpdate;

  Widget buildWidget() =>
      throw UnsupportedError('MseImpl stub — no widget on non-web');

  void appendBytes(List<int> bytes) {}
  double? get currentTime => null;
  double? get bufferEnd => null;
  void seekTo(double seconds) {}
  void evictOldBuffer(double keepBehindSec) {}
  Future<void> dispose() async {}
}
