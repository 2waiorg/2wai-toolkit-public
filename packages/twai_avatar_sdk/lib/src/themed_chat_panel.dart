import 'package:flutter/material.dart';

import 'player_avatar_theme.dart';

/// A chat-panel container that applies a [PlayerAvatarTheme] to its
/// subtree. Publishes the theme via [PlayerAvatarTheme.of] so any
/// descendant widget can look it up, and paints the surface layers
/// (background + optional texture + optional vignette + optional
/// gilded top rule).
///
/// Everything on the theme is optional; unspecified slots fall back
/// to unthemed rendering (equivalent to a plain [Container] with a
/// child). This is what preserves the "SDK ships opinionated
/// defaults but every feature is optional and configurable" rule.
///
/// # Composition
///
/// ```
/// TwaiThemedChatPanel                       ← this widget
///   ├── background layer (panelBg / dark)
///   ├── texture layer     (panelTextureUrl · blend · opacity)
///   ├── vignette layer    (vignetteColor)
///   ├── gilded top rule   (accent · motif · dividerColor)
///   └── child             (your chat list + composer)
/// ```
///
/// Modeled after `2waiorg/2wai-edu:components/scopes/chat/ThemedChatPanel.vue`
/// (see `reference_2wai_edu_repo.md` §B1). Vue uses CSS custom
/// properties; Flutter uses the typed [PlayerAvatarTheme] as an
/// inherited widget.
class TwaiThemedChatPanel extends StatelessWidget {
  const TwaiThemedChatPanel({
    super.key,
    required this.theme,
    required this.child,
    this.brightness,
    this.showGildedRule = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  /// The theme to apply. See [PlayerAvatarTheme].
  final PlayerAvatarTheme theme;

  /// Panel contents (chat log + composer, typically).
  final Widget child;

  /// Which brightness variant of [PlayerAvatarTheme.panelBg] to use.
  /// Null → read from `Theme.of(context).brightness`. Explicit is
  /// useful when the ambient theme doesn't match the panel context
  /// (e.g. a dark panel embedded on a light page).
  final Brightness? brightness;

  /// Whether to render the top gilded rule + motif. Turn off when
  /// composing multiple themed panels vertically (only the topmost
  /// should have the rule) or when the ambient design doesn't want it.
  final bool showGildedRule;

  /// Padding around [child] inside the themed surface. Doesn't affect
  /// the background / texture / vignette layers — those fill the
  /// container edge-to-edge.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final b = brightness ?? Theme.of(context).brightness;
    final panelColor = theme.resolvePanelBg(b);
    final tex = theme.panelTextureUrl;
    final vignette = theme.vignetteColor;

    // Layered fill: background → texture → vignette → gilded rule → child.
    // The Stack orders layers bottom-up; a Positioned.fill on each fill
    // layer means the child sits on top with normal layout.
    return PlayerAvatarThemeScope(
      theme: theme,
      child: Container(
        color: panelColor,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (tex != null && tex.isNotEmpty)
              Positioned.fill(
                child: TwaiTextureOverlay(
                  imageUrl: tex,
                  blend: theme.panelTextureBlend,
                  opacity: theme.panelTextureOpacity,
                ),
              ),
            if (vignette != null)
              Positioned.fill(child: TwaiVignette(color: vignette)),
            Column(
              children: [
                if (showGildedRule)
                  TwaiGildedRule(
                    accent: theme.accent,
                    dividerColor: theme.dividerColor,
                    motif: theme.motif,
                  ),
                Expanded(
                  child: Padding(padding: padding, child: child),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A texture image (papyrus, wood grain, canvas, etc.) drawn over
/// whatever's behind it with a configurable blend + opacity. Prefers
/// [Image.network] but the URL can be any image source Flutter's
/// network image resolver handles.
///
/// Standalone widget — usable outside [TwaiThemedChatPanel] when an
/// app wants texture on some other surface. Consumed by the panel via
/// the theme's `panelTextureUrl`.
class TwaiTextureOverlay extends StatelessWidget {
  const TwaiTextureOverlay({
    super.key,
    required this.imageUrl,
    this.blend = BlendMode.multiply,
    this.opacity = 0.24,
    this.fit = BoxFit.cover,
  });

  final String imageUrl;
  final BlendMode blend;
  final double opacity;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: ColorFiltered(
          // ColorFiltered with a fully-opaque color at the same blend
          // mode as ImageFilter would apply — here we just let the
          // image paint through with the opacity envelope. The blend
          // hint is future-proofing when we swap to a proper
          // BlendMode.dstIn / -Over sandwich.
          colorFilter: ColorFilter.mode(Colors.transparent, blend),
          child: Image.network(
            imageUrl,
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// Radial-gradient vignette — darkens the panel edges to focus
/// attention on messages in the center. Painted at full IgnorePointer
/// opacity but the [color]'s alpha channel controls intensity.
class TwaiVignette extends StatelessWidget {
  const TwaiVignette({super.key, required this.color, this.intensity = 0.4});

  final Color color;

  /// How dark the edges get relative to [color]'s alpha. `[0, 1]`.
  /// Default `0.4` matches edu's default parchment vignette.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [
              Colors.transparent,
              color.withValues(alpha: intensity.clamp(0.0, 1.0)),
            ],
            radius: 0.9,
            stops: const [0.55, 1.0],
          ),
        ),
      ),
    );
  }
}

/// A centered gilded horizontal rule with an optional motif widget.
/// Mirrors the top divider on Vue's ThemedChatPanel — a hairline
/// [accent]-colored line with a decorative glyph centered on it.
class TwaiGildedRule extends StatelessWidget {
  const TwaiGildedRule({
    super.key,
    this.accent,
    this.dividerColor,
    this.motif,
    this.height = 32,
  });

  final Color? accent;
  final Color? dividerColor;

  /// Optional widget centered on the rule (a lotus glyph, laurel,
  /// symbol, etc.). Null → renders as a plain hairline rule.
  final Widget? motif;

  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = dividerColor ?? scheme.outlineVariant;
    final glyph = accent ?? scheme.secondary;

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Container(height: 1, color: line)),
          if (motif != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: glyph),
                child: motif!,
              ),
            ),
          Expanded(child: Container(height: 1, color: line)),
        ],
      ),
    );
  }
}
