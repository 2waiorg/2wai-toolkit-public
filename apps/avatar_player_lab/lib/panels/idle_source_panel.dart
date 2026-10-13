// Idle source panel — pick which AvatarIdleSource the stage uses AND
// inspect the current outfit's curated playlist.
//
// TWO sections:
//
//   1. IDLE SOURCE — 7-way radio for which AvatarIdleSource subclass
//      wraps the idle layer. Shared with construction_panel — the two
//      edit the same LabState.idleKind.
//
//   2. CURATED PLAYLIST — for Adapter-1 outfits with idleUrls: [...]
//      set, shows the rotation pool + a SHUFFLE action that bumps
//      rebuildToken so resolveOutfit() picks a fresh URL. This is the
//      real behavior of Mason's player v46 curated idle playlists —
//      per-session random pick from the outfit's list.

import 'package:flutter/material.dart';

import '../lab_state.dart';
import '../lab_shell.dart' show showLabSnack;
import '../theme.dart';

class IdleSourcePanel extends StatelessWidget {
  final LabState state;
  const IdleSourcePanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          final outfit = state.currentOutfit;
          final urls = outfit.idleUrls;
          return ListView(
            children: [
              const LabSectionHeader(
                label: 'IDLE SOURCE',
                hint:
                    'Which of the 7 AvatarIdleSource subclasses wraps the idle '
                    'layer. Changing this rebuilds the stage. Shared with the '
                    'CONSTRUCT tab\'s idle knob.',
              ),
              _IdleRow(
                value: IdleKind.network,
                label: 'NetworkVideoIdle',
                sub: 'Streams outfit.idleUrl on loop. Default.',
                state: state,
              ),
              _IdleRow(
                value: IdleKind.solid,
                label: 'SolidColorIdle',
                sub: 'Flat black backdrop — A/B against video idles.',
                state: state,
              ),
              _IdleRow(
                value: IdleKind.none,
                label: 'NoIdle',
                sub: 'Transparent placeholder — compose your own idle behind it.',
                state: state,
              ),
              _IdleRow(
                value: IdleKind.transparent,
                label: 'TransparentVideoIdle',
                sub:
                    'Alpha video (HEVC+alpha .mov / VP9+alpha .webm). Falls '
                    'back to the outfit idle URL if no alpha variants set.',
                state: state,
              ),
              _IdleRow(
                value: IdleKind.posterNetwork,
                label: 'NetworkPosterIdle',
                sub: 'Static poster from URL — no motion.',
                state: state,
              ),
              _IdleRow(
                value: IdleKind.asset,
                label: 'AssetVideoIdle (P2 wiring)',
                sub: 'Bundled asset — needs sample assets checked in.',
                state: state,
                disabled: true,
              ),
              _IdleRow(
                value: IdleKind.posterAsset,
                label: 'AssetPosterIdle (P2 wiring)',
                sub: 'Bundled poster asset — needs sample assets checked in.',
                state: state,
                disabled: true,
              ),
              const Divider(),
              LabSectionHeader(
                label: 'CURATED PLAYLIST',
                hint: urls == null || urls.isEmpty
                    ? 'This outfit only has a single idleUrl. Switch to Sophi '
                        'or Bella Vaunt to see rotation.'
                    : 'Rotation pool for the current outfit (${outfit.name}). '
                        'The SDK\'s resolveOutfit() picks one per session — '
                        'SHUFFLE bumps rebuildToken so it picks fresh.',
                trailing: (urls != null && urls.isNotEmpty)
                    ? OutlinedButton.icon(
                        icon: const Icon(Icons.shuffle, size: 14),
                        label: const Text('SHUFFLE'),
                        onPressed: () {
                          state.bumpRebuild();
                          showLabSnack(context,
                              'Stage rebuild — resolveOutfit() picks fresh idle');
                        },
                      )
                    : null,
              ),
              if (urls != null && urls.isNotEmpty) ...[
                for (var i = 0; i < urls.length; i++)
                  _PlaylistRow(index: i, url: urls[i]),
              ] else
                const _SingleIdleNote(),
              const SizedBox(height: 12),
              const _RotationNote(),
              const SizedBox(height: 24),
            ],
          );
        },
      );
}

class _IdleRow extends StatelessWidget {
  final IdleKind value;
  final String label;
  final String sub;
  final LabState state;
  final bool disabled;
  const _IdleRow({
    required this.value,
    required this.label,
    required this.sub,
    required this.state,
    this.disabled = false,
  });
  @override
  Widget build(BuildContext context) {
    final selected = state.idleKind == value;
    return InkWell(
      onTap: disabled ? null : () => state.idleKind = value,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? LabColors.chrome : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? LabColors.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: disabled
                    ? LabColors.comingSoon
                    : (selected ? LabColors.accent : LabColors.border),
                width: 2,
              ),
              color: selected ? LabColors.accent : Colors.transparent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color:
                            disabled ? LabColors.textMuted : LabColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: TextStyle(
                          color: disabled
                              ? LabColors.textMuted
                              : LabColors.textDim,
                          fontSize: 11)),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  final int index;
  final String url;
  const _PlaylistRow({required this.index, required this.url});
  @override
  Widget build(BuildContext context) {
    final filename = url.split('/').last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: LabColors.border),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text('${index + 1}',
              style: const TextStyle(
                  color: LabColors.textDim,
                  fontSize: 10,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 11)),
        ),
      ]),
    );
  }
}

class _SingleIdleNote extends StatelessWidget {
  const _SingleIdleNote();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'No rotation for this outfit — single idleUrl only. '
          'Sophi Summers (Date/Casual) and Bella Vaunt (Casual/Date/Swim) '
          'have curated idle playlists.',
          style: TextStyle(
              color: LabColors.textDim, fontSize: 12, height: 1.4),
        ),
      );
}

class _RotationNote extends StatelessWidget {
  const _RotationNote();
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
          'Per-session rotation: resolveOutfit() picks one idle URL '
          'randomly per session from the outfit\'s idleUrls list, per '
          'port spec §12.1.3. SHUFFLE forces a rebuild so a fresh pick '
          'lands. Per-loop cycling (advance to next URL each time the '
          'idle video ends) is a future SDK add — the current SDK sticks '
          'with the same URL until the session rebuilds.',
          style: TextStyle(
              color: LabColors.textDim, fontSize: 11, height: 1.4),
        ),
      );
}
