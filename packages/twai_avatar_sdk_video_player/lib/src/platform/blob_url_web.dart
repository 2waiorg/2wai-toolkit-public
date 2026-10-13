// Web-only Blob URL helpers. Reachable only when `dart.library.html`
// is available — non-web targets see blob_url_stub.dart via conditional
// import.
//
// Pattern mirrors penthouse's reference implementation at
// `clg_penthouse_pets/frontend/src/utils/blobVideoCache.ts`:
//   1. Wrap bytes in a `Blob` with the MP4 MIME type
//   2. Mint a `blob:<uuid>` URL via `URL.createObjectURL`
//   3. Caller hands the URL to the `<video>` element (in our case via
//      `VideoPlayerController.networkUrl`)
//   4. Caller MUST call `revokeObjectURL` when done or the browser
//      keeps the backing bytes in memory forever
//
// Penthouse adds IndexedDB persistence + refcounted URL ownership for
// their idle-clip caching use case. We don't need either — per chat
// turn we produce one MP4, play it, and revoke when the next turn
// arrives. Single owner, no cache.
//
// Uses `package:web` + `dart:js_interop` (the modern Dart web binding
// that replaced `dart:html`).

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Wrap [bytes] in an in-memory `video/mp4` Blob and return a
/// `blob:` URL the browser can serve to a `<video>` element. Pair
/// every call with a later [revokeObjectUrl] on the returned string
/// to avoid leaking browser memory.
String createObjectUrl(Uint8List bytes) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'video/mp4'),
  );
  return web.URL.createObjectURL(blob);
}

/// Tell the browser to free the Blob behind [url]. Safe to call with
/// a URL that's already been revoked (browser ignores it).
void revokeObjectUrl(String url) {
  web.URL.revokeObjectURL(url);
}
