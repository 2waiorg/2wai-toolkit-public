// Cross-platform save + preview helpers for the wire recorder buffer.
//
// Web: triggers a browser download via a Blob + anchor click.
// Native (iOS / Android / desktop): writes to the app's documents dir
// via path_provider + dart:io.
//
// Conditional imports pick the right implementation at compile time so
// nothing web-only ever lands in a native build (and vice versa).

import 'dart:typed_data';

import 'package:video_player/video_player.dart';

import 'wire_save_stub.dart'
    if (dart.library.html) 'wire_save_web.dart'
    if (dart.library.io) 'wire_save_io.dart';

/// Result of a save call. On web, `path` is the blob URL used to
/// trigger the download; on native it's the on-disk file path.
class SavedWireCapture {
  final String path;
  final int byteLength;
  const SavedWireCapture({required this.path, required this.byteLength});
}

/// Save the captured wire bytes to a platform-appropriate location.
/// Returns the resulting file path (native) or blob URL (web).
Future<SavedWireCapture> saveWireCapture(
  Uint8List bytes, {
  String? suggestedName,
}) =>
    platformSaveWireCapture(bytes, suggestedName: suggestedName);

/// Build a VideoPlayerController that plays back the given bytes.
/// Native: writes a temp file first, returns `.file()` controller.
/// Web: returns `.networkUrl()` controller pointed at a blob URL.
Future<VideoPlayerController> controllerForBytes(Uint8List bytes) =>
    platformControllerForBytes(bytes);
