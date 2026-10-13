import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Web build of the transparent-video idle. Constructs a browser
/// `<video>` element with a source list ordered so the browser picks
/// the format it can decode with alpha:
///
/// 1. `hevcAlphaMovUrl` (HEVC + alpha, `.mov`) — Safari 13+ on
///    macOS / iOS. Chrome / Firefox skip it (`canPlayType` returns
///    empty), moving to the next source.
/// 2. `vp9AlphaWebmUrl` (VP9 + alpha, `.webm`) — Chrome / Firefox /
///    Edge. Safari skips (no VP9 alpha support).
/// 3. `fallbackVideoUrl` — plain opaque MP4 as a last-resort so the
///    element renders SOMETHING even on a browser that can't decode
///    either alpha format (or when the caller only wired the fallback).
///
/// The element autoplays muted + loops + is `playsInline` — the
/// standard idle-video shape. Alpha compositing happens natively in
/// the browser: transparent pixels in the video source show whatever's
/// beneath the platform view (typically a `TwaiSceneStage`'s plate
/// layer).
///
/// Registers a unique platform-view id per instance so multiple
/// TransparentVideoIdle widgets on one page don't collide.
Widget buildTransparentVideoIdle({
  required String? hevcAlphaMovUrl,
  required String? vp9AlphaWebmUrl,
  required String? fallbackVideoUrl,
  required BoxFit fit,
}) {
  final sources = <_SourceSpec>[
    if (hevcAlphaMovUrl != null && hevcAlphaMovUrl.isNotEmpty)
      _SourceSpec(hevcAlphaMovUrl, 'video/quicktime; codecs="hvc1"'),
    if (vp9AlphaWebmUrl != null && vp9AlphaWebmUrl.isNotEmpty)
      _SourceSpec(vp9AlphaWebmUrl, 'video/webm; codecs="vp9"'),
    if (fallbackVideoUrl != null && fallbackVideoUrl.isNotEmpty)
      _SourceSpec(fallbackVideoUrl, 'video/mp4'),
  ];
  if (sources.isEmpty) {
    return const SizedBox.expand();
  }
  return _TransparentVideoView(sources: sources, fit: fit);
}

class _SourceSpec {
  const _SourceSpec(this.src, this.type);
  final String src;
  final String type;
}

class _TransparentVideoView extends StatefulWidget {
  const _TransparentVideoView({required this.sources, required this.fit});
  final List<_SourceSpec> sources;
  final BoxFit fit;

  @override
  State<_TransparentVideoView> createState() =>
      _TransparentVideoViewState();
}

class _TransparentVideoViewState extends State<_TransparentVideoView> {
  static int _seq = 0;
  late final String _viewId;

  @override
  void initState() {
    super.initState();
    _viewId = 'twai-transparent-video-${_seq++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (_) {
      final video = web.HTMLVideoElement()
        ..autoplay = true
        ..muted = true
        ..loop = true
        ..controls = false
        ..playsInline = true
        ..setAttribute('playsinline', '')
        // Fill the platform view; the Flutter FittedBox handles outer
        // aspect. object-fit here is `cover` to match the sink's
        // default framing behavior.
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = _cssObjectFit(widget.fit);
      for (final s in widget.sources) {
        final source = web.HTMLSourceElement()
          ..src = s.src
          ..type = s.type;
        video.appendChild(source);
      }
      // The browser needs an explicit .load() after appending sources
      // programmatically — the initial autoplay only kicks after the
      // source list is committed. Harmless if it fails (autoplay may
      // still be rejected + retried on gesture).
      video.load();
      return video;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewId);
  }
}

String _cssObjectFit(BoxFit fit) {
  switch (fit) {
    case BoxFit.cover:
      return 'cover';
    case BoxFit.contain:
      return 'contain';
    case BoxFit.fill:
      return 'fill';
    case BoxFit.fitWidth:
    case BoxFit.fitHeight:
      return 'contain';
    case BoxFit.none:
    case BoxFit.scaleDown:
      return 'none';
  }
}
