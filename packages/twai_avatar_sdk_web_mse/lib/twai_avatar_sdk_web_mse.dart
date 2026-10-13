/// Real MSE (Media Source Extensions) tail-following `VideoSink` for
/// Flutter web. Bit-for-bit sink counterpart to the reference player;
/// consumes a [TwaiAvatarPlayerController] and drives an
/// HTMLVideoElement + MediaSource + SourceBuffer trio.
///
/// **Flutter web only** — construction on other platforms throws
/// `UnsupportedError`. See [WebMseStreamSink] for the multi-platform
/// dispatch pattern.
///
/// Design: see `docs/sink_streaming_scoping.md` §4 Phase 1 and §5.
library;

export 'src/web_mse_stream_sink.dart' show WebMseStreamSink;
