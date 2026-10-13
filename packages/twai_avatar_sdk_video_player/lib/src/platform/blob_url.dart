// Conditional-import barrel. Dart picks the right implementation based
// on which platform libraries are available at compile time:
//
//   - Web build (dart.library.html present)  → blob_url_web.dart
//   - Native/IO build                         → blob_url_stub.dart
//
// Callers always import this file and get the right `createObjectUrl`
// / `revokeObjectUrl` for their target. Branch on `kIsWeb` in the
// caller before invoking — the stub throws if reached on non-web.
export 'blob_url_stub.dart'
    if (dart.library.html) 'blob_url_web.dart';
