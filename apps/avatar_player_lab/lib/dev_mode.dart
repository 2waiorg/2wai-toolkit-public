// Dev-mode detection.
//
// Three ways to enable:
//   1. Web URL param:      ?dev=1
//   2. Native compile:     flutter run --dart-define=DEV_MODE=1
//   3. Long-press unlock:  hold the version chip in the shell for 2 seconds
//
// Dev-mode surfaces additional panels (debug overlay, wire recorder,
// config sliders, wire inspector, sink override) that would be
// embarrassing in a shipping public demo. See the plan doc for the
// full list.

import 'package:flutter/foundation.dart';

const _kDevModeCompile = bool.fromEnvironment('DEV_MODE', defaultValue: false);

class DevMode extends ChangeNotifier {
  bool _enabled;
  DevMode._(this._enabled);

  bool get enabled => _enabled;

  void enable() {
    if (_enabled) return;
    _enabled = true;
    notifyListeners();
  }

  void disable() {
    if (!_enabled) return;
    _enabled = false;
    notifyListeners();
  }

  /// Initial state — checks the compile-time flag and, on web, the URL
  /// `?dev=1` param. Long-press unlock is toggled at runtime via
  /// [enable]/[disable].
  factory DevMode.initial() {
    var enabled = _kDevModeCompile;
    if (!enabled && kIsWeb) {
      final loc = Uri.base;
      final v = loc.queryParameters['dev'];
      if (v == '1' || v == 'true') enabled = true;
    }
    return DevMode._(enabled);
  }
}
