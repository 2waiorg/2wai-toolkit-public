// avatar_player_lab — TwaiPlayer capability exerciser.
//
// The "kitchen sink with dials" reference app. Every SDK knob surfaces
// as a live control. Design principle: EVERYTHING IS ON BY DEFAULT —
// knobs dial things back, not on. Boot maxed-out; testers subtract
// features to bisect issues. See docs/twai_player_capability_exerciser_plan.md.
//
// One codebase, two modes:
//   - Public showcase (default) — polished landing for the marketing site
//   - Dev mode — every panel unlocked (see dev_mode.dart)
//
// RUN
//   cd apps/avatar_player_lab
//   flutter clean && flutter pub get
//   flutter run -d chrome --web-port 5179                    # public mode
//   flutter run -d chrome --web-port 5179 --dart-define=DEV_MODE=1  # dev mode
//   flutter run -d 1A181JEG501702                            # Pixel 5a
//
// Alt on web: append ?dev=1 to the URL to enable dev mode without a rebuild.

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import 'dev_mode.dart';
import 'lab_shell.dart';
import 'lab_state.dart';
import 'theme.dart';

const _kBuildTag = 'avatar_player_lab v0.1.4';

void main() => runApp(const AvatarPlayerLabApp());

class AvatarPlayerLabApp extends StatefulWidget {
  const AvatarPlayerLabApp({super.key});
  @override
  State<AvatarPlayerLabApp> createState() => _AvatarPlayerLabAppState();
}

class _AvatarPlayerLabAppState extends State<AvatarPlayerLabApp> {
  final LabState _state = LabState();
  late final DevMode _devMode;

  @override
  void initState() {
    super.initState();
    _devMode = DevMode.initial();
    // Boot with the TwaiDebugController active if dev-mode is already on
    // at start. Version-chip long-press flips it later — we listen for
    // the transition and activate then.
    if (_devMode.enabled) {
      TwaiDebugController.instance.enable(buildTag: _kBuildTag);
    }
    _devMode.addListener(_syncDebugController);
  }

  void _syncDebugController() {
    final c = TwaiDebugController.instance;
    if (_devMode.enabled && !c.enabled) {
      c.enable(buildTag: _kBuildTag);
    } else if (!_devMode.enabled && c.enabled) {
      c.disable();
    }
  }

  @override
  void dispose() {
    _devMode.removeListener(_syncDebugController);
    _state.dispose();
    _devMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Avatar Player Lab',
        debugShowCheckedModeBanner: false,
        theme: buildLabTheme(),
        home: LabShell(state: _state, devMode: _devMode),
      );
}
