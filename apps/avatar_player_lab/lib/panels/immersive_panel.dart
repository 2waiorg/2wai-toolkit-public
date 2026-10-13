// Immersive UI panel — toggles for the 5 SDK UI primitives.
//
// Wiring status (2026-08-16):
//   showImmersiveLayout   = ✓ wired (wraps stage in TwaiImmersiveLayout)
//   showConnectionOverlay = ✓ wired (paints connecting spinner + retry)
//   showThemedChat        — NOT a stage wrapper. TwaiThemedChatPanel is a
//                            themed container for a chat log + composer.
//                            Compose it in your chat pane, not around the
//                            stage. Toggle is inert here.
//   showSceneNavigator    — NOT a stage wrapper. TwaiSceneNavigator needs
//                            a list of TwaiScene defs with transition
//                            films between them. Not seeded in the lab.
//   showCinematicPlayer   — NOT a stage wrapper. TwaiCinematicPlayer
//                            plays a specific video clip as a route or
//                            overlay entry (reward films, transition
//                            films). Needs a video URL to trigger.
//
// The three "NOT a stage wrapper" toggles are kept in the UI so the
// panel honestly lists all 5 primitives, but they no-op until we add
// per-primitive demo affordances in a later slice.

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart' show StageZoomLevel;

import '../lab_state.dart';
import '../lab_shell.dart' show LabRow;
import '../theme.dart';

class ImmersivePanel extends StatelessWidget {
  final LabState state;
  const ImmersivePanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) => ListView(
          children: [
            const LabSectionHeader(
              label: 'IMMERSIVE WRAPPERS',
              hint:
                  'Which of the 7 SDK UI primitives wrap the stage. All start ON where '
                  'they don\'t collide with the exerciser\'s own panel bar.',
            ),
            LabRow(
              label: 'TwaiImmersiveLayout',
              sub: 'Full-screen scene shell — main wrapper.',
              trailing: Switch(
                value: state.showImmersiveLayout,
                onChanged: (v) => state.showImmersiveLayout = v,
              ),
            ),
            LabRow(
              label: 'TwaiConnectionOverlay',
              sub:
                  'Connecting / reconnecting overlay. Fires on status → connecting/failed.',
              trailing: Switch(
                value: state.showConnectionOverlay,
                onChanged: (v) => state.showConnectionOverlay = v,
              ),
            ),
            LabRow(
              label: 'TwaiThemedChatPanel',
              sub:
                  'Chat log + composer on-stage. Off by default in exerciser (chat is in METHODS/STREAMS).',
              trailing: Switch(
                value: state.showThemedChat,
                onChanged: (v) => state.showThemedChat = v,
              ),
            ),
            LabRow(
              label: 'TwaiSceneNavigator',
              sub: '3-scene hard-cut + transition film. Opt-in.',
              trailing: Switch(
                value: state.showSceneNavigator,
                onChanged: (v) => state.showSceneNavigator = v,
              ),
            ),
            LabRow(
              label: 'TwaiCinematicPlayer',
              sub: 'Full-bleed cinematic mode — hides panel bar. Opt-in.',
              trailing: Switch(
                value: state.showCinematicPlayer,
                onChanged: (v) => state.showCinematicPlayer = v,
              ),
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'STAGE PRIMITIVES (always present)',
              hint: 'The stack that always renders under any wrapper.',
            ),
            const _AlwaysOnRow(
              label: 'TwaiSceneStage',
              sub: 'The stage the avatar renders inside. Always present.',
            ),
            const _AlwaysOnRow(
              label: 'TwaiStackedLayout',
              sub: 'Mobile-first stacked variant — auto-selected on narrow layouts.',
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'STAGE — PHASE 3',
              hint:
                  'zoomLevel + panLock ship as TwaiSceneStage props. '
                  'autoScroll is a knob for TwaiChatAutoScroller (consumer '
                  'apps wrap their chat log in it and pass the current message count).',
            ),
            LabRow(
              label: 'zoomLevel',
              sub:
                  'Full (1.0x) → Mid (1.4x) → Close (1.8x). Cycles per '
                  'Penthouse useZoomControl. Transform.scale, alignment top-center.',
              trailing: Wrap(
                spacing: 6,
                children: [
                  for (final z in StageZoomLevel.values)
                    _ZoomChip(
                      value: z,
                      state: state,
                    ),
                ],
              ),
            ),
            LabRow(
              label: 'panLock',
              sub:
                  'Reserves API for the long-press pan-lock behavior. Flag '
                  'plumbed today; full pan implementation ports in a later slice.',
              trailing: Switch(
                value: state.panLock,
                onChanged: (v) => state.panLock = v,
              ),
            ),
            LabRow(
              label: 'chatAutoScroll',
              sub:
                  'Toggle for TwaiChatAutoScroller.enabled — consumer apps '
                  'wrap their chat ListView + pass itemCount. Off = user '
                  'holds scroll position; on = jump to bottom on new messages.',
              trailing: Switch(
                value: state.chatAutoScroll,
                onChanged: (v) => state.chatAutoScroll = v,
              ),
            ),
            const SizedBox(height: 16),
            const _WiringNote(),
            const SizedBox(height: 24),
          ],
        ),
      );
}

class _ZoomChip extends StatelessWidget {
  final StageZoomLevel value;
  final LabState state;
  const _ZoomChip({required this.value, required this.state});
  @override
  Widget build(BuildContext context) {
    final selected = state.zoomLevel == value;
    final label = value.name.toUpperCase();
    return OutlinedButton(
      style: selected
          ? OutlinedButton.styleFrom(
              backgroundColor: LabColors.accent,
              foregroundColor: LabColors.accentOn,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            )
          : OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
      onPressed: () => state.zoomLevel = value,
      child: Text(label,
          style: const TextStyle(
              fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w800)),
    );
  }
}

class _AlwaysOnRow extends StatelessWidget {
  final String label;
  final String sub;
  const _AlwaysOnRow({required this.label, required this.sub});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: LabColors.live,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: LabColors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: const TextStyle(
                          color: LabColors.textDim, fontSize: 11)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: LabColors.live),
              borderRadius: BorderRadius.circular(2),
            ),
            child: const Text('ALWAYS ON',
                style: TextStyle(
                    color: LabColors.live,
                    fontSize: 9,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w800)),
          ),
        ]),
      );
}

class _WiringNote extends StatelessWidget {
  const _WiringNote();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LabColors.chrome,
          border: Border.all(color: LabColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'Wired: TwaiImmersiveLayout + TwaiConnectionOverlay. The other '
          'three (ThemedChat, SceneNavigator, CinematicPlayer) are NOT '
          'stage wrappers in the SDK — they compose elsewhere in your app. '
          'Toggles for those are inert until we add per-primitive demo '
          'affordances (a themed chat overlay, a two-scene navigator '
          'sample, a reward-clip trigger).',
          style: TextStyle(
              color: LabColors.textDim, fontSize: 12, height: 1.4),
        ),
      );
}
