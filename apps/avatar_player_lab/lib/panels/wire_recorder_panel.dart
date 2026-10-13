// Wire recorder panel — DEV MODE ONLY.
//
// Wraps a TwaiWireRecorder (owned by this panel — one per panel-mount).
// Sources bytes from LabState.currentHandle.videoBytes.
//
// P2.2 first cut: start/stop/clear + live counters (bytes, fragments,
// duration) + a per-fragment timeline (last N shown). Download-to-file
// and in-app scrub playback land in P2.7 polish — this panel exposes the
// buffer; save + scrub are conditional-imports work best done alongside
// the sink override picker.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import '../lab_state.dart';
import '../lab_shell.dart' show showLabSnack;
import '../theme.dart';
import '../wire_save.dart';
import 'wire_preview_dialog.dart';

class WireRecorderPanel extends StatefulWidget {
  final LabState state;
  const WireRecorderPanel({super.key, required this.state});
  @override
  State<WireRecorderPanel> createState() => _WireRecorderPanelState();
}

class _WireRecorderPanelState extends State<WireRecorderPanel> {
  final TwaiWireRecorder _recorder = TwaiWireRecorder();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _recorder.addListener(_onRecorderChange);
    // While recording, tick every 200ms so the elapsed clock advances
    // visibly even in the gaps between fragments.
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_recorder.state == WireRecorderState.recording && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _recorder.removeListener(_onRecorderChange);
    _recorder.dispose();
    super.dispose();
  }

  void _onRecorderChange() {
    if (mounted) setState(() {});
  }

  void _start() {
    final h = widget.state.currentHandle;
    if (h == null) {
      showLabSnack(context, 'No live handle — stage is rebuilding.', bad: true);
      return;
    }
    _recorder.start(h.videoBytes);
    showLabSnack(context, 'Recording started');
  }

  void _stop() {
    _recorder.stop();
    showLabSnack(context, 'Recording stopped');
  }

  void _clear() {
    _recorder.clear();
    showLabSnack(context, 'Buffer cleared');
  }

  Future<void> _save() async {
    if (_recorder.bytesCount == 0) {
      showLabSnack(context, 'Buffer empty — nothing to save.', bad: true);
      return;
    }
    try {
      final saved = await saveWireCapture(_recorder.getBytes());
      if (!mounted) return;
      showLabSnack(context,
          'Saved ${_formatBytes(saved.byteLength)} → ${saved.path}');
    } catch (e) {
      if (mounted) showLabSnack(context, 'Save failed: $e', bad: true);
    }
  }

  Future<void> _preview() async {
    if (_recorder.bytesCount == 0) {
      showLabSnack(context, 'Buffer empty — record something first.', bad: true);
      return;
    }
    await showWirePreviewDialog(context, bytes: _recorder.getBytes());
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Container(
          color: LabColors.chrome,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(children: [
            const Icon(Icons.fiber_manual_record,
                size: 16, color: LabColors.bad),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'TwaiWireRecorder — bit-exact fMP4 capture from handle.videoBytes',
                style: TextStyle(
                    color: LabColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
            _StateBadge(state: _recorder.state),
          ]),
        ),
        const Divider(),
        _Counters(recorder: _recorder),
        const Divider(),
        _Controls(
          state: _recorder.state,
          hasBuffer: _recorder.bytesCount > 0,
          onStart: _start,
          onStop: _stop,
          onClear: _clear,
          onSave: _save,
          onPreview: _preview,
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            const Text('FRAGMENTS (newest first)',
                style: TextStyle(
                    color: LabColors.textDim,
                    fontSize: 10,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('${_recorder.fragmentCount} total',
                style: const TextStyle(
                    color: LabColors.textDim, fontSize: 11)),
          ]),
        ),
        Expanded(
          child: _recorder.fragments.isEmpty
              ? const _EmptyFragments()
              : _FragmentList(fragments: _recorder.fragments),
        ),
        const Divider(),
        const _RoadmapNote(),
      ]);
}

class _StateBadge extends StatelessWidget {
  final WireRecorderState state;
  const _StateBadge({required this.state});
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      WireRecorderState.idle => ('IDLE', LabColors.textDim),
      WireRecorderState.recording => ('REC', LabColors.bad),
      WireRecorderState.stopped => ('STOP', LabColors.wait),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label,
          style: TextStyle(
              color: color,
              fontSize: 9,
              letterSpacing: 1,
              fontWeight: FontWeight.w800)),
    );
  }
}

class _Counters extends StatelessWidget {
  final TwaiWireRecorder recorder;
  const _Counters({required this.recorder});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          _Metric(label: 'BYTES', value: _formatBytes(recorder.bytesCount)),
          const SizedBox(width: 20),
          _Metric(
              label: 'FRAGS', value: '${recorder.fragmentCount}'),
          const SizedBox(width: 20),
          _Metric(
              label: 'DURATION',
              value: _formatDuration(recorder.elapsed)),
        ]),
      );
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: LabColors.textDim,
                  fontSize: 9,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ],
      );
}

class _Controls extends StatelessWidget {
  final WireRecorderState state;
  final bool hasBuffer;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onClear;
  final VoidCallback onSave;
  final VoidCallback onPreview;
  const _Controls({
    required this.state,
    required this.hasBuffer,
    required this.onStart,
    required this.onStop,
    required this.onClear,
    required this.onSave,
    required this.onPreview,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (state != WireRecorderState.recording)
            ElevatedButton.icon(
              icon: const Icon(Icons.fiber_manual_record, size: 16),
              label: const Text('START'),
              onPressed: onStart,
              style: ElevatedButton.styleFrom(
                backgroundColor: LabColors.bad,
                foregroundColor: Colors.white,
              ),
            )
          else
            ElevatedButton.icon(
              icon: const Icon(Icons.stop, size: 16),
              label: const Text('STOP'),
              onPressed: onStop,
              style: ElevatedButton.styleFrom(
                backgroundColor: LabColors.wait,
                foregroundColor: LabColors.stage,
              ),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_circle_outline, size: 14),
            label: const Text('PREVIEW'),
            onPressed: hasBuffer ? onPreview : null,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.download_outlined, size: 14),
            label: const Text('SAVE'),
            onPressed: hasBuffer ? onSave : null,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, size: 14),
            label: const Text('CLEAR'),
            onPressed: onClear,
          ),
        ]),
      );
}

class _FragmentList extends StatelessWidget {
  final List<WireFragment> fragments;
  const _FragmentList({required this.fragments});
  @override
  Widget build(BuildContext context) {
    // Show newest first; cap to last 200 rendered rows so a long
    // recording doesn't tank the panel scroll performance.
    final visible = fragments.reversed.take(200).toList(growable: false);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: visible.length,
      itemBuilder: (_, i) {
        final f = visible[i];
        final t = f.at;
        final hh = t.hour.toString().padLeft(2, '0');
        final mm = t.minute.toString().padLeft(2, '0');
        final ss = t.second.toString().padLeft(2, '0');
        final ms = t.millisecond.toString().padLeft(3, '0');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: DefaultTextStyle(
            style: const TextStyle(
                color: LabColors.text,
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.35),
            child: Row(children: [
              Text('$hh:$mm:$ss.$ms',
                  style: const TextStyle(color: LabColors.textMuted)),
              const SizedBox(width: 8),
              Text('${f.byteLength.toString().padLeft(6)} B',
                  style: const TextStyle(color: LabColors.live)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: LabColors.bad.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor:
                        (f.byteLength / 8192).clamp(0.02, 1.0).toDouble(),
                    child: Container(
                      decoration: BoxDecoration(
                        color: LabColors.bad,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _EmptyFragments extends StatelessWidget {
  const _EmptyFragments();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No fragments captured yet.\nPress START, then send a message from METHODS to see wire bytes stream in.',
            textAlign: TextAlign.center,
            style: TextStyle(color: LabColors.textDim, fontSize: 12),
          ),
        ),
      );
}

class _RoadmapNote extends StatelessWidget {
  const _RoadmapNote();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LabColors.chrome,
          border: Border.all(color: LabColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'Bit-exact fMP4 — artifacts round-trip through Mason\'s '
          'twai-api/scripts/ CLI. PREVIEW plays the concatenated buffer '
          'in-app; SAVE writes to the app documents dir (native) or '
          'triggers a browser download (web). PREVIEW works best when '
          'you START before the first message so the pipeline init '
          'segment is captured — otherwise playback may show a broken clip.',
          style: TextStyle(
              color: LabColors.textDim, fontSize: 11, height: 1.4),
        ),
      );
}

String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String _formatDuration(Duration d) {
  final s = d.inSeconds;
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$mm:$ss.${ms.substring(0, 1)}';
}
