// Conditional-import barrel for the MSE Live sink.
//
//   Web build (dart.library.html present)  → mse_live_sink_web.dart
//   Native/IO build                         → mse_live_sink_stub.dart
//
// The stub throws on construction so a native customer who accidentally
// picks this sink gets a clear error message instead of a cryptic
// js_interop runtime failure.
export 'mse_live_sink_stub.dart'
    if (dart.library.html) 'mse_live_sink_web.dart';
