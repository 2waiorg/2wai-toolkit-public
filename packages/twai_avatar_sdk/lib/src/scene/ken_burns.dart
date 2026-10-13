import 'package:flutter/widgets.dart';

/// Slow scale + translate animation applied to a scene plate — the
/// classic "Ken Burns" documentary effect that adds subtle depth to
/// an otherwise-static backdrop. Ported from edu's per-scene plate
/// animation ([ImmersiveAvatarStage.vue:324-330](../../../../../2wai-edu/components/scopes/chat/ImmersiveAvatarStage.vue)).
///
/// # Behavior
///
/// - Runs on a loop, forward + reverse, so the animation is
///   symmetric and never appears to "reset".
/// - Duration defaults to 36 seconds — long enough that the motion
///   is only perceptible in peripheral vision, matching edu.
/// - **Respects `MediaQuery.disableAnimations`** (accessibility /
///   `prefers-reduced-motion`) — when set, renders the child at
///   scale=1.0, no animation running. Zero CPU cost in that state.
///
/// # Parameters
///
/// - [child] — the plate (image or looping video) to animate.
/// - [duration] — length of one direction of the cycle. Full cycle
///   is `2 × duration` (forward + reverse). Default 36s.
/// - [scaleStart] — starting scale (typically slight zoom, `1.04`
///   default so the child is already slightly larger than parent).
/// - [scaleEnd] — ending scale (`1.09` default = slow zoom-in).
/// - [alignment] — anchor for the scale transform. Center is
///   natural for most scenes; try `Alignment.bottomCenter` if the
///   subject sits low in the frame.
class TwaiKenBurnsParallax extends StatefulWidget {
  const TwaiKenBurnsParallax({
    super.key,
    required this.child,
    this.duration = const Duration(seconds: 36),
    this.scaleStart = 1.04,
    this.scaleEnd = 1.09,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Duration duration;
  final double scaleStart;
  final double scaleEnd;
  final Alignment alignment;

  @override
  State<TwaiKenBurnsParallax> createState() =>
      _TwaiKenBurnsParallaxState();
}

class _TwaiKenBurnsParallaxState extends State<TwaiKenBurnsParallax>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    // Kick off the reverse-on-completion cycle. Guarded so the
    // controller doesn't tick when the app requests reduced motion
    // (checked lazily in didChangeDependencies so the MediaQuery is
    // available).
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _controller.stop();
      _controller.value = 0.0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant TwaiKenBurnsParallax old) {
    super.didUpdateWidget(old);
    if (widget.duration != old.duration) {
      _controller.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      // Freeze at scaleStart — subtle zoom, no motion.
      return Transform.scale(
        scale: widget.scaleStart,
        alignment: widget.alignment,
        child: widget.child,
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final scale = widget.scaleStart +
            (widget.scaleEnd - widget.scaleStart) * t;
        return Transform.scale(
          scale: scale,
          alignment: widget.alignment,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
