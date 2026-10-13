import 'package:flutter/widgets.dart';

/// Fractional anchor coordinates for placing the avatar's live feed
/// within a scene stage. Every value is a fraction of the parent
/// container in `[0.0, 1.0]`, matching 2wai-edu's per-scene anchor
/// convention (see `useSceneNavigation.ts:37-46`).
///
/// Coord system (matches edu exactly so anchors are copy-pasteable):
///
/// - **`xFraction`** — horizontal position of the feed's *center*.
///   0.0 = flush-left, 0.5 = centered, 1.0 = flush-right.
/// - **`yFraction`** — vertical position of the feed's *top edge*.
///   0.0 = top of stage, 1.0 = feed pushed off the bottom.
/// - **`widthFraction`** / **`heightFraction`** — feed's own size as
///   a fraction of the stage.
///
/// # Example (Cleopatra temple scene)
///
/// ```dart
/// const SceneAnchor(
///   xFraction: 0.517,      // slight nudge right of center
///   yFraction: 0.0065,     // hugging the top of the plate
///   widthFraction: 0.289,  // ~29% of stage width
///   heightFraction: 0.921, // ~92% of stage height
/// )
/// ```
///
/// # How it renders
///
/// [TwaiSceneStage] consumes this via its `feedAnchor` parameter —
/// wraps the feed in a `Positioned` computed from the anchor +
/// parent constraints. Without an anchor, the feed fills the stage.
///
/// Anchors are cheap to construct and comparable by value, so they
/// slot naturally into a `TwaiScene` catalog.
@immutable
class SceneAnchor {
  const SceneAnchor({
    required this.xFraction,
    required this.yFraction,
    required this.widthFraction,
    required this.heightFraction,
  });

  final double xFraction;
  final double yFraction;
  final double widthFraction;
  final double heightFraction;

  /// The feed sized 100% of the stage, anchored top-left. Equivalent
  /// to omitting the anchor entirely — use this when you want to
  /// pass an explicit "identity" anchor through data-driven code
  /// paths where `null` is inconvenient.
  static const fullStage = SceneAnchor(
    xFraction: 0.5,
    yFraction: 0.0,
    widthFraction: 1.0,
    heightFraction: 1.0,
  );

  /// Compute the concrete rectangle within a stage of the given
  /// [stageSize]. Used by [TwaiSceneStage] internally; exposed for
  /// tests + apps that want to render their own overlays at the
  /// same coordinates as the feed.
  Rect resolveIn(Size stageSize) {
    final w = stageSize.width * widthFraction;
    final h = stageSize.height * heightFraction;
    // xFraction anchors the feed's CENTER; convert to left edge.
    final left = stageSize.width * xFraction - w / 2;
    final top = stageSize.height * yFraction;
    return Rect.fromLTWH(left, top, w, h);
  }

  @override
  bool operator ==(Object other) =>
      other is SceneAnchor &&
      other.xFraction == xFraction &&
      other.yFraction == yFraction &&
      other.widthFraction == widthFraction &&
      other.heightFraction == heightFraction;

  @override
  int get hashCode =>
      Object.hash(xFraction, yFraction, widthFraction, heightFraction);

  @override
  String toString() =>
      'SceneAnchor(x=$xFraction, y=$yFraction, w=$widthFraction, h=$heightFraction)';
}
