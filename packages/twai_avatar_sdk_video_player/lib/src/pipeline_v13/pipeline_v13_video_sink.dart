import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:video_player/video_player.dart';

import '../platform/blob_url.dart' as blob;

/// [VideoSink] for Adapter 2 (v1.3 `POST /chat` → MP4).
///
/// Each turn produces one complete MP4 on [ChatSession.videoBytes]. The
/// sink writes that MP4 to a temp file, builds a fresh
/// [VideoPlayerController.file], initializes it, and plays it. The
/// previous controller (and its temp file) are disposed/deleted once
/// the new one is running.
///
/// Cross-platform: native targets write to a temp file, web target
/// mints a `blob:` URL via `URL.createObjectURL`. Same controller
/// lifecycle either way.
class VideoPlayerPipelineV13Sink implements VideoSink {
  VideoPlayerPipelineV13Sink();

  @override
  ValueListenable<bool> get isRenderingContent => alwaysNotRendering;

  final _controller = ValueNotifier<VideoPlayerController?>(null);
  StreamSubscription<Uint8List>? _sub;
  // File path on native, `blob:` URL on web. Released via [_disposeSource].
  String? _currentSource;
  bool _attached = false;

  @override
  Future<void> attach(ChatSession session) async {
    if (_attached) {
      throw StateError('VideoPlayerPipelineV13Sink.attach called twice');
    }
    _attached = true;
    _sub = session.videoBytes.listen(_onMp4Chunk);
  }

  Future<void> _onMp4Chunk(Uint8List bytes) async {
    // Platform-branch only on the "make these bytes playable" step.
    final String source;
    final VideoPlayerController fresh;
    if (kIsWeb) {
      source = blob.createObjectUrl(bytes);
      fresh = VideoPlayerController.networkUrl(Uri.parse(source));
    } else {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/twai_v13_${DateTime.now().microsecondsSinceEpoch}.mp4',
      );
      await file.writeAsBytes(bytes, flush: true);
      source = file.path;
      fresh = VideoPlayerController.file(file);
    }

    final old = _controller.value;
    final oldSource = _currentSource;
    _currentSource = source;

    try {
      await fresh.initialize();
    } catch (e) {
      // Failed to decode this MP4 — drop the new source, keep the
      // previous controller. Native: delete the temp file. Web: revoke
      // the blob URL.
      await fresh.dispose();
      _disposeSource(source);
      _currentSource = oldSource;
      return;
    }

    // Explicit non-loop — see VideoPlayerMseStreamSink comment.
    await fresh.setLooping(false);
    _controller.value = fresh;
    await fresh.play();

    // Now safe to release the previous controller + its source.
    await old?.dispose();
    _disposeSource(oldSource);
  }

  /// Release a previously-active source. Native: delete the temp MP4
  /// file. Web: revoke the blob URL so the browser frees the in-memory
  /// bytes.
  void _disposeSource(String? source) {
    if (source == null) return;
    if (kIsWeb) {
      blob.revokeObjectUrl(source);
    } else {
      // ignore: unawaited_futures
      File(source).delete().catchError((_) => File(source));
    }
  }

  @override
  Widget buildWidget() => _PipelineV13VideoView(controller: _controller);

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    final c = _controller.value;
    _controller.value = null;
    await c?.dispose();
    final s = _currentSource;
    _currentSource = null;
    _disposeSource(s);
    _controller.dispose();
  }
}

class _PipelineV13VideoView extends StatelessWidget {
  const _PipelineV13VideoView({required this.controller});

  final ValueListenable<VideoPlayerController?> controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: controller,
      builder: (context, c, _) {
        if (c == null || !c.value.isInitialized) {
          return const ColoredBox(
            color: Color(0xFF111111),
            child: Center(
              child: Text(
                'Waiting for first reply…',
                style: TextStyle(color: Color(0xFFAAAAAA)),
              ),
            ),
          );
        }
        return ColoredBox(
          color: const Color(0xFF000000),
          child: Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
        );
      },
    );
  }
}
