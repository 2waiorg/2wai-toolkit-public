// Construction panel — rebuild-required knobs. Toggling any of these
// bumps LabState.rebuildToken and the shell re-mounts TwaiPlayer.
//
// Everything-on-by-default:
//   env      = staging
//   idle     = network (uses outfit.idleUrl)
//   sink     = auto (SDK picks per platform)
//   creds    = anonymous (staging)
//   autoConnect = true
//   fadeDuration = 200ms
//
// The Sink knob is disabled with a "coming P2" note — the SDK exposes
// sinkFactory but wiring the three concrete factories requires a per-
// platform lookup we'll centralize in P2.7 sink_panel.

import 'package:flutter/material.dart';

import '../lab_state.dart';
import '../lab_shell.dart' show LabRow;
import '../theme.dart';

class ConstructionPanel extends StatelessWidget {
  final LabState state;
  const ConstructionPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) => ListView(
          children: [
            const LabSectionHeader(
              label: 'ENVIRONMENT',
              hint: 'Which gateway the SDK talks to.',
            ),
            _EnvRow(
              value: EnvKind.staging,
              label: 'twaiStaging',
              sub: 'staging.coreledgergroup.com — default',
              state: state,
            ),
            _EnvRow(
              value: EnvKind.prod,
              label: 'twaiProd',
              sub: '2wai.ai production',
              state: state,
            ),
            _EnvRow(
              value: EnvKind.twaiApi,
              label: 'twaiApi',
              sub: 'api.2wai.ai gateway (twai-api transport)',
              state: state,
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'CONNECTION',
              hint: 'Autoconnect + timing knobs.',
            ),
            LabRow(
              label: 'autoConnect',
              sub: 'connect() runs automatically on mount',
              trailing: Switch(
                value: state.autoConnect,
                onChanged: (v) => state.autoConnect = v,
              ),
            ),
            LabRow(
              label: 'fadeDuration',
              sub: '${state.fadeDuration.inMilliseconds}ms crossfade between idle ↔ live',
              trailing: SizedBox(
                width: 140,
                child: Slider(
                  value: state.fadeDuration.inMilliseconds.toDouble(),
                  min: 0,
                  max: 1000,
                  divisions: 20,
                  onChanged: (v) => state.fadeDuration =
                      Duration(milliseconds: v.round()),
                ),
              ),
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'SINK (coming P2.7)',
              hint: 'Sink override — pick which fMP4 delivery pipeline runs.',
            ),
            const _DisabledNote(
              text:
                  'Sink factory override lands in P2.7 (dev-mode only). '
                  'For now the SDK auto-selects: WebMseStreamSink on web, '
                  'VideoPlayerMseStreamSink on iOS/Android, '
                  'MediaKitMseStreamSink on Windows.',
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'PATH PREFIX',
              hint:
                  "The pipeline URL prefix. Default '/ext-api-muse' for penthouse; "
                  "override to route via a proxy or alternate stack.",
            ),
            _PathPrefixField(state: state),
            const SizedBox(height: 24),
          ],
        ),
      );
}

class _EnvRow extends StatelessWidget {
  final EnvKind value;
  final String label;
  final String sub;
  final LabState state;
  const _EnvRow({
    required this.value,
    required this.label,
    required this.sub,
    required this.state,
  });
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => state.env = value,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: state.env == value ? LabColors.chrome : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: state.env == value
                    ? LabColors.accent
                    : Colors.transparent,
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
                  color: state.env == value
                      ? LabColors.accent
                      : LabColors.border,
                  width: 2,
                ),
                color: state.env == value
                    ? LabColors.accent
                    : Colors.transparent,
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
                          fontWeight: FontWeight.w700,
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
          ]),
        ),
      );
}

class _PathPrefixField extends StatefulWidget {
  final LabState state;
  const _PathPrefixField({required this.state});
  @override
  State<_PathPrefixField> createState() => _PathPrefixFieldState();
}

class _PathPrefixFieldState extends State<_PathPrefixField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.state.pathPrefixOverride ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                hintText: '/ext-api-muse (default)',
                hintStyle: TextStyle(color: LabColors.textMuted),
              ),
              style: const TextStyle(color: LabColors.text, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () {
              final v = _ctrl.text.trim();
              widget.state.pathPrefixOverride = v.isEmpty ? null : v;
            },
            child: const Text('APPLY'),
          ),
        ]),
      );
}

class _DisabledNote extends StatelessWidget {
  final String text;
  const _DisabledNote({required this.text});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LabColors.chrome,
          border: Border.all(color: LabColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(
                color: LabColors.textDim, fontSize: 12, height: 1.4)),
      );
}
