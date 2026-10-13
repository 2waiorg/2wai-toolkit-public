import 'package:flutter/material.dart';

/// Which side of a horizontal (side-by-side) layout the avatar pane
/// sits on. Content (chat log, composer, product UI) takes the other
/// side. See [TwaiSideBySideLayout].
enum AvatarSide { left, right }

/// Which side of a vertical (stacked) layout the avatar pane sits on.
/// Content takes the other side. See [TwaiStackedLayout].
enum AvatarVerticalSide { top, bottom }

/// Two-column layout: avatar pane on one side, arbitrary content on
/// the other. Matches the pattern 2wai.ai's web app uses — portrait
/// avatar sitting alongside a chat + product column.
///
/// **The customer contract:**
///
/// ```dart
/// TwaiSideBySideLayout(
///   avatar: TwaiAvatarStage(...),
///   content: Column([chatLog, composer]),
///   avatarSide: AvatarSide.left,
///   avatarFlex: 2,           // avatar gets 2/5 of the width
///   contentFlex: 3,          // content gets 3/5
///   avatarAspectRatio: 9/16, // constrains the avatar pane to portrait
/// )
/// ```
///
/// The `avatarAspectRatio` constraint is the important knob — most
/// avatars are 9:16 portraits, and letting the pane match that aspect
/// means the avatar fills its column naturally without cropping or
/// letterboxing. Omit for a full-column (no aspect constraint) pane.
///
/// For the top-vs-bottom stacked pattern, use [TwaiStackedLayout]
/// (not yet implemented — add when a customer needs it).
class TwaiSideBySideLayout extends StatelessWidget {
  const TwaiSideBySideLayout({
    super.key,
    required this.avatar,
    required this.content,
    this.avatarSide = AvatarSide.left,
    this.avatarFlex = 2,
    this.contentFlex = 3,
    this.avatarAspectRatio,
    this.avatarBackground = const Color(0xFF000000),
    this.avatarPadding = EdgeInsets.zero,
  });

  /// The avatar widget — typically [TwaiAvatarStage]. Rendered inside
  /// a colored [avatarBackground] pane; optionally aspect-constrained
  /// by [avatarAspectRatio].
  final Widget avatar;

  /// The content column — chat log, composer, product UI, whatever
  /// the customer app puts alongside the avatar.
  final Widget content;

  /// Which side of the layout the avatar sits on. Default [AvatarSide.left]
  /// (mirrors 2wai.ai/*avatar-slug* layout).
  final AvatarSide avatarSide;

  /// Flex weight for the avatar column. Combined with [contentFlex]
  /// this decides horizontal split. Defaults to 2 (with contentFlex=3
  /// → 2/5 of the width goes to the avatar).
  final int avatarFlex;

  /// Flex weight for the content column.
  final int contentFlex;

  /// If set, the avatar is aspect-constrained to this ratio (width /
  /// height). Use `9 / 16` for portrait avatars — the pane will match
  /// the video's aspect and the video fills the pane naturally with
  /// neither cropping nor letterboxing. Null → avatar fills the
  /// column with its natural fit (which may crop or letterbox
  /// depending on the underlying widget).
  final double? avatarAspectRatio;

  /// Fills the avatar column behind the avatar widget. Shows through
  /// on letterbox bars when the avatar is aspect-constrained and its
  /// container is wider/taller than the constraint. Defaults to
  /// solid black.
  final Color avatarBackground;

  /// Optional padding around the avatar pane inside its column.
  /// Useful for framing the avatar with breathing room away from the
  /// window edges. Default zero.
  final EdgeInsets avatarPadding;

  @override
  Widget build(BuildContext context) {
    Widget avatarPane = ColoredBox(
      color: avatarBackground,
      child: avatarAspectRatio != null
          ? Center(
              child: AspectRatio(
                aspectRatio: avatarAspectRatio!,
                child: avatar,
              ),
            )
          : avatar,
    );
    if (avatarPadding != EdgeInsets.zero) {
      avatarPane = Padding(padding: avatarPadding, child: avatarPane);
    }

    final avatarChild = Expanded(flex: avatarFlex, child: avatarPane);
    final contentChild = Expanded(flex: contentFlex, child: content);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: avatarSide == AvatarSide.left
          ? [avatarChild, contentChild]
          : [contentChild, avatarChild],
    );
  }
}

/// Widescreen 16:9 immersive layout — aspect-locked landscape stage
/// with an automatic portrait fallback. Matches the shape 2wai-edu
/// uses for the Cleopatra tutor (16:9 landscape, portrait fallback
/// to a stacked column). Absorbed from
/// [ImmersiveAvatarStage.vue](../../../../2wai-edu/components/scopes/chat/ImmersiveAvatarStage.vue).
///
/// **When to use:** cinematic embeds where the avatar shares screen
/// with a rich background (scenes, plates) and you want a locked
/// aspect regardless of window size. On portrait phones the
/// [portraitFallback] takes over — passing a [TwaiStackedLayout]
/// instance is the common choice.
///
/// **When NOT to use:** simple companion / chat apps where the
/// existing [TwaiSideBySideLayout] or [TwaiStackedLayout] fit the
/// design. This is heavier — locks a specific aspect and doesn't
/// resize below it.
///
/// # Parameters
///
/// - [avatar] — the stage widget to render inside the 16:9 pane.
///   Typically `TwaiSceneStage(...)` or `TwaiPlayer(...)`.
/// - [portraitFallback] — the layout to render when the viewport is
///   taller than wide (or breaks [landscapeMinAspect]). Null → the
///   [avatar] renders full-bleed, no aspect lock.
/// - [landscapeAspectRatio] — width/height of the stage in landscape
///   mode. Default `16 / 9`.
/// - [landscapeMinAspect] — viewport aspect ratio at which we switch
///   to portrait fallback. Default `1.0` (square = fallback).
class TwaiImmersiveLayout extends StatelessWidget {
  const TwaiImmersiveLayout({
    super.key,
    required this.avatar,
    this.portraitFallback,
    this.landscapeAspectRatio = 16 / 9,
    this.landscapeMinAspect = 1.0,
    this.background = const Color(0xFF000000),
    this.padding = EdgeInsets.zero,
  });

  final Widget avatar;
  final Widget? portraitFallback;
  final double landscapeAspectRatio;
  final double landscapeMinAspect;
  final Color background;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportAspect =
            constraints.maxWidth / constraints.maxHeight;
        final useFallback =
            viewportAspect < landscapeMinAspect && portraitFallback != null;
        if (useFallback) {
          return portraitFallback!;
        }
        Widget stage = ColoredBox(
          color: background,
          child: Center(
            child: AspectRatio(
              aspectRatio: landscapeAspectRatio,
              child: avatar,
            ),
          ),
        );
        if (padding != EdgeInsets.zero) {
          stage = Padding(padding: padding, child: stage);
        }
        return stage;
      },
    );
  }
}

/// Two-row layout: avatar pane on top (or bottom), content
/// underneath (or on top). The classic phone-first pattern —
/// portrait avatar filling most of the height, chat/composer
/// stacked below. Mirrors [TwaiSideBySideLayout]'s knobs but on
/// the vertical axis.
///
/// ```dart
/// TwaiStackedLayout(
///   avatar: TwaiAvatarStage(...),
///   content: Column([chatLog, composer]),
///   avatarSide: AvatarVerticalSide.top,
///   avatarFlex: 3,
///   contentFlex: 2,
///   avatarAspectRatio: 9/16,
/// )
/// ```
class TwaiStackedLayout extends StatelessWidget {
  const TwaiStackedLayout({
    super.key,
    required this.avatar,
    required this.content,
    this.avatarSide = AvatarVerticalSide.top,
    this.avatarFlex = 3,
    this.contentFlex = 2,
    this.avatarAspectRatio,
    this.avatarBackground = const Color(0xFF000000),
    this.avatarPadding = EdgeInsets.zero,
  });

  /// The avatar widget — typically [TwaiAvatarStage].
  final Widget avatar;

  /// The content column — chat log, composer, product UI.
  final Widget content;

  /// Which vertical side the avatar sits on. Default
  /// [AvatarVerticalSide.top] (phone-app pattern).
  final AvatarVerticalSide avatarSide;

  /// Flex weight for the avatar row (of a total of
  /// [avatarFlex] + [contentFlex]). Default 3 (with contentFlex=2 →
  /// avatar gets 3/5 of the height).
  final int avatarFlex;

  /// Flex weight for the content row.
  final int contentFlex;

  /// If set, the avatar is aspect-constrained to this ratio (width /
  /// height). Use `9 / 16` for portrait avatars — matches the
  /// video's aspect and the video fills the row naturally without
  /// letterboxing.
  final double? avatarAspectRatio;

  /// Fills the avatar row behind the avatar widget. Shows through on
  /// letterbox bars if the avatar is aspect-constrained and its
  /// container is wider than the constraint.
  final Color avatarBackground;

  /// Optional padding around the avatar pane inside its row.
  final EdgeInsets avatarPadding;

  @override
  Widget build(BuildContext context) {
    Widget avatarPane = ColoredBox(
      color: avatarBackground,
      child: avatarAspectRatio != null
          ? Center(
              child: AspectRatio(
                aspectRatio: avatarAspectRatio!,
                child: avatar,
              ),
            )
          : avatar,
    );
    if (avatarPadding != EdgeInsets.zero) {
      avatarPane = Padding(padding: avatarPadding, child: avatarPane);
    }

    final avatarChild = Expanded(flex: avatarFlex, child: avatarPane);
    final contentChild = Expanded(flex: contentFlex, child: content);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: avatarSide == AvatarVerticalSide.top
          ? [avatarChild, contentChild]
          : [contentChild, avatarChild],
    );
  }
}
