import 'package:flutter/material.dart';

/// A 5-layer compositing stack for immersive avatar scenes. Mirrors
/// the shape 2wai-edu built for the Cleopatra tutor
/// ([ImmersiveAvatarStage.vue](../../../../2wai-edu/components/scopes/chat/ImmersiveAvatarStage.vue)):
/// a scene plate, an atmosphere overlay, the live avatar feed, an
/// optional overlay layer, and a top tools layer.
///
/// Every layer except [feed] is optional; unspecified slots don't
/// paint. This preserves the parameterized-optional principle — apps
/// that want a simple opaque avatar just fill [feed] and skip the
/// rest.
///
/// # Layer order (bottom → top)
///
/// | z | Slot | Typical content |
/// |---|---|---|
/// | 0 | `plate` | Static scene backdrop (still image, looping video) — the world behind the avatar |
/// | 1 | `atmosphere` | Lighting / weather / particle / color-grade overlay (dust motes, smoke, cross-fade filter) |
/// | 2 | `feed` | The live avatar itself — typically `TwaiPlayer` or `TwaiAvatarPlayerStage` |
/// | 3 | `overlay` | Overlay elements (frames, emote glyphs, scene transitions) painted OVER the feed |
/// | 4 | `tools` | Chrome (HUD, action buttons, composer, subtitles) |
///
/// The composite uses [Stack] so layers can absolutely-position their
/// children. Callers with a specific anchor for the feed (e.g. edu's
/// per-scene fractional coordinates) can wrap [feed] in a `Positioned`
/// / `Align` before passing it in.
///
/// # Not scene navigation — that's Group D
///
/// This widget is the *composite primitive*. Multi-scene navigation +
/// scene transitions + per-scene color grading land in a later group
/// (Group D from the 2wai-edu survey). A single stage instance
/// renders one scene; swap scenes by rebuilding with different
/// [plate] + [atmosphere] slots.
/// Zoom presets for [TwaiSceneStage.zoomLevel]. Ported from Penthouse
/// `useZoomControl` — three cycling levels focused on the avatar's
/// upper body.
enum StageZoomLevel {
  full(1.0),
  mid(1.4),
  close(1.8);

  const StageZoomLevel(this.scale);
  final double scale;

  StageZoomLevel get next => switch (this) {
        StageZoomLevel.full => StageZoomLevel.mid,
        StageZoomLevel.mid => StageZoomLevel.close,
        StageZoomLevel.close => StageZoomLevel.full,
      };
}

class TwaiSceneStage extends StatelessWidget {
  const TwaiSceneStage({
    super.key,
    required this.feed,
    this.plate,
    this.atmosphere,
    this.overlay,
    this.tools,
    this.clipBehavior = Clip.hardEdge,
    this.zoomLevel = StageZoomLevel.full,
    this.panLock = false,
  });

  /// The live avatar layer (z=2). Typically `TwaiPlayer(controller:
  /// handle)` or `TwaiAvatarPlayerStage(...)`. Required — a scene
  /// stage without an avatar is just a wallpaper.
  final Widget feed;

  /// Bottom layer (z=0). Scene backdrop — a still image or looping
  /// video. Fills the stage; the feed is composited on top.
  final Widget? plate;

  /// Above the plate, below the feed (z=1). Environmental accents:
  /// dust motes, smoke, per-scene color-grade filter. Should be
  /// pointer-transparent so gestures reach [feed] / [tools].
  final Widget? atmosphere;

  /// Above the feed (z=3). Avatar-scene overlays: emote glyphs,
  /// frames, scene transitions. Also usually pointer-transparent.
  final Widget? overlay;

  /// Top layer (z=4). HUD, action buttons, composer, subtitles.
  /// Interactive by default.
  final Widget? tools;

  /// How the stage clips its bounds. Default [Clip.hardEdge] — most
  /// callers want the atmosphere / feed / overlay clipped to the
  /// pane. Set [Clip.none] when composing inside another layout
  /// that already handles clipping.
  final Clip clipBehavior;

  /// Zoom preset applied to the feed layer. Cycles full → mid → close
  /// per [StageZoomLevel.next]; consumer app owns the cycle (usually
  /// wired to a button + a state notifier). Applied as `Transform.scale`
  /// with `alignment: Alignment.topCenter` — mirrors Penthouse's
  /// upper-body-focused zoom.
  final StageZoomLevel zoomLevel;

  /// Pan-lock — when true, the feed transform is fixed at its current
  /// zoom offset and horizontal pan gestures don't shift it. Long-press
  /// gesture that toggles this is a consumer concern (Penthouse uses
  /// `useIdlePanMode`); this flag is the state the stage consumes.
  ///
  /// Currently the stage doesn't implement pan (single-point Transform);
  /// the flag reserves API surface for when the full pan behavior ports
  /// from Penthouse. Setting it today is a no-op visually.
  final bool panLock;

  @override
  Widget build(BuildContext context) {
    // Zoom wrapper — Transform.scale with alignment: topCenter so the
    // avatar's head stays framed as scale increases.
    Widget wrappedFeed = feed;
    if (zoomLevel != StageZoomLevel.full) {
      wrappedFeed = Transform.scale(
        scale: zoomLevel.scale,
        alignment: Alignment.topCenter,
        child: feed,
      );
    }
    final layers = <Widget>[
      if (plate != null) Positioned.fill(child: plate!),
      if (atmosphere != null)
        Positioned.fill(child: IgnorePointer(child: atmosphere!)),
      Positioned.fill(child: wrappedFeed),
      if (overlay != null)
        Positioned.fill(child: IgnorePointer(child: overlay!)),
      if (tools != null) Positioned.fill(child: tools!),
    ];
    return Stack(clipBehavior: clipBehavior, children: layers);
  }
}
