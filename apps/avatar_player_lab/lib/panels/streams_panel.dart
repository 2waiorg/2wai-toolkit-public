// Streams panel — live tail of every event stream on the handle.
//
// Everything-on-by-default: all 7 stream kinds visible. Filter chips at
// the top hide individual kinds. Auto-scroll on. Rolling buffer capped
// at 500 entries.
//
// The panel no longer subscribes to the handle's streams directly —
// LabState owns those subscriptions and buffers events in its
// [LabState.eventLog]. Broadcast streams don't replay past events to
// late subscribers; before this refactor the initial `connecting →
// ready` transition landed before the panel had mounted (especially on
// a tab that hadn't been visited), and STREAMS looked empty. LabState
// is always-on so nothing gets lost.

import 'package:flutter/material.dart';

import '../lab_state.dart';
import '../theme.dart';

class StreamsPanel extends StatefulWidget {
  final LabState state;
  const StreamsPanel({super.key, required this.state});
  @override
  State<StreamsPanel> createState() => _StreamsPanelState();
}

class _StreamsPanelState extends State<StreamsPanel> {
  final Map<LabEventKind, bool> _enabled = {
    for (final k in LabEventKind.values) k: true,
  };
  bool _autoScroll = true;
  bool _paused = false;
  final _scrollCtrl = ScrollController();
  int _lastSeq = -1;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _maybeAutoScroll() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.state,
        builder: (_, __) {
          // Filter events per the chip toggles, then optionally freeze
          // the tail while PAUSED.
          final all = widget.state.eventLog;
          final visible = [
            for (final e in all)
              if (_enabled[e.kind] == true) e,
          ];
          if (!_paused && widget.state.eventSeq != _lastSeq) {
            _lastSeq = widget.state.eventSeq;
            _maybeAutoScroll();
          }
          return Column(children: [
            _FilterBar(
              enabled: _enabled,
              autoScroll: _autoScroll,
              paused: _paused,
              onToggleStream: (k, v) => setState(() => _enabled[k] = v),
              onToggleAutoScroll: (v) => setState(() => _autoScroll = v),
              onTogglePause: (v) => setState(() => _paused = v),
              onClear: widget.state.clearEventLog,
            ),
            const Divider(),
            Expanded(
              child: visible.isEmpty
                  ? const _EmptyLog()
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      itemCount: visible.length,
                      itemBuilder: (_, i) => _EntryRow(entry: visible[i]),
                    ),
            ),
          ]);
        },
      );
}

class _FilterBar extends StatelessWidget {
  final Map<LabEventKind, bool> enabled;
  final bool autoScroll;
  final bool paused;
  final void Function(LabEventKind, bool) onToggleStream;
  final ValueChanged<bool> onToggleAutoScroll;
  final ValueChanged<bool> onTogglePause;
  final VoidCallback onClear;
  const _FilterBar({
    required this.enabled,
    required this.autoScroll,
    required this.paused,
    required this.onToggleStream,
    required this.onToggleAutoScroll,
    required this.onTogglePause,
    required this.onClear,
  });
  @override
  Widget build(BuildContext context) => Container(
        color: LabColors.chrome,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in LabEventKind.values)
              FilterChip(
                selected: enabled[k]!,
                label: Text(_labelFor(k),
                    style: const TextStyle(fontSize: 10, letterSpacing: 0.8)),
                onSelected: (v) => onToggleStream(k, v),
                selectedColor: LabColors.accent,
                checkmarkColor: LabColors.accentOn,
                backgroundColor: LabColors.panel,
                side: const BorderSide(color: LabColors.border),
                showCheckmark: true,
                labelStyle: TextStyle(
                    color: enabled[k]! ? LabColors.accentOn : LabColors.textDim),
              ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            _ToolChip(
              label: paused ? 'PAUSED' : 'LIVE',
              icon: paused ? Icons.play_arrow : Icons.pause,
              color: paused ? LabColors.wait : LabColors.live,
              onTap: () => onTogglePause(!paused),
            ),
            const SizedBox(width: 6),
            _ToolChip(
              label: autoScroll ? 'AUTOSCROLL' : 'HOLD',
              icon: autoScroll
                  ? Icons.vertical_align_bottom
                  : Icons.vertical_align_center,
              color: autoScroll ? LabColors.accent : LabColors.textDim,
              onTap: () => onToggleAutoScroll(!autoScroll),
            ),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, size: 14),
              label: const Text('CLEAR'),
              onPressed: onClear,
            ),
          ]),
        ]),
      );

  static String _labelFor(LabEventKind k) => switch (k) {
        LabEventKind.status => 'STATUS',
        LabEventKind.replyText => 'REPLY',
        LabEventKind.speaking => 'SPEAKING',
        LabEventKind.mood => 'MOOD',
        LabEventKind.xp => 'XP',
        LabEventKind.levelUp => 'LEVEL',
        LabEventKind.overlay => 'OVERLAY',
      };
}

class _ToolChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ToolChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 10,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w800)),
          ]),
        ),
      );
}

class _EntryRow extends StatelessWidget {
  final LabEvent entry;
  const _EntryRow({required this.entry});
  @override
  Widget build(BuildContext context) {
    final ts = entry.at;
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    final ms = ts.millisecond.toString().padLeft(3, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DefaultTextStyle(
        style: const TextStyle(
            color: LabColors.text,
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.35),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$hh:$mm:$ss.$ms',
              style: const TextStyle(color: LabColors.textMuted)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: _colorFor(entry.kind).withValues(alpha: 0.15),
              border: Border.all(color: _colorFor(entry.kind)),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(_labelFor(entry.kind),
                style: TextStyle(
                    color: _colorFor(entry.kind),
                    fontSize: 9,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(entry.text)),
        ]),
      ),
    );
  }

  static String _labelFor(LabEventKind k) => switch (k) {
        LabEventKind.status => 'STAT',
        LabEventKind.replyText => 'RPLY',
        LabEventKind.speaking => 'SPK ',
        LabEventKind.mood => 'MOOD',
        LabEventKind.xp => 'XP  ',
        LabEventKind.levelUp => 'LVL ',
        LabEventKind.overlay => 'OVLY',
      };

  static Color _colorFor(LabEventKind k) => switch (k) {
        LabEventKind.status => LabColors.live,
        LabEventKind.replyText => LabColors.accent,
        LabEventKind.speaking => LabColors.wait,
        LabEventKind.mood => Colors.purpleAccent,
        LabEventKind.xp => Colors.orangeAccent,
        LabEventKind.levelUp => Colors.cyanAccent,
        LabEventKind.overlay => Colors.pinkAccent,
      };
}

class _EmptyLog extends StatelessWidget {
  const _EmptyLog();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'STREAMS surfaces every event the SDK publishes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: LabColors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              'A consumer app subscribes to a subset of these to drive UI:\n'
              'mood → color badge · xp → progress ring · levelUp → celebration\n'
              'reply → chat log · speaking → mic mute · overlay → gesture render.\n\n'
              'Send a message from METHODS to see events land.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: LabColors.textDim, fontSize: 12, height: 1.5),
            ),
          ]),
        ),
      );
}
