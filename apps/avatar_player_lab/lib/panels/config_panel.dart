// Config panel — DEV MODE ONLY.
//
// Every one of PlayerConfig's 35 knobs surfaces as a live control.
// Grouped into 8 sections that mirror the source-comment groupings:
// TIMING CORE, TIMING JITTER, RECONNECT, HEARTBEATS + DEBOUNCE,
// PROGRESSION + TOAST, MIC, BRAIN WARMUP, CODEC + RENDER.
//
// Each knob shows the current value + the SDK default (VPC = Verified
// Production Constant, or MOID = Mason-Open Inferred Default). Changing
// any value bumps rebuildToken so the fresh TwaiPlayer picks up the new
// PlayerConfig on remount. RESET ALL TO DEFAULTS button at the top
// clears every override in one tap.

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import '../lab_state.dart';
import '../lab_shell.dart' show showLabSnack;
import '../theme.dart';

class ConfigPanel extends StatelessWidget {
  final LabState state;
  const ConfigPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          final c = state.config;
          const d = PlayerConfig();
          final isDefault = _configEquals(c, d);
          return ListView(
            children: [
              Container(
                color: LabColors.chrome,
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(children: [
                  Icon(
                      isDefault
                          ? Icons.check_circle_outline
                          : Icons.tune,
                      size: 16,
                      color: isDefault ? LabColors.live : LabColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isDefault
                          ? 'PlayerConfig — all defaults (VPC + MOID)'
                          : 'PlayerConfig — overrides active',
                      style: const TextStyle(
                          color: LabColors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.restart_alt, size: 14),
                    label: const Text('RESET ALL'),
                    onPressed: isDefault
                        ? null
                        : () {
                            state.resetConfigToDefaults();
                            showLabSnack(context,
                                'PlayerConfig reset to all defaults');
                          },
                  ),
                ]),
              ),
              const Divider(),

              // ═══════════════════════════════════════════════
              const LabSectionHeader(
                label: 'TIMING — CORE',
                hint:
                    'Session-lifecycle timeouts + watchdogs. All VPC. Reference: port spec §3.',
              ),
              _DurationKnob(
                label: 'minConnectLifetime',
                sub: 'Min socket age before treating close as a flap vs. mobile glitch.',
                value: c.minConnectLifetime,
                defaultValue: d.minConnectLifetime,
                min: 500,
                max: 15000,
                onChanged: (v) =>
                    state.config = c.copyWith(minConnectLifetime: v),
              ),
              _DurationKnob(
                label: 'wsSilence',
                sub: 'Max gap between WS frames before socket declared dead.',
                value: c.wsSilence,
                defaultValue: d.wsSilence,
                min: 500,
                max: 15000,
                onChanged: (v) => state.config = c.copyWith(wsSilence: v),
              ),
              _DurationKnob(
                label: 'resumeRecovery',
                sub: 'iOS MediaSource wedge watchdog. "Tap to resume" if not playing by this.',
                value: c.resumeRecovery,
                defaultValue: d.resumeRecovery,
                min: 1000,
                max: 15000,
                onChanged: (v) => state.config = c.copyWith(resumeRecovery: v),
              ),
              _DurationKnob(
                label: 'speakWatchdog',
                sub: 'Timeout for speaking:start after /human reply. Never-started TTS.',
                value: c.speakWatchdog,
                defaultValue: d.speakWatchdog,
                min: 2000,
                max: 30000,
                onChanged: (v) => state.config = c.copyWith(speakWatchdog: v),
              ),
              _DurationKnob(
                label: 'stuckTalkingCeiling',
                sub: 'Mid-reply frozen-playhead ceiling. speaking:stop frame dropped.',
                value: c.stuckTalkingCeiling,
                defaultValue: d.stuckTalkingCeiling,
                min: 5000,
                max: 30000,
                onChanged: (v) =>
                    state.config = c.copyWith(stuckTalkingCeiling: v),
              ),
              _DurationKnob(
                label: 'greetingInputLock',
                sub: 'Composer disabled at session start while greeting streams.',
                value: c.greetingInputLock,
                defaultValue: d.greetingInputLock,
                min: 0,
                max: 15000,
                onChanged: (v) =>
                    state.config = c.copyWith(greetingInputLock: v),
              ),
              _DurationKnob(
                label: 'connectTimeout',
                sub: 'Max time to wait for initial /connect to complete.',
                value: c.connectTimeout,
                defaultValue: d.connectTimeout,
                min: 2000,
                max: 30000,
                onChanged: (v) => state.config = c.copyWith(connectTimeout: v),
              ),
              _DurationKnob(
                label: 'heldSendTimeout',
                sub: 'How long a queued send is retained after status leaves ready.',
                value: c.heldSendTimeout,
                defaultValue: d.heldSendTimeout,
                min: 1000,
                max: 30000,
                onChanged: (v) => state.config = c.copyWith(heldSendTimeout: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'TIMING — JITTER + CLAMP',
                hint:
                    'MSE playhead clamping + speech-onset preroll + jitter margin. All VPC.',
              ),
              _IntKnob(
                label: 'evictKeepBehindSec',
                sub: 'Bytes retained behind the playhead before MSE eviction.',
                value: c.evictKeepBehindSec,
                defaultValue: d.evictKeepBehindSec,
                min: 1,
                max: 30,
                onChanged: (v) =>
                    state.config = c.copyWith(evictKeepBehindSec: v),
              ),
              _DoubleKnob(
                label: 'clampTriggerLagSec',
                sub: 'Playhead lag from live-edge that arms the clamp.',
                value: c.clampTriggerLagSec,
                defaultValue: d.clampTriggerLagSec,
                min: 0.1,
                max: 5.0,
                step: 0.1,
                onChanged: (v) =>
                    state.config = c.copyWith(clampTriggerLagSec: v),
              ),
              _DoubleKnob(
                label: 'clampTargetBehindSec',
                sub: 'Where the clamp seeks TO (safe behind live-edge).',
                value: c.clampTargetBehindSec,
                defaultValue: d.clampTargetBehindSec,
                min: 0.1,
                max: 5.0,
                step: 0.1,
                onChanged: (v) =>
                    state.config = c.copyWith(clampTargetBehindSec: v),
              ),
              _DoubleKnob(
                label: 'speechOnsetPrerollSec',
                sub: 'Buffer ahead before speak-start to avoid audio underrun.',
                value: c.speechOnsetPrerollSec,
                defaultValue: d.speechOnsetPrerollSec,
                min: 0.0,
                max: 3.0,
                step: 0.05,
                onChanged: (v) =>
                    state.config = c.copyWith(speechOnsetPrerollSec: v),
              ),
              _DoubleKnob(
                label: 'jitterMarginStepSec',
                sub: 'How aggressively the jitter margin grows on stall.',
                value: c.jitterMarginStepSec,
                defaultValue: d.jitterMarginStepSec,
                min: 0.05,
                max: 2.0,
                step: 0.05,
                onChanged: (v) =>
                    state.config = c.copyWith(jitterMarginStepSec: v),
              ),
              _DoubleKnob(
                label: 'jitterMarginMaxSec',
                sub: 'Ceiling for the adaptive jitter margin.',
                value: c.jitterMarginMaxSec,
                defaultValue: d.jitterMarginMaxSec,
                min: 0.5,
                max: 10.0,
                step: 0.1,
                onChanged: (v) =>
                    state.config = c.copyWith(jitterMarginMaxSec: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'RECONNECT',
                hint: 'Backoff ladder for session drops.',
              ),
              _IntKnob(
                label: 'maxReconnectAttempts',
                sub: 'Cap on automatic reconnects before "tap to reconnect" overlay.',
                value: c.maxReconnectAttempts,
                defaultValue: d.maxReconnectAttempts,
                min: 0,
                max: 20,
                onChanged: (v) =>
                    state.config = c.copyWith(maxReconnectAttempts: v),
              ),
              _DurationKnob(
                label: 'reconnectBaseBackoff',
                sub: 'Initial wait before first retry. Doubles each attempt.',
                value: c.reconnectBaseBackoff,
                defaultValue: d.reconnectBaseBackoff,
                min: 100,
                max: 10000,
                onChanged: (v) =>
                    state.config = c.copyWith(reconnectBaseBackoff: v),
              ),
              _DurationKnob(
                label: 'reconnectMaxBackoff',
                sub: 'Ceiling for exponential backoff.',
                value: c.reconnectMaxBackoff,
                defaultValue: d.reconnectMaxBackoff,
                min: 1000,
                max: 60000,
                onChanged: (v) =>
                    state.config = c.copyWith(reconnectMaxBackoff: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'HEARTBEATS + DEBOUNCE',
                hint: 'Liveness pings + stall detection + duplicate-send guard.',
              ),
              _DurationKnob(
                label: 'livenessHeartbeat',
                sub: 'App-side liveness tick.',
                value: c.livenessHeartbeat,
                defaultValue: d.livenessHeartbeat,
                min: 500,
                max: 10000,
                onChanged: (v) =>
                    state.config = c.copyWith(livenessHeartbeat: v),
              ),
              _DurationKnob(
                label: 'idleFreezeHeartbeat',
                sub: 'Idle-video freeze detector interval.',
                value: c.idleFreezeHeartbeat,
                defaultValue: d.idleFreezeHeartbeat,
                min: 500,
                max: 10000,
                onChanged: (v) =>
                    state.config = c.copyWith(idleFreezeHeartbeat: v),
              ),
              _DurationKnob(
                label: 'stallDebounce',
                sub: 'How long a playhead stall persists before firing recovery.',
                value: c.stallDebounce,
                defaultValue: d.stallDebounce,
                min: 500,
                max: 10000,
                onChanged: (v) => state.config = c.copyWith(stallDebounce: v),
              ),
              _DurationKnob(
                label: 'duplicateSendWindow',
                sub: 'Deduplicate identical sends within this window.',
                value: c.duplicateSendWindow,
                defaultValue: d.duplicateSendWindow,
                min: 100,
                max: 10000,
                onChanged: (v) =>
                    state.config = c.copyWith(duplicateSendWindow: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'PROGRESSION + TOAST',
                hint: 'XP/level UI timing + prefetch concurrency.',
              ),
              _IntKnob(
                label: 'chatTimingHistoryMax',
                sub: 'How many chat-timing samples the controller retains.',
                value: c.chatTimingHistoryMax,
                defaultValue: d.chatTimingHistoryMax,
                min: 1,
                max: 100,
                onChanged: (v) =>
                    state.config = c.copyWith(chatTimingHistoryMax: v),
              ),
              _DurationKnob(
                label: 'toastLifetime',
                sub: 'XP toast + status snack visible duration.',
                value: c.toastLifetime,
                defaultValue: d.toastLifetime,
                min: 200,
                max: 8000,
                onChanged: (v) => state.config = c.copyWith(toastLifetime: v),
              ),
              _DurationKnob(
                label: 'pendingLevelUpMaxDelay',
                sub: 'Max time a level-up waits for status → ready to deliver.',
                value: c.pendingLevelUpMaxDelay,
                defaultValue: d.pendingLevelUpMaxDelay,
                min: 1000,
                max: 60000,
                onChanged: (v) =>
                    state.config = c.copyWith(pendingLevelUpMaxDelay: v),
              ),
              _IntKnob(
                label: 'prefetchConcurrency',
                sub: 'Parallel avatar-asset prefetches.',
                value: c.prefetchConcurrency,
                defaultValue: d.prefetchConcurrency,
                min: 1,
                max: 8,
                onChanged: (v) =>
                    state.config = c.copyWith(prefetchConcurrency: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'MIC',
                hint: 'Voice-input capture. Reference: port spec §2.4 / mic.ts.',
              ),
              _DurationKnob(
                label: 'maxRecord',
                sub: 'Hard cap on a single mic capture.',
                value: c.maxRecord,
                defaultValue: d.maxRecord,
                min: 5000,
                max: 300000,
                onChanged: (v) => state.config = c.copyWith(maxRecord: v),
              ),
              _IntKnob(
                label: 'minBlobBytes',
                sub: 'Reject captures smaller than this (probably silent).',
                value: c.minBlobBytes,
                defaultValue: d.minBlobBytes,
                min: 128,
                max: 16384,
                onChanged: (v) => state.config = c.copyWith(minBlobBytes: v),
              ),
              _DurationKnob(
                label: 'transcribeTimeout',
                sub: 'Max time to wait for /stt-api/transcribe response.',
                value: c.transcribeTimeout,
                defaultValue: d.transcribeTimeout,
                min: 2000,
                max: 60000,
                onChanged: (v) =>
                    state.config = c.copyWith(transcribeTimeout: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'BRAIN WARMUP',
                hint: 'Prompt-prefix pre-warm. Reference: port spec §12.2.2.',
              ),
              _DurationKnob(
                label: 'warmupRetry',
                sub: 'Delay between warmup attempts.',
                value: c.warmupRetry,
                defaultValue: d.warmupRetry,
                min: 100,
                max: 10000,
                onChanged: (v) => state.config = c.copyWith(warmupRetry: v),
              ),
              _IntKnob(
                label: 'warmupMaxAttempts',
                sub: 'How many warmup tries before giving up.',
                value: c.warmupMaxAttempts,
                defaultValue: d.warmupMaxAttempts,
                min: 0,
                max: 10,
                onChanged: (v) =>
                    state.config = c.copyWith(warmupMaxAttempts: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'CODEC + RENDER (MOID)',
                hint: 'Mason-Open Inferred Defaults. Editing these is risky.',
              ),
              _ReadOnlyKnob(
                label: 'mseCodec',
                sub: 'MSE codec string. Changing risks browser rejection.',
                value: c.mseCodec,
                defaultValue: d.mseCodec,
              ),
              _ReadOnlyKnob(
                label: 'staticMp4Codec',
                sub: 'Static-MP4 codec string (preview clips, overlays).',
                value: c.staticMp4Codec,
                defaultValue: d.staticMp4Codec,
              ),
              _IntKnob(
                label: 'videoFps',
                sub: 'Nominal video frame rate. Wire is 25fps for penthouse muse.',
                value: c.videoFps,
                defaultValue: d.videoFps,
                min: 15,
                max: 60,
                onChanged: (v) => state.config = c.copyWith(videoFps: v),
              ),
              _IntKnob(
                label: 'voiceRefSampleRateHz',
                sub: 'Reference sample rate for voice files (Qwen3 is 24kHz).',
                value: c.voiceRefSampleRateHz,
                defaultValue: d.voiceRefSampleRateHz,
                min: 8000,
                max: 48000,
                onChanged: (v) =>
                    state.config = c.copyWith(voiceRefSampleRateHz: v),
              ),
              _IntKnob(
                label: 'previewLoopSeconds',
                sub: 'Preview-clip loop length.',
                value: c.previewLoopSeconds,
                defaultValue: d.previewLoopSeconds,
                min: 1,
                max: 30,
                onChanged: (v) =>
                    state.config = c.copyWith(previewLoopSeconds: v),
              ),
              _IntKnob(
                label: 'previewFps',
                sub: 'Preview-clip fps.',
                value: c.previewFps,
                defaultValue: d.previewFps,
                min: 6,
                max: 30,
                onChanged: (v) => state.config = c.copyWith(previewFps: v),
              ),
              _BoolKnob(
                label: 'idlesAreMuted',
                sub: 'Muted-autoplay for idle videos. Required for browser autoplay.',
                value: c.idlesAreMuted,
                defaultValue: d.idlesAreMuted,
                onChanged: (v) => state.config = c.copyWith(idlesAreMuted: v),
              ),

              // ═══════════════════════════════════════════════
              const Divider(),
              const LabSectionHeader(
                label: 'UX PARITY — PHASE 3',
                hint:
                    'Penthouse-port flags added 2026-08. Consumer widgets '
                    'gate animations on respectReducedMotion; the silence '
                    'filler flag is exposed today, wire integration follows.',
              ),
              _BoolKnob(
                label: 'respectReducedMotion',
                sub:
                    'Honor OS reduced-motion (MediaQuery.disableAnimations) '
                    'by zeroing crossfades + skipping transition films.',
                value: c.respectReducedMotion,
                defaultValue: d.respectReducedMotion,
                onChanged: (v) =>
                    state.config = c.copyWith(respectReducedMotion: v),
              ),
              _BoolKnob(
                label: 'silenceFillerEnabled',
                sub:
                    'Insert silence filler between reply audio chunks '
                    '(smooths server-side inter-chunk gaps). Wire hook TBD.',
                value: c.silenceFillerEnabled,
                defaultValue: d.silenceFillerEnabled,
                onChanged: (v) =>
                    state.config = c.copyWith(silenceFillerEnabled: v),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      );
}

// ---- copyWith extension on PlayerConfig -----------------------------------

extension PlayerConfigCopyWith on PlayerConfig {
  PlayerConfig copyWith({
    Duration? minConnectLifetime,
    Duration? wsSilence,
    Duration? resumeRecovery,
    Duration? speakWatchdog,
    Duration? stuckTalkingCeiling,
    Duration? greetingInputLock,
    Duration? connectTimeout,
    Duration? heldSendTimeout,
    int? evictKeepBehindSec,
    double? clampTriggerLagSec,
    double? clampTargetBehindSec,
    double? speechOnsetPrerollSec,
    double? jitterMarginStepSec,
    double? jitterMarginMaxSec,
    Duration? duplicateSendWindow,
    int? maxReconnectAttempts,
    Duration? reconnectBaseBackoff,
    Duration? reconnectMaxBackoff,
    int? chatTimingHistoryMax,
    Duration? toastLifetime,
    Duration? pendingLevelUpMaxDelay,
    int? prefetchConcurrency,
    Duration? livenessHeartbeat,
    Duration? idleFreezeHeartbeat,
    Duration? stallDebounce,
    Duration? maxRecord,
    int? minBlobBytes,
    Duration? transcribeTimeout,
    Duration? warmupRetry,
    int? warmupMaxAttempts,
    String? mseCodec,
    String? staticMp4Codec,
    int? videoFps,
    int? voiceRefSampleRateHz,
    int? previewLoopSeconds,
    int? previewFps,
    bool? idlesAreMuted,
    bool? respectReducedMotion,
    bool? silenceFillerEnabled,
  }) =>
      PlayerConfig(
        minConnectLifetime: minConnectLifetime ?? this.minConnectLifetime,
        wsSilence: wsSilence ?? this.wsSilence,
        resumeRecovery: resumeRecovery ?? this.resumeRecovery,
        speakWatchdog: speakWatchdog ?? this.speakWatchdog,
        stuckTalkingCeiling: stuckTalkingCeiling ?? this.stuckTalkingCeiling,
        greetingInputLock: greetingInputLock ?? this.greetingInputLock,
        connectTimeout: connectTimeout ?? this.connectTimeout,
        heldSendTimeout: heldSendTimeout ?? this.heldSendTimeout,
        evictKeepBehindSec: evictKeepBehindSec ?? this.evictKeepBehindSec,
        clampTriggerLagSec: clampTriggerLagSec ?? this.clampTriggerLagSec,
        clampTargetBehindSec:
            clampTargetBehindSec ?? this.clampTargetBehindSec,
        speechOnsetPrerollSec:
            speechOnsetPrerollSec ?? this.speechOnsetPrerollSec,
        jitterMarginStepSec: jitterMarginStepSec ?? this.jitterMarginStepSec,
        jitterMarginMaxSec: jitterMarginMaxSec ?? this.jitterMarginMaxSec,
        duplicateSendWindow: duplicateSendWindow ?? this.duplicateSendWindow,
        maxReconnectAttempts:
            maxReconnectAttempts ?? this.maxReconnectAttempts,
        reconnectBaseBackoff:
            reconnectBaseBackoff ?? this.reconnectBaseBackoff,
        reconnectMaxBackoff: reconnectMaxBackoff ?? this.reconnectMaxBackoff,
        chatTimingHistoryMax:
            chatTimingHistoryMax ?? this.chatTimingHistoryMax,
        toastLifetime: toastLifetime ?? this.toastLifetime,
        pendingLevelUpMaxDelay:
            pendingLevelUpMaxDelay ?? this.pendingLevelUpMaxDelay,
        prefetchConcurrency: prefetchConcurrency ?? this.prefetchConcurrency,
        livenessHeartbeat: livenessHeartbeat ?? this.livenessHeartbeat,
        idleFreezeHeartbeat: idleFreezeHeartbeat ?? this.idleFreezeHeartbeat,
        stallDebounce: stallDebounce ?? this.stallDebounce,
        maxRecord: maxRecord ?? this.maxRecord,
        minBlobBytes: minBlobBytes ?? this.minBlobBytes,
        transcribeTimeout: transcribeTimeout ?? this.transcribeTimeout,
        warmupRetry: warmupRetry ?? this.warmupRetry,
        warmupMaxAttempts: warmupMaxAttempts ?? this.warmupMaxAttempts,
        mseCodec: mseCodec ?? this.mseCodec,
        staticMp4Codec: staticMp4Codec ?? this.staticMp4Codec,
        videoFps: videoFps ?? this.videoFps,
        voiceRefSampleRateHz:
            voiceRefSampleRateHz ?? this.voiceRefSampleRateHz,
        previewLoopSeconds: previewLoopSeconds ?? this.previewLoopSeconds,
        previewFps: previewFps ?? this.previewFps,
        idlesAreMuted: idlesAreMuted ?? this.idlesAreMuted,
        respectReducedMotion:
            respectReducedMotion ?? this.respectReducedMotion,
        silenceFillerEnabled:
            silenceFillerEnabled ?? this.silenceFillerEnabled,
      );
}

bool _configEquals(PlayerConfig a, PlayerConfig b) =>
    a.minConnectLifetime == b.minConnectLifetime &&
    a.wsSilence == b.wsSilence &&
    a.resumeRecovery == b.resumeRecovery &&
    a.speakWatchdog == b.speakWatchdog &&
    a.stuckTalkingCeiling == b.stuckTalkingCeiling &&
    a.greetingInputLock == b.greetingInputLock &&
    a.connectTimeout == b.connectTimeout &&
    a.heldSendTimeout == b.heldSendTimeout &&
    a.evictKeepBehindSec == b.evictKeepBehindSec &&
    a.clampTriggerLagSec == b.clampTriggerLagSec &&
    a.clampTargetBehindSec == b.clampTargetBehindSec &&
    a.speechOnsetPrerollSec == b.speechOnsetPrerollSec &&
    a.jitterMarginStepSec == b.jitterMarginStepSec &&
    a.jitterMarginMaxSec == b.jitterMarginMaxSec &&
    a.duplicateSendWindow == b.duplicateSendWindow &&
    a.maxReconnectAttempts == b.maxReconnectAttempts &&
    a.reconnectBaseBackoff == b.reconnectBaseBackoff &&
    a.reconnectMaxBackoff == b.reconnectMaxBackoff &&
    a.chatTimingHistoryMax == b.chatTimingHistoryMax &&
    a.toastLifetime == b.toastLifetime &&
    a.pendingLevelUpMaxDelay == b.pendingLevelUpMaxDelay &&
    a.prefetchConcurrency == b.prefetchConcurrency &&
    a.livenessHeartbeat == b.livenessHeartbeat &&
    a.idleFreezeHeartbeat == b.idleFreezeHeartbeat &&
    a.stallDebounce == b.stallDebounce &&
    a.maxRecord == b.maxRecord &&
    a.minBlobBytes == b.minBlobBytes &&
    a.transcribeTimeout == b.transcribeTimeout &&
    a.warmupRetry == b.warmupRetry &&
    a.warmupMaxAttempts == b.warmupMaxAttempts &&
    a.mseCodec == b.mseCodec &&
    a.staticMp4Codec == b.staticMp4Codec &&
    a.videoFps == b.videoFps &&
    a.voiceRefSampleRateHz == b.voiceRefSampleRateHz &&
    a.previewLoopSeconds == b.previewLoopSeconds &&
    a.previewFps == b.previewFps &&
    a.idlesAreMuted == b.idlesAreMuted &&
    a.respectReducedMotion == b.respectReducedMotion &&
    a.silenceFillerEnabled == b.silenceFillerEnabled;

// ---- Reusable knob widgets -------------------------------------------------

/// Shared row scaffolding: label + sub + (overridden badge) + trailing control.
class _KnobRow extends StatelessWidget {
  final String label;
  final String sub;
  final bool overridden;
  final Widget trailing;
  const _KnobRow({
    required this.label,
    required this.sub,
    required this.overridden,
    required this.trailing,
  });
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: overridden ? LabColors.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: LabColors.text,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
              if (overridden)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: LabColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text('OVERRIDE',
                      style: TextStyle(
                          color: LabColors.accentOn,
                          fontSize: 8,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w800)),
                ),
            ]),
            const SizedBox(height: 2),
            Text(sub,
                style: const TextStyle(
                    color: LabColors.textDim,
                    fontSize: 11,
                    height: 1.3)),
            const SizedBox(height: 6),
            trailing,
          ],
        ),
      );
}

class _DurationKnob extends StatelessWidget {
  final String label;
  final String sub;
  final Duration value;
  final Duration defaultValue;
  final int min;
  final int max;
  final ValueChanged<Duration> onChanged;
  const _DurationKnob({
    required this.label,
    required this.sub,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => _KnobRow(
        label: label,
        sub: sub,
        overridden: value != defaultValue,
        trailing: Row(children: [
          SizedBox(
            width: 60,
            child: Text(
              '${value.inMilliseconds}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const Text(' ms',
              style: TextStyle(color: LabColors.textDim, fontSize: 11)),
          Expanded(
            child: Slider(
              value: value.inMilliseconds
                  .clamp(min, max)
                  .toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: 40,
              onChanged: (v) => onChanged(Duration(milliseconds: v.round())),
            ),
          ),
          Text('def ${defaultValue.inMilliseconds}',
              style: const TextStyle(
                  color: LabColors.textMuted, fontSize: 10)),
        ]),
      );
}

class _IntKnob extends StatelessWidget {
  final String label;
  final String sub;
  final int value;
  final int defaultValue;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  const _IntKnob({
    required this.label,
    required this.sub,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => _KnobRow(
        label: label,
        sub: sub,
        overridden: value != defaultValue,
        trailing: Row(children: [
          SizedBox(
            width: 60,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: (max - min).clamp(1, 100),
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
          Text('def $defaultValue',
              style: const TextStyle(
                  color: LabColors.textMuted, fontSize: 10)),
        ]),
      );
}

class _DoubleKnob extends StatelessWidget {
  final String label;
  final String sub;
  final double value;
  final double defaultValue;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  const _DoubleKnob({
    required this.label,
    required this.sub,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => _KnobRow(
        label: label,
        sub: sub,
        overridden: value != defaultValue,
        trailing: Row(children: [
          SizedBox(
            width: 60,
            child: Text(
              value.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) / step).round().clamp(1, 200),
              onChanged: onChanged,
            ),
          ),
          Text('def ${defaultValue.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: LabColors.textMuted, fontSize: 10)),
        ]),
      );
}

class _BoolKnob extends StatelessWidget {
  final String label;
  final String sub;
  final bool value;
  final bool defaultValue;
  final ValueChanged<bool> onChanged;
  const _BoolKnob({
    required this.label,
    required this.sub,
    required this.value,
    required this.defaultValue,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => _KnobRow(
        label: label,
        sub: sub,
        overridden: value != defaultValue,
        trailing: Row(children: [
          Switch(value: value, onChanged: onChanged),
          const SizedBox(width: 8),
          Text('default $defaultValue',
              style: const TextStyle(
                  color: LabColors.textMuted, fontSize: 10)),
        ]),
      );
}

class _ReadOnlyKnob extends StatelessWidget {
  final String label;
  final String sub;
  final String value;
  final String defaultValue;
  const _ReadOnlyKnob({
    required this.label,
    required this.sub,
    required this.value,
    required this.defaultValue,
  });
  @override
  Widget build(BuildContext context) => _KnobRow(
        label: label,
        sub: sub,
        overridden: value != defaultValue,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: LabColors.chrome,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: LabColors.border),
          ),
          child: Text(value,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 11)),
        ),
      );
}
