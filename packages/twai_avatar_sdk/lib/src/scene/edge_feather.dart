import 'package:flutter/widgets.dart';

/// Softens the edges of a widget with a dual-axis alpha mask so it
/// blends into whatever's behind it — the SDK equivalent of edu's
/// per-scene `mask-image` fade
/// ([ImmersiveAvatarStage.vue:351-362](../../../../../2wai-edu/components/scopes/chat/ImmersiveAvatarStage.vue)).
///
/// Wraps [child] in nested [ShaderMask]s: one horizontal (fades the
/// left + right edges to transparent), one vertical (fades the
/// bottom edge). Result: a cutout that dissolves into the scene
/// plate instead of showing a hard rectangle around the avatar.
///
/// # When to use
///
/// - The avatar's live feed sits on top of a scene plate + you don't
///   want a visible frame around the mouth of the mask
/// - Both feeds are transparent-alpha and you want the leaked
///   background to soften rather than punch through
///
/// # When NOT to use
///
/// - The feed is intentionally a portrait tile (product cards etc.)
///   where you want the crisp rectangle
/// - You already control edge softening via a texture on the
///   underlying video source
///
/// # Parameters
///
/// - [horizontalFade] — how far in from each side the fade starts,
///   as a fraction `[0, 0.5]`. `0.11` = fade begins 11% in from the
///   left edge (mirrored on the right). Default matches edu.
/// - [bottomFadeStart] — where the bottom fade begins, as a fraction
///   `[0, 1]`. `0.8` = fully-opaque from top to 80%, fading to zero
///   at 100%. Default matches edu.
class TwaiEdgeFeather extends StatelessWidget {
  const TwaiEdgeFeather({
    super.key,
    required this.child,
    this.horizontalFade = 0.11,
    this.bottomFadeStart = 0.8,
  });

  final Widget child;
  final double horizontalFade;
  final double bottomFadeStart;

  @override
  Widget build(BuildContext context) {
    final hf = horizontalFade.clamp(0.0, 0.499);
    final bfs = bottomFadeStart.clamp(0.0, 1.0);

    // Horizontal mask (outer): opaque middle, transparent edges.
    // Vertical mask (inner, closer to child): opaque top, transparent bottom.
    return ShaderMask(
      shaderCallback: (Rect bounds) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: const [
          Color(0x00FFFFFF),
          Color(0xFFFFFFFF),
          Color(0xFFFFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: [0.0, hf, 1.0 - hf, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: ShaderMask(
        shaderCallback: (Rect bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0.0, bfs, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: child,
      ),
    );
  }
}
