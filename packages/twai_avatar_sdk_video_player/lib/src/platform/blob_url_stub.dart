import 'dart:typed_data';

/// Stub for non-web platforms. The video sinks should never call into
/// this — they branch on `kIsWeb` and use file-path playback on IO
/// targets. If this ever throws, the conditional-import setup is wrong.
String createObjectUrl(Uint8List bytes) =>
    throw UnsupportedError('createObjectUrl is web-only');

void revokeObjectUrl(String url) {
  // No-op on non-web. Reachable only if someone calls revoke without
  // first calling create — also a logic error, but harmless to ignore.
}
