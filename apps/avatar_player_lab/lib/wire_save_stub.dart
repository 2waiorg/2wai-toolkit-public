// Stub — only reached on platforms that have neither dart:html nor
// dart:io. Every real Flutter target has one or the other, so this
// path is unreachable in practice. Kept so conditional imports type-check.

import 'dart:typed_data';

import 'package:video_player/video_player.dart';

import 'wire_save.dart';

Future<SavedWireCapture> platformSaveWireCapture(
  Uint8List bytes, {
  String? suggestedName,
}) async {
  throw UnsupportedError(
    'saveWireCapture: no platform-specific implementation available',
  );
}

Future<VideoPlayerController> platformControllerForBytes(Uint8List bytes) async {
  throw UnsupportedError(
    'controllerForBytes: no platform-specific implementation available',
  );
}
