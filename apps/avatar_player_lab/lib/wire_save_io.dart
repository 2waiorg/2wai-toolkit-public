// Native implementation — writes to the app's documents dir via
// path_provider + dart:io. Only compiled when `dart.library.io` is
// available.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'wire_save.dart';

Future<SavedWireCapture> platformSaveWireCapture(
  Uint8List bytes, {
  String? suggestedName,
}) async {
  final name = suggestedName ?? _defaultName();
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return SavedWireCapture(path: file.path, byteLength: bytes.length);
}

Future<VideoPlayerController> platformControllerForBytes(Uint8List bytes) async {
  // VideoPlayer on native needs a real file:// URI. Write a temp file
  // with a unique name so multiple previews in a session don't clobber
  // each other.
  final dir = await getTemporaryDirectory();
  final name = 'wire-preview-${DateTime.now().microsecondsSinceEpoch}.mp4';
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes, flush: true);
  return VideoPlayerController.file(file);
}

String _defaultName() {
  final now = DateTime.now();
  String pad(int v) => v.toString().padLeft(2, '0');
  return 'wire-${now.year}${pad(now.month)}${pad(now.day)}'
      '-${pad(now.hour)}${pad(now.minute)}${pad(now.second)}.mp4';
}
