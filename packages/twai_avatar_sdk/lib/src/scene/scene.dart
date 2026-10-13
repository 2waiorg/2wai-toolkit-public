import 'package:flutter/widgets.dart';

import 'scene_anchor.dart';

/// One immersive scene in a multi-scene experience. Bundles the
/// per-scene visual state that a [TwaiSceneNavigator] needs to
/// render one moment in the story: the plate, where the avatar
/// stands, and how the composite is graded.
///
/// Everything except [id] and [plate] is optional; unspecified
/// slots take sensible defaults (feed at full stage, identity
/// grade, no contact shadow, no transition film).
///
/// # Example (edu's Cleopatra temple scene)
///
/// ```dart
/// const TwaiScene(
///   id: 'temple',
///   plate: NetworkImage(templeBackdropUrl),
///   anchor: SceneAnchor(
///     xFraction: 0.517, yFraction: 0.0065,
///     widthFraction: 0.289, heightFraction: 0.921,
///   ),
///   colorGrade: TwaiColorGrade(),        // identity
///   contactShadowIntensity: 0.38,
/// )
/// ```
///
/// # Not a widget
///
/// This is a pure value type. Renderable through [TwaiSceneNavigator]
/// (which composes it into a [TwaiSceneStage]), or by hand if the
/// consuming app wants to lay out its own scene widget hierarchy.
@immutable
class TwaiScene {
  const TwaiScene({
    required this.id,
    required this.plate,
    this.anchor,
    this.contactShadowColor = const Color(0xFF000000),
    this.contactShadowIntensity = 0.36,
    this.gradeBrightness = 1.0,
    this.gradeContrast = 1.0,
    this.gradeSaturation = 1.0,
    this.gradeSepia = 0.0,
    this.gradeHueRotate = 0.0,
    this.transitionFilmUrl,
  });

  /// Stable identifier for switching. Any string that's unique within
  /// the navigator's scene list (`'temple'`, `'nilometer'`, etc.).
  final String id;

  /// The scene backdrop — typically an `Image.network`, an
  /// `Image.asset`, or a widget that wraps a looping-video plate.
  final Widget plate;

  /// Where the avatar's feed sits inside this scene. Null → feed
  /// fills the whole stage (equivalent to [SceneAnchor.fullStage]).
  final SceneAnchor? anchor;

  /// Contact-shadow color + intensity applied under the feed. Set
  /// [contactShadowIntensity] to 0 to hide the shadow entirely.
  final Color contactShadowColor;
  final double contactShadowIntensity;

  /// Per-scene color grade — brightness / contrast / saturation /
  /// sepia / hue-rotate. All values are the identity by default so
  /// unspecified grade = no grade. See [TwaiColorGrade] for meaning
  /// of each field.
  final double gradeBrightness;
  final double gradeContrast;
  final double gradeSaturation;
  final double gradeSepia;
  final double gradeHueRotate;

  /// Optional URL of a full-viewport film that bridges from the
  /// previous scene to this one when [TwaiSceneNavigator] activates
  /// it. `null` = hard-cut. **Reserved slot**: the SDK's built-in
  /// navigator doesn't currently play the film — that's a follow-on
  /// slice (see planning docs). Apps that want transitions today can
  /// wrap the navigator in their own overlay + cinematic player.
  final String? transitionFilmUrl;

  @override
  bool operator ==(Object other) =>
      other is TwaiScene &&
      other.id == id &&
      other.plate == plate &&
      other.anchor == anchor &&
      other.contactShadowColor == contactShadowColor &&
      other.contactShadowIntensity == contactShadowIntensity &&
      other.gradeBrightness == gradeBrightness &&
      other.gradeContrast == gradeContrast &&
      other.gradeSaturation == gradeSaturation &&
      other.gradeSepia == gradeSepia &&
      other.gradeHueRotate == gradeHueRotate &&
      other.transitionFilmUrl == transitionFilmUrl;

  @override
  int get hashCode => Object.hash(
        id,
        plate,
        anchor,
        contactShadowColor,
        contactShadowIntensity,
        gradeBrightness,
        gradeContrast,
        gradeSaturation,
        gradeSepia,
        gradeHueRotate,
        transitionFilmUrl,
      );
}
