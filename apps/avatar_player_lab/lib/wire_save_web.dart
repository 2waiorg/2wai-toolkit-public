// Web implementation — Blob + anchor click for download, blob URL for preview.
// Only compiled when `dart.library.html` is available.
//
// Uses package:web + dart:js_interop (dart:html was deprecated in
// favor of these as of 2026).

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'wire_save.dart';

Future<SavedWireCapture> platformSaveWireCapture(
  Uint8List bytes, {
  String? suggestedName,
}) async {
  final name = suggestedName ?? _defaultName();
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'video/mp4'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // Deliberately don't revokeObjectURL(url) — the browser needs it live
  // long enough for the download to start. Tab GC cleans it up.
  return SavedWireCapture(path: name, byteLength: bytes.length);
}

Future<VideoPlayerController> platformControllerForBytes(Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'video/mp4'),
  );
  final url = web.URL.createObjectURL(blob);
  return VideoPlayerController.networkUrl(Uri.parse(url));
}

String _defaultName() {
  final now = DateTime.now();
  String pad(int v) => v.toString().padLeft(2, '0');
  return 'wire-${now.year}${pad(now.month)}${pad(now.day)}'
      '-${pad(now.hour)}${pad(now.minute)}${pad(now.second)}.mp4';
}
