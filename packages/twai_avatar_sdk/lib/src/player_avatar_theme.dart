import 'package:flutter/material.dart';

/// Per-avatar visual theming — the customer-facing shape that turns a
/// generic chat panel into a papyrus scroll for Cleopatra, a wooden
/// tablet for a historical persona, or a neon HUD for a sci-fi one.
///
/// Immutable value type. Every field is nullable so callers can
/// override only what they care about; widgets consume the theme via
/// [InheritedWidget] and fall back to sensible defaults when a slot
/// is null (unthemed rendering ≈ what the SDK shipped before B1-B3).
///
/// Modeled after `2waiorg/2wai-edu:composables/useAvatarThemes.ts`'s
/// `AvatarChatTheme` (see `reference_2wai_edu_repo.md`). The Vue side
/// implements this as a CSS custom-property contract; Flutter's
/// equivalent is this typed object propagated through the widget
/// tree.
@immutable
class PlayerAvatarTheme {
  const PlayerAvatarTheme({
    // ─── panel surface ───
    this.panelBg,
    this.panelBgDark,
    this.panelTextureUrl,
    this.panelTextureBlend = BlendMode.multiply,
    this.panelTextureOpacity = 0.24,
    this.vignetteColor,
    // ─── typography ───
    this.fontBody,
    this.fontDisplay,
    // ─── ornament ───
    this.motif,
    this.accent,
    this.dividerColor,
    // ─── message bubbles ───
    this.aiBubbleBg,
    this.aiBubbleFg,
    this.userBubbleBg,
    this.userBubbleFg,
  });

  /// Panel background in light mode. Null → transparent (defers to
  /// the ambient Material / Cupertino theme).
  final Color? panelBg;

  /// Panel background in dark mode. Null → falls back to [panelBg].
  final Color? panelBgDark;

  /// Optional texture image URL (papyrus, wood grain, etc.) rendered
  /// on top of the panel background. Blend + opacity control the mix.
  final String? panelTextureUrl;

  /// Blend mode for the texture overlay. `BlendMode.multiply` (dark
  /// mode) or `BlendMode.overlay` (light mode) are typical.
  final BlendMode panelTextureBlend;

  /// Texture overlay opacity in `[0.0, 1.0]`. Edu's default is 0.24
  /// for parchment on dark; feel free to nudge per texture.
  final double panelTextureOpacity;

  /// Radial-gradient vignette color. Darkens the panel edges to
  /// focus attention on the messages. Null → no vignette.
  final Color? vignetteColor;

  /// Body-copy TextStyle (message text, composer input). Null →
  /// ambient theme.
  final TextStyle? fontBody;

  /// Display TextStyle (headings, name plate, top motif). Null →
  /// ambient theme.
  final TextStyle? fontDisplay;

  /// Optional decorative widget centered on the panel's top rule
  /// (e.g. a lotus glyph for Cleopatra, a laurel for a Roman
  /// persona). Rendered inside the gilded rule slot.
  final Widget? motif;

  /// Accent / gilded-rule color. Also usable as bubble ring color.
  /// Null → theme's `colorScheme.secondary`.
  final Color? accent;

  /// Divider line color. Null → subtle default.
  final Color? dividerColor;

  /// AI message bubble background.
  final Color? aiBubbleBg;

  /// AI message bubble foreground (text) color.
  final Color? aiBubbleFg;

  /// User message bubble background.
  final Color? userBubbleBg;

  /// User message bubble foreground (text) color.
  final Color? userBubbleFg;

  /// A no-op theme — every field null. Handy as a default in
  /// `PlayerAvatarTheme.of(context) ?? const PlayerAvatarTheme.empty()`.
  const PlayerAvatarTheme.empty()
      : panelBg = null,
        panelBgDark = null,
        panelTextureUrl = null,
        panelTextureBlend = BlendMode.multiply,
        panelTextureOpacity = 0.24,
        vignetteColor = null,
        fontBody = null,
        fontDisplay = null,
        motif = null,
        accent = null,
        dividerColor = null,
        aiBubbleBg = null,
        aiBubbleFg = null,
        userBubbleBg = null,
        userBubbleFg = null;

  /// Resolve the panel background based on the ambient brightness.
  /// Callers that need to render the panel surface pass their
  /// `Theme.of(context).brightness` — the theme picks the light or
  /// dark variant.
  Color? resolvePanelBg(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return panelBgDark ?? panelBg;
    }
    return panelBg;
  }

  /// Read the ambient theme, or null when none has been provided.
  /// Consumers should tolerate null (unthemed rendering).
  static PlayerAvatarTheme? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_PlayerAvatarThemeScope>()
        ?.theme;
  }
}

/// Internal — used by [TwaiThemedChatPanel] to publish the theme to
/// descendants. Public API is [PlayerAvatarTheme.of].
class _PlayerAvatarThemeScope extends InheritedWidget {
  const _PlayerAvatarThemeScope({
    required this.theme,
    required super.child,
  });

  final PlayerAvatarTheme theme;

  @override
  bool updateShouldNotify(_PlayerAvatarThemeScope old) =>
      theme != old.theme;
}

/// Publish a [PlayerAvatarTheme] to a subtree. Public but low-level;
/// most apps use [TwaiThemedChatPanel] instead, which does this plus
/// the surface rendering.
class PlayerAvatarThemeScope extends StatelessWidget {
  const PlayerAvatarThemeScope({
    super.key,
    required this.theme,
    required this.child,
  });

  final PlayerAvatarTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _PlayerAvatarThemeScope(theme: theme, child: child);
}
