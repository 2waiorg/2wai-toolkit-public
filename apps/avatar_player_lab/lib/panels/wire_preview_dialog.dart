// In-app scrub playback for the captured wire bytes. Opens as a full-
// screen dialog with a VideoPlayer widget + native scrubber.
//
// Caveat: the concatenated bytes only form a playable clip if the
// recording started BEFORE the SDK issued its init segment. If you
// STOP + START without a session rebuild, the second recording will
// be missing the init and preview will show a broken clip.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import '../wire_save.dart';

Future<void> showWirePreviewDialog(
  BuildContext context, {
  required Uint8List bytes,
}) async {
  return showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _WirePreviewDialog(bytes: bytes),
  );
}

class _WirePreviewDialog extends StatefulWidget {
  final Uint8List bytes;
  const _WirePreviewDialog({required this.bytes});
  @override
  State<_WirePreviewDialog> createState() => _WirePreviewDialogState();
}

class _WirePreviewDialogState extends State<_WirePreviewDialog> {
  VideoPlayerController? _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final ctrl = await controllerForBytes(widget.bytes);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      _ctrl = ctrl;
      await ctrl.setLooping(false);
      await ctrl.play();
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Preview failed: $e\n\n'
          'The concatenated buffer needs the pipeline init segment at the '
          'start to play. If you STOPped + STARTed without rebuilding the '
          'stage, the second capture is missing the init — clear + rebuild '
          'and try again.');
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: LabColors.stage,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: LabColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: LabColors.chrome,
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(children: [
                const Icon(Icons.play_circle_outline,
                    size: 16, color: LabColors.accent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'WIRE PREVIEW — captured buffer',
                    style: TextStyle(
                        color: LabColors.text,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                        fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  color: LabColors.textDim,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),
            Expanded(
              child: _error != null
                  ? _ErrorView(message: _error!)
                  : _ctrl == null
                      ? const _LoadingView()
                      : _PlayerView(controller: _ctrl!),
            ),
          ]),
        ),
      );
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();
  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: LabColors.accent),
            SizedBox(height: 12),
            Text('Muxing preview…',
                style: TextStyle(color: LabColors.textDim, fontSize: 12)),
          ],
        ),
      );
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Text(message,
            style: const TextStyle(
                color: LabColors.textDim, fontSize: 12, height: 1.5)),
      );
}

class _PlayerView extends StatefulWidget {
  final VideoPlayerController controller;
  const _PlayerView({required this.controller});
  @override
  State<_PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<_PlayerView> {
  Timer? _tick;
  @override
  void initState() {
    super.initState();
    // Repaint the scrubber row 5x/sec.
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
    widget.controller.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    return Column(children: [
      Expanded(
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: v.aspectRatio == 0 ? 9 / 16 : v.aspectRatio,
              child: VideoPlayer(widget.controller),
            ),
          ),
        ),
      ),
      Container(
        color: LabColors.chrome,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(children: [
          IconButton(
            icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow,
                color: LabColors.accent),
            onPressed: () {
              if (v.isPlaying) {
                widget.controller.pause();
              } else {
                widget.controller.play();
              }
            },
          ),
          Text(_fmt(v.position),
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 12)),
          Expanded(
            child: Slider(
              value: v.position.inMilliseconds
                  .clamp(0, v.duration.inMilliseconds)
                  .toDouble(),
              min: 0,
              max: v.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (ms) => widget.controller
                  .seekTo(Duration(milliseconds: ms.round())),
            ),
          ),
          Text(_fmt(v.duration),
              style: const TextStyle(
                  color: LabColors.textDim,
                  fontFamily: 'monospace',
                  fontSize: 12)),
        ]),
      ),
    ]);
  }
}

String _fmt(Duration d) {
  final s = d.inSeconds;
  final mm = (s ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}
