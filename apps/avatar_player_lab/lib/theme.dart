// Dev-instrument palette — charcoal bg + electric-yellow accent. Signals
// "this is an internal testbed / kitchen sink with dials," not a consumer
// app. Different from the MMM warm-neutrals palette on purpose.

import 'package:flutter/material.dart';

class LabColors {
  // Backgrounds — near-black stage, panel just above it, chrome above that.
  static const stage = Color(0xFF08090C);
  static const panel = Color(0xFF12141B);
  static const chrome = Color(0xFF1B1E28);
  static const border = Color(0xFF2A2F3D);

  // Text
  static const text = Color(0xFFE8ECF4);
  static const textDim = Color(0xFF8B93A6);
  static const textMuted = Color(0xFF5C6377);

  // Accents
  static const accent = Color(0xFFFFEE00);           // electric yellow — main affordance
  static const accentOn = Color(0xFF08090C);         // for text on accent
  static const live = Color(0xFF41E3A0);             // green — live/ready
  static const wait = Color(0xFFFFB74A);             // amber — connecting/pending
  static const bad = Color(0xFFFF5A6E);              // red — failed/error
  static const comingSoon = Color(0xFF4A5163);       // grey — deferred/greyed panels
}

ThemeData buildLabTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: LabColors.accent,
    onPrimary: LabColors.accentOn,
    secondary: LabColors.live,
    onSecondary: LabColors.stage,
    surface: LabColors.panel,
    onSurface: LabColors.text,
    error: LabColors.bad,
    onError: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: LabColors.stage,
    fontFamily: 'Roboto',
    dividerTheme: const DividerThemeData(
      color: LabColors.border,
      space: 1,
      thickness: 1,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LabColors.chrome,
      foregroundColor: LabColors.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: LabColors.text,
        fontWeight: FontWeight.w800,
        fontSize: 15,
        letterSpacing: 1.6,
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: LabColors.accent,
      unselectedLabelColor: LabColors.textDim,
      indicatorColor: LabColors.accent,
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 11,
        letterSpacing: 1.2,
      ),
      unselectedLabelStyle: TextStyle(
        fontWeight: FontWeight.w500,
        fontSize: 11,
        letterSpacing: 1.2,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: LabColors.accent,
        foregroundColor: LabColors.accentOn,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          fontSize: 12,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LabColors.text,
        side: const BorderSide(color: LabColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          fontSize: 11,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LabColors.chrome,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: LabColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: LabColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: LabColors.accent, width: 2),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? LabColors.accent : LabColors.textDim),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? LabColors.accent.withValues(alpha: 0.4) : LabColors.border),
    ),
  );
}

/// A section header used inside every panel for consistent dev-instrument feel.
class LabSectionHeader extends StatelessWidget {
  final String label;
  final String? hint;
  final Widget? trailing;
  const LabSectionHeader({super.key, required this.label, this.hint, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: LabColors.textDim,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      fontSize: 10,
                    ),
                  ),
                  if (hint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        hint!,
                        style: const TextStyle(
                          color: LabColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}
