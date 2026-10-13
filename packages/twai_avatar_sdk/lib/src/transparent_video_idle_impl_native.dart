import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Native (non-web) build of the transparent-video idle. Alpha
/// compositing isn't reliable through `video_player` on non-web
/// targets today — no `preservesPitch`/`alphaChannel` accessor and
/// the platform surface embedding doesn't punch alpha through to the
/// underlying scene. So the native impl renders the [fallbackVideoUrl]
/// opaquely (looped, muted), matching the existing [NetworkVideoIdle]
/// behavior.
///
/// If [fallbackVideoUrl] is null the widget renders as a transparent
/// [SizedBox.expand] — the caller's scaffold background shows
/// through, which at least won't paint a jarring black rectangle.
///
/// When Flutter native gains a reliable alpha-video path (or when we
/// swap to a native alpha-aware plugin like `flutter_avif` or a
/// media_kit alpha variant), this impl swaps in place — the public
/// [TransparentVideoIdle] surface doesn't change.
Widget buildTransparentVideoIdle({
  required String? hevcAlphaMovUrl,
  required String? vp9AlphaWebmUrl,
  required String? fallbackVideoUrl,
  required BoxFit fit,
}) {
  if (fallbackVideoUrl == null || fallbackVideoUrl.isEmpty) {
    return const SizedBox.expand();
  }
  return _NativeOpaqueLoopingVideo(url: fallbackVideoUrl, fit: fit);
}

class _NativeOpaqueLoopingVideo extends StatefulWidget {
  const _NativeOpaqueLoopingVideo({required this.url, required this.fit});
  final String url;
  final BoxFit fit;

  @override
  State<_NativeOpaqueLoopingVideo> createState() =>
      _NativeOpaqueLoopingVideoState();
}

class _NativeOpaqueLoopingVideoState
    extends State<_NativeOpaqueLoopingVideo> {
  VideoPlayerController? _controller;
  String? _initializedFor;

  @override
  void initState() {
    super.initState();
    _init(widget.url);
  }

  @override
  void didUpdateWidget(covariant _NativeOpaqueLoopingVideo old) {
    super.didUpdateWidget(old);
    if (widget.url != old.url) {
      _disposeController();
      _init(widget.url);
    }
  }

  Future<void> _init(String url) async {
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      return;
    }
    if (!mounted || _initializedFor != null && _initializedFor != url) {
      await c.dispose();
      return;
    }
    await c.setLooping(true);
    await c.setVolume(0);
    await c.play();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() {
      _controller = c;
      _initializedFor = url;
    });
  }

  void _disposeController() {
    // ignore: discarded_futures
    _controller?.dispose();
    _controller = null;
    _initializedFor = null;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox.expand();
    }
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
