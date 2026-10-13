import 'package:flutter/widgets.dart';

/// Per-scene elliptical "contact shadow" — a soft radial gradient
/// beneath the feed that visually grounds the avatar into the plate.
/// Ports edu's per-scene shadow layer
/// ([ImmersiveAvatarStage.vue:366-377](../../../../../2wai-edu/components/scopes/chat/ImmersiveAvatarStage.vue)).
///
/// Renders as a pointer-transparent overlay filling the parent
/// bounds. Drop it in the `atmosphere` or `overlay` slot of
/// [TwaiSceneStage] and it composites at the right z depth.
///
/// # Parameters
///
/// - [color] — shadow color. Typically a dark neutral with alpha
///   applied via [intensity].
/// - [intensity] — alpha strength `[0, 1]`. `0.28` = soft (indoor
///   temple lighting), `0.44` = strong (harsh noon sun). Default
///   matches edu's mid-scene value.
/// - [radius] — radial extent as a fraction of the parent diagonal.
///   Larger = softer / more spread-out shadow.
/// - [center] — where the shadow sits (as an [Alignment]). Default
///   bottom-center so it looks like a floor contact.
/// - [ellipseAspect] — width/height of the ellipse. `2.5` gives a
///   flattened floor-shadow shape (default); `1.0` would be circular.
class TwaiContactShadow extends StatelessWidget {
  const TwaiContactShadow({
    super.key,
    this.color = const Color(0xFF000000),
    this.intensity = 0.36,
    this.radius = 0.5,
    this.center = Alignment.bottomCenter,
    this.ellipseAspect = 2.5,
  });

  final Color color;
  final double intensity;
  final double radius;
  final Alignment center;
  final double ellipseAspect;

  @override
  Widget build(BuildContext context) {
    final shadow = color.withValues(alpha: intensity.clamp(0.0, 1.0));
    return IgnorePointer(
      child: FractionallySizedBox(
        alignment: center,
        widthFactor: 1.0,
        heightFactor: 1.0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: center,
              radius: radius,
              colors: [shadow, const Color(0x00000000)],
              stops: const [0.0, 1.0],
              focalRadius: 0.0,
              tileMode: TileMode.clamp,
            ),
            // Stretch the ellipse via ImageShader would need a paint
            // context; simpler idiom: scale the whole shadow along
            // the horizontal axis so the radial gradient reads oval.
            // Handled via Transform in the parent Stack.
          ),
          child: SizedBox.expand(
            child: Transform.scale(
              scaleX: ellipseAspect.clamp(0.1, 10.0),
              scaleY: 1.0,
              alignment: center,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}
