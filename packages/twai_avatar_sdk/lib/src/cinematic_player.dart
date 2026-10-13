import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Full-viewport video escape for reward clips, transition films,
/// or any cinematic moment that shouldn't inherit the immersive
/// stage's clip / z-stack hierarchy. Ports 2wai-edu's
/// [CinematicPlayer.vue](../../../../2wai-edu/components/scopes/chat/CinematicPlayer.vue)
/// pattern.
///
/// # Usage patterns
///
/// **1. Push as a route (full-viewport, back-button dismissal):**
///
/// ```dart
/// Navigator.of(context).push(MaterialPageRoute(
///   builder: (_) => TwaiCinematicPlayer(
///     videoUrl: rewardMp4Url,
///     onComplete: () => Navigator.of(context).maybePop(),
///   ),
///   fullscreenDialog: true,
/// ));
/// ```
///
/// **2. Mount inside an [Overlay] entry** (composed with your own
/// timing or fade-in/out):
///
/// ```dart
/// final entry = OverlayEntry(builder: (ctx) => TwaiCinematicPlayer(
///   videoUrl: transitionFilmUrl,
///   onComplete: () { entry.remove(); },
///   dismissOnTap: false,
/// ));
/// Overlay.of(context).insert(entry);
/// ```
///
/// **3. Convenience helper — `show()`** (pushes a fullscreen dialog
/// route + auto-pops on completion):
///
/// ```dart
/// await TwaiCinematicPlayer.show(context, videoUrl: rewardMp4Url);
/// ```
class TwaiCinematicPlayer extends StatefulWidget {
  const TwaiCinematicPlayer({
    super.key,
    required this.videoUrl,
    this.onComplete,
    this.autoplay = true,
    this.dismissOnTap = true,
    this.background = const Color(0xFF000000),
    this.fit = BoxFit.contain,
  });

  /// HTTP(S) URL of the video to play.
  final String videoUrl;

  /// Called when the video reaches its end. Not called on user-
  /// initiated dismissal (tap when [dismissOnTap] is on) — hook the
  /// route pop for that.
  final VoidCallback? onComplete;

  /// Whether the video starts playing on mount. Default true. When
  /// false, the caller must expose their own play trigger (e.g. via
  /// a GlobalKey and a public `play()` method — a future slice can
  /// add this if a customer needs it).
  final bool autoplay;

  /// Whether tapping anywhere on the video dismisses it. Default
  /// true. Passes through by returning `false` from the tap handler
  /// so a parent Navigator can pop.
  final bool dismissOnTap;

  /// Full-viewport background painted behind the video (visible when
  /// [fit] letterboxes). Default solid black.
  final Color background;

  /// How the video fills the viewport. [BoxFit.contain] (default)
  /// letterboxes to preserve aspect. [BoxFit.cover] crops to fill.
  final BoxFit fit;

  /// Convenience helper — pushes a fullscreen dialog route hosting
  /// the cinematic player, auto-pops when the video ends. Returns a
  /// [Future] that resolves after the pop.
  static Future<void> show(
    BuildContext context, {
    required String videoUrl,
    bool autoplay = true,
    bool dismissOnTap = true,
    Color background = const Color(0xFF000000),
    BoxFit fit = BoxFit.contain,
  }) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (routeCtx) => TwaiCinematicPlayer(
        videoUrl: videoUrl,
        autoplay: autoplay,
        dismissOnTap: dismissOnTap,
        background: background,
        fit: fit,
        onComplete: () {
          if (Navigator.of(routeCtx).canPop()) {
            Navigator.of(routeCtx).pop();
          }
        },
      ),
    ));
  }

  @override
  State<TwaiCinematicPlayer> createState() => _TwaiCinematicPlayerState();
}

class _TwaiCinematicPlayerState extends State<TwaiCinematicPlayer> {
  VideoPlayerController? _controller;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _init(widget.videoUrl);
  }

  @override
  void didUpdateWidget(covariant TwaiCinematicPlayer old) {
    super.didUpdateWidget(old);
    if (widget.videoUrl != old.videoUrl) {
      _dispose();
      _init(widget.videoUrl);
    }
  }

  Future<void> _init(String url) async {
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      // Fire onComplete so an outer route can pop rather than
      // hanging on a black screen.
      _fireOnComplete();
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    c.addListener(_onControllerTick);
    if (widget.autoplay) {
      await c.play();
    }
    setState(() {
      _controller = c;
      _fired = false;
    });
  }

  void _onControllerTick() {
    final c = _controller;
    if (c == null || _fired) return;
    final v = c.value;
    // Fire once when the video reaches its end. `isCompleted` isn't
    // always accurate across platforms; position-at-end is more
    // reliable. Guard on isPlaying == false so we don't fire during
    // scrubbing / seeking mid-playback.
    if (v.duration > Duration.zero &&
        v.position >= v.duration &&
        !v.isPlaying) {
      _fireOnComplete();
    }
  }

  void _fireOnComplete() {
    if (_fired) return;
    _fired = true;
    widget.onComplete?.call();
  }

  Future<void> _dispose() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    c.removeListener(_onControllerTick);
    await c.dispose();
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    Widget body;
    if (c == null || !c.value.isInitialized) {
      body = const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      body = Center(
        child: FittedBox(
          fit: widget.fit,
          child: SizedBox(
            width: c.value.size.width,
            height: c.value.size.height,
            child: VideoPlayer(c),
          ),
        ),
      );
    }
    final stack = ColoredBox(color: widget.background, child: body);
    if (!widget.dismissOnTap) return stack;
    return GestureDetector(
      onTap: _fireOnComplete,
      behavior: HitTestBehavior.opaque,
      child: stack,
    );
  }
}
