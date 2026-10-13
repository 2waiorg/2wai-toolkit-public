// Platform conditional import — web gets the real MediaSource
// implementation; other platforms get a stub that throws on
// construction. The sink class in `web_mse_stream_sink.dart` selects
// via `dart.library.js_interop` presence.
export 'mse_impl_stub.dart'
    if (dart.library.js_interop) 'mse_impl_web.dart';
