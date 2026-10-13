// Runtime methods panel — invoke every public method on TwaiPlayerHandle.
//
// Handle lookup is lazy — every button grabs LabState.currentHandle at
// tap time, so if the shell is between-rebuilds the tap gracefully errors
// out with a snack instead of crashing.

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import '../known_avatars.dart' show kKnownVoices;
import '../lab_state.dart';
import '../lab_shell.dart' show LabRow, showLabSnack;
import '../theme.dart';

class RuntimeMethodsPanel extends StatefulWidget {
  final LabState state;
  const RuntimeMethodsPanel({super.key, required this.state});
  @override
  State<RuntimeMethodsPanel> createState() => _RuntimeMethodsPanelState();
}

class _RuntimeMethodsPanelState extends State<RuntimeMethodsPanel> {
  final _sendCtrl = TextEditingController();
  final _sendFocus = FocusNode();
  final _voiceCtrl = TextEditingController();
  int _xpAmount = 25;
  String? _lastGreetingAvatarName;
  // In-flight indicators — tap feedback so the tester never wonders
  // "did that actually go?" while the async call is still on the wire.
  bool _sending = false;
  String? _switchingOutfitSlug;
  bool _switchingVoice = false;
  // Persistent echo of the last successful send. Sits below the SEND
  // row until the next send fires. STREAMS shows the reply after the
  // fact; this shows the user's own turn immediately.
  String? _lastSentEcho;
  DateTime? _lastSentAt;

  @override
  void initState() {
    super.initState();
    // Prefill with a greeting for the boot avatar; keep it in sync on
    // avatar changes as long as the user hasn't manually typed anything
    // that isn't a greeting for the previous avatar.
    widget.state.addListener(_syncGreeting);
    _syncGreeting();
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncGreeting);
    _sendCtrl.dispose();
    _sendFocus.dispose();
    _voiceCtrl.dispose();
    super.dispose();
  }

  void _syncGreeting() {
    if (!mounted) return;
    // NEVER touch the field while the user is typing. LabState fires
    // notifyListeners() on every engine event (state ticks, reply
    // deltas, speaking transitions, etc — see lab_state.dart:485
    // `pushEvent`), so a mid-typing engine event would trigger this
    // listener, mutate `_sendCtrl.text`, and reset the cursor —
    // which is exactly the "loses letters + refresh" symptom.
    if (_sendFocus.hasFocus) return;
    final currentName = widget.state.avatar.avatar.name;
    // Extract first name (Sophi Summers → Sophi, Dr. Alman → Dr., etc.)
    final greeting = 'Hey ${_shortName(currentName)}, how are you?';
    // Update the field only if:
    //  - it's empty, OR
    //  - it currently holds the greeting for a previous avatar
    final current = _sendCtrl.text;
    final prevGreeting = _lastGreetingAvatarName != null
        ? 'Hey ${_shortName(_lastGreetingAvatarName!)}, how are you?'
        : null;
    if (current.isEmpty ||
        current == prevGreeting ||
        current == 'Hey Sophi, how are you?') {
      _sendCtrl.text = greeting;
    }
    _lastGreetingAvatarName = currentName;
  }

  String _shortName(String fullName) {
    // "Sophi Summers" → "Sophi", "Dr. Alman" → "Dr. Alman", "Mila" → "Mila"
    final parts = fullName.split(' ');
    if (parts.length >= 2 && parts.first.endsWith('.')) return fullName;
    return parts.first;
  }

  TwaiPlayerHandle? _requireHandle(BuildContext ctx) {
    final h = widget.state.currentHandle;
    if (h == null) {
      showLabSnack(ctx, 'No live handle — stage is rebuilding.', bad: true);
    }
    return h;
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _sendCtrl.text.trim();
    if (text.isEmpty) return;
    // A previous transient failure must not remain over a healthy retry.
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    // Transport 0 (LiveKit) path: engine, not handle. The two are
    // mutually exclusive on the LiveKit adapter. Falling through to
    // the handle path when the engine is live would silently no-op
    // because currentHandle stays null on Transport 0.
    final t0Engine = widget.state.currentTransport0Engine;
    setState(() => _sending = true);
    try {
      if (t0Engine != null) {
        await t0Engine.send(text);
      } else {
        final h = _requireHandle(context);
        if (h == null) {
          setState(() => _sending = false);
          return;
        }
        await h.send(text);
      }
      if (mounted) {
        setState(() {
          _sending = false;
          _lastSentEcho = text;
          _lastSentAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showLabSnack(context, 'send failed: $e', bad: true);
      }
    }
  }

  Future<void> _switchOutfit(String slug) async {
    if (_switchingOutfitSlug != null) return;
    final outfit = widget.state.avatar.avatar.outfits
        .firstWhere((o) => o.slug == slug);
    // Update the highlight immediately so the tap feels responsive;
    // the async switch happens in the background and the spinner
    // overlay on the chip surfaces the in-flight state.
    setState(() => _switchingOutfitSlug = slug);
    widget.state.outfitSlug = slug;

    // Transport 0: mirrors PP's `switchOutfit` at
    // `clg_penthouse_pets/frontend/src/lean/controller.ts:7453-7513` —
    // teardown() + connect(avatar, resolvedOutfit). Each outfit has
    // its own tenant avt_ id → different pipeline_name → the broker
    // has to mint a fresh room with the new plates. There is no
    // live-swap; sending the same rebuildToken bump we already use
    // for avatar swap triggers the exact same tear-down + reconnect
    // path (which is proven-working). Widget rebuild takes over the
    // visual feedback (the connecting spinner) so the chip spinner
    // clears immediately.
    final t0Engine = widget.state.currentTransport0Engine;
    if (t0Engine != null) {
      widget.state.bumpRebuild();
      if (mounted) setState(() => _switchingOutfitSlug = null);
      return;
    }

    // Adapter 1 / 4 (historical): use handle.switchOutfit() live-swap.
    // Reconstructs the session under the hood but keeps the same
    // TwaiPlayerHandle — no widget rebuild.
    final h = _requireHandle(context);
    if (h == null) {
      if (mounted) setState(() => _switchingOutfitSlug = null);
      return;
    }
    try {
      await h.switchOutfit(outfit);
    } catch (e) {
      if (mounted) showLabSnack(context, 'switchOutfit failed: $e', bad: true);
    } finally {
      if (mounted) setState(() => _switchingOutfitSlug = null);
    }
  }

  Future<void> _switchVoice() async {
    if (_switchingVoice) return;
    final h = _requireHandle(context);
    if (h == null) return;
    final voiceId = _voiceCtrl.text.trim();
    if (voiceId.isEmpty) {
      showLabSnack(context, 'Voice ID is required', bad: true);
      return;
    }
    setState(() => _switchingVoice = true);
    try {
      await h.switchVoice(voiceId);
      if (mounted) {
        setState(() => _switchingVoice = false);
        showLabSnack(context, 'switchVoice → $voiceId');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _switchingVoice = false);
        showLabSnack(context, 'switchVoice failed: $e', bad: true);
      }
    }
  }

  Future<void> _resetVoice() async {
    if (_switchingVoice) return;
    final h = _requireHandle(context);
    if (h == null) return;
    setState(() => _switchingVoice = true);
    try {
      await h.switchVoice(widget.state.avatar.avatar.voiceId);
      if (mounted) {
        _voiceCtrl.clear();
        setState(() => _switchingVoice = false);
        showLabSnack(context, 'Voice reset to avatar default');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _switchingVoice = false);
        showLabSnack(context, 'resetVoice failed: $e', bad: true);
      }
    }
  }

  void _awardXp() {
    final h = _requireHandle(context);
    if (h == null) return;
    h.awardXp(_xpAmount, band: XpBand.medium, reason: 'lab: manual award');
    if (mounted) {
      showLabSnack(context, 'awarded $_xpAmount XP (band=medium)');
    }
  }

  void _notifyLevelUp() {
    final h = _requireHandle(context);
    if (h == null) return;
    final level = (h.currentLevel ?? 0) + 1;
    h.notifyLevelUp(level);
    if (mounted) {
      showLabSnack(context, 'notified level-up → $level');
    }
  }

  Future<void> _reconnect() async {
    final h = _requireHandle(context);
    if (h == null) return;
    try {
      await h.manualReconnect();
      if (mounted) showLabSnack(context, 'manualReconnect() ok');
    } catch (e) {
      if (mounted) showLabSnack(context, 'reconnect failed: $e', bad: true);
    }
  }

  void _notifyOverlayEnded() {
    final h = _requireHandle(context);
    if (h == null) return;
    h.notifyOverlayEnded();
    showLabSnack(context, 'notifyOverlayEnded()');
  }

  void _rebuildStage() {
    widget.state.bumpRebuild();
    showLabSnack(context, 'Stage rebuild — new handle constructed');
  }

  @override
  Widget build(BuildContext context) {
    // SEND section — extracted as a STABLE subtree so it doesn't rebuild
    // on every LabState.notifyListeners. LabState fires notify per engine
    // event (state ticks, reply deltas, speaking transitions — all via
    // pushEvent). If the TextField rebuilds mid-typing, Flutter web's
    // hidden HTML input backing it destabilises and drops characters.
    //
    // Passed as AnimatedBuilder's `child:` parameter below — Flutter
    // hands the same instance to every builder call, so the TextField
    // element persists and its IME wiring stays connected.
    final sendSection = _SendSection(
      controller: _sendCtrl,
      focus: _sendFocus,
      sending: _sending,
      lastEcho: _lastSentEcho,
      lastEchoAt: _lastSentAt,
      onSubmit: _send,
    );
    return AnimatedBuilder(
      animation: widget.state,
      child: sendSection,
      builder: (_, sendSectionChild) => ListView(
        children: [
          sendSectionChild!,
          const Divider(),
            LabSectionHeader(
              label: 'OUTFITS',
              hint:
                  'switchOutfit() live-swap for ${widget.state.avatar.avatar.name}. '
                  'Tapping a chip calls handle.switchOutfit() — no stage rebuild; '
                  'idle crossfades to the new outfit. Names come from '
                  'PlayerOutfit.name in known_avatars.dart.',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in widget.state.avatar.avatar.outfits)
                    _OutfitChip(
                      label: o.name.toUpperCase(),
                      selected: o.slug == widget.state.outfitSlug,
                      switching: _switchingOutfitSlug == o.slug,
                      disabled: _switchingOutfitSlug != null &&
                          _switchingOutfitSlug != o.slug,
                      onTap: () => _switchOutfit(o.slug),
                    ),
                ],
              ),
            ),
            const Divider(),
            LabSectionHeader(
              label: 'VOICE',
              hint:
                  'switchVoice() live-swap. Both adapters reconstruct the '
                  'session under the hood — quick flicker to spinner, then '
                  'the next speak-turn is in the new voice.',
              trailing: OutlinedButton.icon(
                icon: const Icon(Icons.restart_alt, size: 14),
                label: const Text('RESET'),
                onPressed: _resetVoice,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _voiceCtrl,
                    decoration: InputDecoration(
                      hintText:
                          'current: ${widget.state.currentHandle?.effectiveVoiceId ?? widget.state.avatar.avatar.voiceId}',
                      hintStyle: const TextStyle(color: LabColors.textMuted),
                    ),
                    style: const TextStyle(
                        color: LabColors.text,
                        fontFamily: 'monospace',
                        fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: _switchingVoice
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: LabColors.accent),
                        )
                      : const Icon(Icons.swap_horiz, size: 14),
                  label: Text(_switchingVoice ? '…' : 'SWITCH'),
                  onPressed: _switchingVoice ? null : _switchVoice,
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text('KNOWN VOICES (tap to prefill)',
                        style: TextStyle(
                            color: LabColors.textDim,
                            fontSize: 10,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800)),
                  ),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final v in kKnownVoices)
                      Tooltip(
                        message: '${v.id}\n${v.origin}',
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                          ),
                          onPressed: () {
                            _voiceCtrl.text = v.id;
                            setState(() {});
                          },
                          child: Text(v.label,
                              style: const TextStyle(
                                  fontSize: 10,
                                  letterSpacing: 0.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ]),
                ],
              ),
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'PROGRESSION',
              hint:
                  'XP/level events. Deliver at ready-transitions; queue if speaking.',
            ),
            LabRow(
              label: 'XP amount',
              sub: 'awardXp(amount, band: medium)',
              trailing: SizedBox(
                width: 140,
                child: Slider(
                  value: _xpAmount.toDouble(),
                  min: 5,
                  max: 200,
                  divisions: 39,
                  label: '$_xpAmount',
                  onChanged: (v) => setState(() => _xpAmount = v.round()),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.star_border, size: 16),
                  label: Text('AWARD $_xpAmount XP'),
                  onPressed: _awardXp,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  label: const Text('NOTIFY LEVEL-UP'),
                  onPressed: _notifyLevelUp,
                ),
              ]),
            ),
            const Divider(),
            const LabSectionHeader(
              label: 'GESTURES / FRAMES',
              hint:
                  'playGesture + playFrame are wired to the SDK catalog. Live picker '
                  'lands in P3 once switchVoice + zoom/pan-lock land alongside.',
            ),
            const _StubNote(
                text:
                    'Gesture/frame catalogs are auto-fetched by TwaiPlayer '
                    '(autoFetchGestures/autoFetchFrames on). P3 adds a live picker.'),
            const Divider(),
            const LabSectionHeader(
              label: 'SESSION',
              hint: 'Connection lifecycle.',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('MANUAL RECONNECT'),
                  onPressed: _reconnect,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('NOTIFY OVERLAY ENDED'),
                  onPressed: _notifyOverlayEnded,
                ),
                Tooltip(
                  message:
                      'Bumps LabState.rebuildToken. The shell disposes the '
                      'current TwaiPlayerHandle and constructs a fresh one, '
                      're-mounting TwaiPlayer with all current construction '
                      'knobs (avatar / transport / env / autoConnect / etc). '
                      'Use after changing something that only takes effect at '
                      'session-start (e.g. shuffling curated idle playlist).',
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.build_outlined, size: 16),
                    label: const Text('REBUILD STAGE'),
                    onPressed: _rebuildStage,
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 24),
          ],
        ),
      );
  }
}

class _StubNote extends StatelessWidget {
  final String text;
  const _StubNote({required this.text});
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

/// Stable SEND subtree. Extracted so it's passed as `AnimatedBuilder.child:`
/// and reused across every LabState notify — Flutter reuses the same
/// element, TextField's Flutter-web IME wiring stays stable, characters
/// don't drop.
class _SendSection extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final bool sending;
  final String? lastEcho;
  final DateTime? lastEchoAt;
  final VoidCallback onSubmit;

  const _SendSection({
    required this.controller,
    required this.focus,
    required this.sending,
    required this.lastEcho,
    required this.lastEchoAt,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LabSectionHeader(
            label: 'SEND',
            hint: 'Post text to the pipeline. Reply streams back on replyText.',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              controller: controller,
              focusNode: focus,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: LabColors.accentOn),
                      )
                    : const Icon(Icons.send, size: 16),
                label: Text(sending ? 'SENDING…' : 'SEND'),
                onPressed: sending ? null : onSubmit,
              ),
            ),
          ),
          if (lastEcho != null && lastEchoAt != null)
            _SentEchoRow(text: lastEcho!, at: lastEchoAt!),
        ],
      );
}

/// Persistent "you sent this" row below the SEND button. Sits until the
/// next send fires — so the tester never has to wonder whether the tap
/// went through or scroll STREAMS to see what they just posted.
class _SentEchoRow extends StatelessWidget {
  final String text;
  final DateTime at;
  const _SentEchoRow({required this.text, required this.at});
  @override
  Widget build(BuildContext context) {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: LabColors.accent.withValues(alpha: 0.12),
          border: Border.all(color: LabColors.accent.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          const Icon(Icons.check_circle_outline,
              size: 12, color: LabColors.accent),
          const SizedBox(width: 6),
          const Text('SENT',
              style: TextStyle(
                  color: LabColors.accent,
                  fontSize: 9,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Text('$hh:$mm:$ss',
              style: const TextStyle(
                  color: LabColors.textMuted,
                  fontSize: 10,
                  fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: LabColors.text, fontSize: 12),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Outfit chip with an in-flight spinner overlay. Selection highlight
/// stays on even while switching; the spinner surfaces the async work.
class _OutfitChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool switching;
  final bool disabled;
  final VoidCallback onTap;
  const _OutfitChip({
    required this.label,
    required this.selected,
    required this.switching,
    required this.disabled,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final style = selected
        ? OutlinedButton.styleFrom(
            backgroundColor: LabColors.accent,
            foregroundColor: LabColors.accentOn,
          )
        : null;
    return Stack(alignment: Alignment.center, children: [
      OutlinedButton(
        style: style,
        onPressed: disabled ? null : onTap,
        child: Opacity(
          opacity: switching ? 0 : 1,
          child: Text(label),
        ),
      ),
      if (switching)
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: selected ? LabColors.accentOn : LabColors.accent,
          ),
        ),
    ]);
  }
}
