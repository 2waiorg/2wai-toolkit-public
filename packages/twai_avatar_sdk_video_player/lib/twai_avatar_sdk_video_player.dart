/// 2wai Avatar SDK — video_player + path_provider backed video sinks.
///
/// One of two interchangeable video backends:
/// - `twai_avatar_sdk_video_player` (this package) — smaller binary,
///   official Flutter team plugin, federated platform implementations
///   (incl. video_player_win for Windows).
/// - `twai_avatar_sdk_media_kit` — libmpv-backed, single backend across
///   every platform including Linux and (with extra setup) web.
///
/// Both implement the same [VideoSink] interface from
/// `package:twai_avatar_sdk`. App code that uses the interface is
/// portable across both — the sink construction is the only difference.
library;

export 'src/mse_stream/mse_stream_video_sink.dart'
    show VideoPlayerMseStreamSink;
// Web-only true-streaming sink. Uses MediaSource Extensions to feed
// fMP4 fragments directly into a <video> element as they arrive on
// the WebSocket — first-frame latency ~1-2s vs ~9s for the buffered
// sink. Throws on construction on native targets (use the buffered
// sink there instead).
export 'src/mse_live/mse_live_sink.dart' show VideoPlayerMseLiveSink;
export 'src/pipeline_v13/pipeline_v13_video_sink.dart'
    show VideoPlayerPipelineV13Sink;
