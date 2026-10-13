import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Per-scene color grading — brightness / contrast / saturation /
/// sepia / hue-rotation applied to [child] as a single [ColorFilter].
/// Direct port of the CSS `filter` chain 2wai-edu uses per scene
/// ([ImmersiveAvatarStage.ts:192-242](../../../../../2wai-edu/components/scopes/chat/ImmersiveAvatarStage.ts)).
///
/// # Why not wrap in a Container with per-effect widgets?
///
/// Flutter's `ColorFilter.matrix()` takes a single 4×5 matrix that
/// composes every one of these operations without stacking filters
/// (each stacked filter forces a separate raster). Composing the
/// matrix here means the whole grade is one GPU pass per frame —
/// same cost as no grade at all when values are defaults.
///
/// # Values
///
/// All defaults are the identity (`brightness=1, contrast=1,
/// saturation=1, sepia=0, hueRotate=0`) so an unspecified grade is
/// visually a no-op. When every value is default, [build] short-
/// circuits to the raw [child] with zero raster overhead.
///
/// - **[brightness]** — `[0, ∞)`. `1.0` = unchanged, `0.5` = half,
///   `1.2` = 20% brighter.
/// - **[contrast]** — `[0, ∞)`. `1.0` = unchanged.
/// - **[saturation]** — `[0, ∞)`. `0.0` = greyscale, `1.0` = unchanged,
///   `1.4` = punchier.
/// - **[sepia]** — `[0, 1]`. `0.0` = unchanged, `1.0` = fully sepia.
/// - **[hueRotate]** — degrees. `0` = unchanged, positive = clockwise
///   around the color wheel.
///
/// # Example (edu's nilometer scene)
///
/// ```dart
/// TwaiColorGrade(
///   brightness: 0.87,
///   hueRotate: -6,
///   child: sceneFeed,
/// )
/// ```
class TwaiColorGrade extends StatelessWidget {
  const TwaiColorGrade({
    super.key,
    required this.child,
    this.brightness = 1.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.sepia = 0.0,
    this.hueRotate = 0.0,
  });

  final Widget child;
  final double brightness;
  final double contrast;
  final double saturation;
  final double sepia;
  final double hueRotate;

  /// Whether this grade is visually a no-op (identity). Callers can
  /// skip the ColorFilter wrapping when true, avoiding a needless
  /// raster pass — [ColorFiltered] does not short-circuit itself.
  bool get isIdentity =>
      brightness == 1.0 &&
      contrast == 1.0 &&
      saturation == 1.0 &&
      sepia == 0.0 &&
      hueRotate == 0.0;

  @override
  Widget build(BuildContext context) {
    if (isIdentity) return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_buildMatrix()),
      child: child,
    );
  }

  /// Compose the 4×5 color matrix (row-major) that represents all
  /// enabled ops. Order matches CSS's `filter: brightness()
  /// contrast() sepia() saturate() hue-rotate()` chain edu uses.
  List<double> _buildMatrix() {
    var m = _identity();
    if (brightness != 1.0) m = _mul(m, _brightness(brightness));
    if (contrast != 1.0) m = _mul(m, _contrast(contrast));
    if (sepia != 0.0) m = _mul(m, _sepia(sepia.clamp(0.0, 1.0)));
    if (saturation != 1.0) m = _mul(m, _saturation(saturation));
    if (hueRotate != 0.0) m = _mul(m, _hueRotate(hueRotate));
    return m;
  }
}

// ── Matrix helpers ──────────────────────────────────────────────────
//
// A 4×5 color matrix is arranged row-major as:
//   R' = m0 R + m1 G + m2 B + m3 A + m4
//   G' = m5 R + m6 G + m7 B + m8 A + m9
//   B' = m10 R + m11 G + m12 B + m13 A + m14
//   A' = m15 R + m16 G + m17 B + m18 A + m19
//
// Composing two grades means multiplying the two matrices with the
// alpha-offset column treated as a translation. Standard technique
// for CSS-filter emulation on canvas.

List<double> _identity() => <double>[
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ];

List<double> _brightness(double b) => <double>[
      b, 0, 0, 0, 0,
      0, b, 0, 0, 0,
      0, 0, b, 0, 0,
      0, 0, 0, 1, 0,
    ];

List<double> _contrast(double c) {
  // Contrast centers around 0.5 → out = c*(in - 0.5) + 0.5 = c*in + (0.5 - c/2)
  // Flutter's ColorFilter.matrix expects 0..255 space for the offset.
  final o = (0.5 - c / 2) * 255.0;
  return <double>[
    c, 0, 0, 0, o,
    0, c, 0, 0, o,
    0, 0, c, 0, o,
    0, 0, 0, 1, 0,
  ];
}

List<double> _saturation(double s) {
  // Standard luminance-preserving saturation matrix.
  final invS = 1 - s;
  final r = 0.2126 * invS;
  final g = 0.7152 * invS;
  final b = 0.0722 * invS;
  return <double>[
    r + s, g, b, 0, 0,
    r, g + s, b, 0, 0,
    r, g, b + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

List<double> _sepia(double t) {
  // Lerp between identity and the CSS sepia constants.
  const r0 = 0.393, r1 = 0.769, r2 = 0.189;
  const g0 = 0.349, g1 = 0.686, g2 = 0.168;
  const b0 = 0.272, b1 = 0.534, b2 = 0.131;
  final invT = 1 - t;
  return <double>[
    invT + t * r0, t * r1, t * r2, 0, 0,
    t * g0, invT + t * g1, t * g2, 0, 0,
    t * b0, t * b1, invT + t * b2, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

List<double> _hueRotate(double degrees) {
  // Standard hue-rotation matrix (CSS Filter Effects spec §7.6).
  final rad = degrees * math.pi / 180.0;
  final c = math.cos(rad);
  final s = math.sin(rad);
  return <double>[
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715,
    0.072 - c * 0.072 + s * 0.928, 0, 0,
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140,
    0.072 - c * 0.072 - s * 0.283, 0, 0,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715,
    0.072 + c * 0.928 + s * 0.072, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// 4×5 by 4×5 matrix multiply (the alpha-offset column is treated
/// as a translation). Standard color-matrix composition.
List<double> _mul(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += a[row * 5 + k] * b[k * 5 + col];
      }
      if (col == 4) {
        sum += a[row * 5 + 4];
      }
      out[row * 5 + col] = sum;
    }
  }
  return out;
}
