// Sink panel — DEV MODE ONLY.
//
// The VideoSink is what actually renders the fMP4 stream on-screen.
// The SDK auto-picks per platform (WebMseStreamSink on web, otherwise
// VideoPlayerMseStreamSink). This panel forces an override — useful
// for A/B'ing sink behavior on the same platform, or verifying that a
// consumer's custom sinkFactory would be constructed correctly.
//
// Overrides live in LabState.sinkKind and take effect via
// lab_shell.dart's _sinkFactoryFor() → TwaiPlayer.sinkFactory. Every
// override bumps rebuildToken so the stage re-mounts with the new sink.

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../lab_state.dart';
import '../theme.dart';

class SinkPanel extends StatelessWidget {
  final LabState state;
  const SinkPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          final platform = _platformLabel();
          const autoChoice = kIsWeb ? 'WebMseStreamSink' : 'VideoPlayerMseStreamSink';
          return ListView(
            children: [
              Container(
                color: LabColors.chrome,
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(children: [
                  const Icon(Icons.settings_input_component,
                      size: 16, color: LabColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'VideoSink — currently: ${_currentLabel(state.sinkKind, autoChoice)}',
                      style: const TextStyle(
                          color: LabColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: LabColors.border),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(platform.toUpperCase(),
                        style: const TextStyle(
                            color: LabColors.textDim,
                            fontSize: 9,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800)),
                  ),
                ]),
              ),
              const Divider(),
              const LabSectionHeader(
                label: 'SINK OVERRIDE',
                hint:
                    'AUTO uses the SDK\'s default per-platform pick '
                    '($autoChoice on this device). Override to force a '
                    'specific sink — useful for A/B testing behavior.',
              ),
              _SinkRow(
                value: SinkKind.auto,
                label: 'AUTO',
                sub: 'SDK auto-picks — WebMse on web, VideoPlayer otherwise.',
                state: state,
              ),
              _SinkRow(
                value: SinkKind.webMse,
                label: 'WebMseStreamSink',
                sub: kIsWeb
                    ? 'Real MSE tail-following sink. Web-only; the SDK\'s '
                        'default choice on this device.'
                    : 'Web-only sink. Throws UnsupportedError on this '
                        'platform — falls back to AUTO.',
                state: state,
                disabled: !kIsWeb,
              ),
              _SinkRow(
                value: SinkKind.videoPlayer,
                label: 'VideoPlayerMseStreamSink',
                sub: 'Accumulate-then-play. Works on all platforms; the '
                    'SDK\'s default on iOS / Android / desktop.',
                state: state,
              ),
              _SinkRow(
                value: SinkKind.mediaKit,
                label: 'MediaKitMseStreamSink',
                sub: 'libmpv tail-follower (best on Windows). Not linked '
                    'in this app — add twai_avatar_sdk_media_kit to '
                    'pubspec + wire in lab_shell.dart:_sinkFactoryFor.',
                state: state,
                disabled: true,
              ),
              const SizedBox(height: 12),
              const _RoadmapNote(),
              const SizedBox(height: 24),
            ],
          );
        },
      );

  String _platformLabel() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name;
  }

  String _currentLabel(SinkKind kind, String autoChoice) {
    switch (kind) {
      case SinkKind.auto:
        return '$autoChoice (auto)';
      case SinkKind.webMse:
        return kIsWeb ? 'WebMseStreamSink' : '$autoChoice (auto — WebMse unavailable)';
      case SinkKind.videoPlayer:
        return 'VideoPlayerMseStreamSink';
      case SinkKind.mediaKit:
        return '$autoChoice (auto — MediaKit not linked)';
    }
  }
}

class _SinkRow extends StatelessWidget {
  final SinkKind value;
  final String label;
  final String sub;
  final LabState state;
  final bool disabled;
  const _SinkRow({
    required this.value,
    required this.label,
    required this.sub,
    required this.state,
    this.disabled = false,
  });
  @override
  Widget build(BuildContext context) {
    final selected = state.sinkKind == value;
    return InkWell(
      onTap: disabled ? null : () => state.sinkKind = value,
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
                        fontSize: 13,
                        fontFamily: value == SinkKind.auto ? null : 'monospace')),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: TextStyle(
                          color: disabled
                              ? LabColors.textMuted
                              : LabColors.textDim,
                          fontSize: 11,
                          height: 1.35)),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _RoadmapNote extends StatelessWidget {
  const _RoadmapNote();
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
          'Under the hood: TwaiPlayer.sinkFactory takes a '
          'TwaiSinkFactory = VideoSink Function(TwaiAvatarPlayerController). '
          'The SDK\'s _defaultSink() picks WebMseStreamSink on web and '
          'VideoPlayerMseStreamSink everywhere else. Consumer apps add '
          'their own factory to swap in MediaKit on Windows, or to A/B '
          'a custom sink implementation. Any override reaches the wire '
          'immediately on rebuild — no other client code changes needed.',
          style: TextStyle(
              color: LabColors.textDim, fontSize: 11, height: 1.4),
        ),
      );
}
