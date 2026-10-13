/// Configuration surface for [TwaiAvatarPlayerController].
///
/// **Two kinds of knobs live here:**
///
/// 1. **Timing constants** — the magic numbers from months of production
///    iteration. All values sourced from the port spec
///    (`docs/port_spec_avatar_player.md` §3) with file:line citations
///    against the reference implementation. **These are load-bearing:**
///    every one exists because a specific bug motivated it. Change with
///    the same care you'd change a load-bearing wall — usually you don't.
///
/// 2. **Inferred defaults for Mason-open items** — values we're confident
///    enough in to ship as defaults, but that Mason is expected to
///    confirm / refine as the API contract lands. Held as `final` fields
///    on the config object so a customer app (or a future SDK version)
///    can override without touching controller code.
///
/// Both kinds are exposed on a single [PlayerConfig] value type so
/// callers pass one object into the controller instead of ~30 named
/// params.
///
/// **Every field carries a comment noting whether it's a "verified
/// production constant" (VPC) or a "Mason-open inferred default" (MOID).**
/// Do not upgrade a MOID to a VPC without a source-of-truth confirmation.
library;

/// One-stop config for [TwaiAvatarPlayerController]. Sensible defaults;
/// override any field per app.
class PlayerConfig {
  const PlayerConfig({
    // — Verified production constants (VPC) — see port spec §3.
    this.minConnectLifetime = const Duration(milliseconds: 4000),
    this.wsSilence = const Duration(milliseconds: 3000),
    this.resumeRecovery = const Duration(milliseconds: 5000),
    this.speakWatchdog = const Duration(milliseconds: 12000),
    this.stuckTalkingCeiling = const Duration(milliseconds: 15000),
    this.greetingInputLock = const Duration(milliseconds: 5000),
    this.connectTimeout = const Duration(milliseconds: 15000),
    this.heldSendTimeout = const Duration(milliseconds: 8000),
    this.evictKeepBehindSec = 5,
    this.clampTriggerLagSec = 1.2,
    this.clampTargetBehindSec = 0.6,
    this.speechOnsetPrerollSec = 0.45,
    this.jitterMarginStepSec = 0.3,
    this.jitterMarginMaxSec = 1.5,
    this.duplicateSendWindow = const Duration(milliseconds: 3000),
    this.maxReconnectAttempts = 5,
    this.reconnectBaseBackoff = const Duration(milliseconds: 1000),
    this.reconnectMaxBackoff = const Duration(milliseconds: 16000),
    this.chatTimingHistoryMax = 20,
    this.toastLifetime = const Duration(milliseconds: 1600),
    this.pendingLevelUpMaxDelay = const Duration(milliseconds: 20000),
    this.prefetchConcurrency = 2,
    this.livenessHeartbeat = const Duration(milliseconds: 2000),
    this.idleFreezeHeartbeat = const Duration(milliseconds: 1000),
    this.stallDebounce = const Duration(milliseconds: 2000),
    // — Mic — see port spec §2.4 / mic.ts.
    this.maxRecord = const Duration(milliseconds: 60000),
    this.minBlobBytes = 1024,
    this.transcribeTimeout = const Duration(milliseconds: 20000),
    // — Brain prompt-prefix pre-warm — see port spec §12.2.2.
    this.warmupRetry = const Duration(milliseconds: 1500),
    this.warmupMaxAttempts = 3,
    // — Mason-open inferred defaults (MOID) — see docs/avatar_input_spec.md §8.
    this.mseCodec = 'video/mp4; codecs="avc1.42C01F, mp4a.40.2"',
    this.staticMp4Codec = 'video/mp4; codecs="avc1.42C01F, mp4a.40.2"',
    this.videoFps = 25,
    this.voiceRefSampleRateHz = 24000,
    this.previewLoopSeconds = 3,
    this.previewFps = 12,
    this.idlesAreMuted = true,
    // — UX parity (Penthouse port, Phase 3) — see plan doc §Phase B.
    this.respectReducedMotion = false,
    this.silenceFillerEnabled = true,
  });

  // ──────────────────────────────────────────────────────────────────
  // VERIFIED PRODUCTION CONSTANTS (VPC)
  // ──────────────────────────────────────────────────────────────────

  /// Min socket age before treating a close as a flap vs. a transient
  /// mobile glitch. If the socket dies faster than this after the first
  /// `playing` event, we treat it as a mobile glitch and use exponential
  /// backoff. VPC (controller.ts:681).
  final Duration minConnectLifetime;

  /// Max gap between WS frames before the socket is declared dead. The
  /// worker streams idle fragments every ~tens of ms; a silence over
  /// this threshold means a zombie socket (iOS `readyState` lies).
  /// VPC (controller.ts:705).
  final Duration wsSilence;

  /// Watchdog for the `ManagedMediaSource` wedge on iOS gestureless
  /// connect. If the session hasn't reached `playing` in this window,
  /// show a "tap to resume" overlay. VPC (controller.ts:720).
  final Duration resumeRecovery;

  /// Timeout for `{speaking:start}` event after `POST /human` reply.
  /// Backstop for stuck TTS/render pipeline; exceeded → force
  /// reconnect. VPC (controller.ts:777).
  final Duration speakWatchdog;

  /// Mid-reply "stuck talking" ceiling. Complements [speakWatchdog]:
  /// where speakWatchdog fires when speaking never STARTED,
  /// stuckTalkingCeiling fires when speaking started but never
  /// STOPPED (e.g. `speaking:stop` frame dropped mid-flight, worker
  /// crashed after opening the reply). Gated on liveness — the timer
  /// resets whenever the playhead advances or new speaking frames
  /// arrive, so it can only fire on TRUE stuck-state (playhead
  /// frozen + no new frames). When it fires, the controller emits
  /// `status.ready` to unfreeze the idle↔speaking crossfade so the
  /// avatar returns to idle rather than looking stuck mid-reply.
  ///
  /// Modeled after 2wai-edu's Watchdog B ceiling (useMseAvatarPlayer.ts:332-340).
  /// 15s is edu's default; conservative enough that Krystal answers
  /// of 15+ seconds don't hit it in practice (liveness keeps
  /// resetting it during actual speech).
  final Duration stuckTalkingCeiling;

  /// Input disabled duration after the runtime greeting renders — ~covers
  /// the spoken opening line playback. VPC (controller.ts:950).
  final Duration greetingInputLock;

  /// Timeout for the `sourceopen` + WS-open race on initial connect.
  /// Falls back to WebRTC if MSE handshake hangs on iOS. VPC
  /// (controller.ts:2303).
  final Duration connectTimeout;

  /// Max wait for pending `/seen` before releasing a held message.
  /// Safety timeout; if `/seen` wedges, don't block chat indefinitely.
  /// VPC (controller.ts:1023).
  final Duration heldSendTimeout;

  /// SourceBuffer retention window behind playhead (seconds). Drop
  /// older frames to prevent OOM stutter after 3+ min sessions.
  /// VPC (controller.ts:2423).
  final int evictKeepBehindSec;

  /// Live-edge clamp threshold (seconds lag). Seek playhead forward
  /// when >this behind the live edge (+ adaptive margin per stall).
  /// VPC (controller.ts:2511).
  final double clampTriggerLagSec;

  /// Landing point for live-edge clamp (seconds behind live). Snappy
  /// responsiveness without landing right on the edge. VPC
  /// (controller.ts:2512).
  final double clampTargetBehindSec;

  /// Buffer before pending speech-start PTS (seconds). Don't clamp
  /// past this; ensures reply onset isn't mid-seek. VPC
  /// (controller.ts:2513).
  final double speechOnsetPrerollSec;

  /// Per-stall jitter margin increment (seconds). Each mid-speech
  /// `waiting` event widens margin by this. VPC (controller.ts:2514).
  final double jitterMarginStepSec;

  /// Max jitter margin (seconds). Cap for jittery connections; margin
  /// resets per connect. VPC (controller.ts:2515).
  final double jitterMarginMaxSec;

  /// Debounce window for identical rapid sends. Drop sends if the last
  /// send is identical and within this window. VPC (controller.ts:3697).
  final Duration duplicateSendWindow;

  /// Max automatic reconnect attempts before showing the "tap to
  /// reconnect" gesture overlay. VPC (controller.ts:993).
  final int maxReconnectAttempts;

  /// Base delay for reconnect exponential backoff. Attempt N delay =
  /// `min(reconnectBaseBackoff * 2^(N-1), reconnectMaxBackoff)`.
  /// VPC (controller.ts:3039-3070) — 1s.
  final Duration reconnectBaseBackoff;

  /// Cap for reconnect exponential backoff. VPC — 16s.
  final Duration reconnectMaxBackoff;

  /// Chat round-trip timing buffer size (sliding window). Exposed via
  /// diagnostic hook. VPC (controller.ts:821).
  final int chatTimingHistoryMax;

  /// XP toast float-up animation duration. VPC (controller.ts:4465).
  final Duration toastLifetime;

  /// Max defer time for level-up modal (stashed while speaking).
  /// Don't queue modals longer than this; drop if speaker goes silent
  /// and re-engages without modal firing. VPC (controller.ts:4851).
  final Duration pendingLevelUpMaxDelay;

  /// Max parallel background media prefetch requests. VPC
  /// (controller.ts:1073).
  final int prefetchConcurrency;

  /// Liveness heartbeat tick. Reads `lastWsMessageTs` to detect zombie
  /// sockets (see [wsSilence]). VPC (implicit in the 2s liveness tick
  /// referenced through controller.ts §12.1.2).
  final Duration livenessHeartbeat;

  /// Idle-freeze self-heal heartbeat. On mobile, checks whether the
  /// idle `<video>` currentTime is advancing; if not, prods the
  /// decoder. VPC (controller.ts:2573-2598).
  final Duration idleFreezeHeartbeat;

  /// Debounce for stall events on jitter margin bumps. Don't react to
  /// every `waiting` event; batch them. VPC (controller.ts:2608).
  final Duration stallDebounce;

  // Mic

  /// Max mic recording duration. Hard upper bound; VAD may never fire.
  /// VPC (mic.ts:34).
  final Duration maxRecord;

  /// Min audio blob size for transcribe POST. Drop accidental quick
  /// taps; STT services also reject very short audio. VPC (mic.ts:38).
  final int minBlobBytes;

  /// Timeout for `POST /stt-api/transcribe`. Covers STT replica
  /// cold-start (~10s) + Whisper (~1-2s) + headroom. VPC (mic.ts:43).
  final Duration transcribeTimeout;

  // Warmup

  /// Interval between speaker prefetch warmup retries. VPC
  /// (controller.ts:4061).
  final Duration warmupRetry;

  /// Max speaker prefetch warmup attempts. VPC (controller.ts:4060).
  final int warmupMaxAttempts;

  // ──────────────────────────────────────────────────────────────────
  // MASON-OPEN INFERRED DEFAULTS (MOID)
  // ──────────────────────────────────────────────────────────────────

  /// MIME + codec string for the live MSE stream. Verified against the
  /// worker's init segment bytes 2026-05-10 (`avc1.42C01F` = H.264
  /// Constrained Baseline 3.1; `mp4a.40.2` = AAC-LC). Do NOT change
  /// this for the live stream (see port spec §5.4).
  ///
  /// It's a MOID rather than a VPC only because the boundary between
  /// "SDK config" and "immutable protocol constant" is fuzzy — this
  /// technically COULD move if Mason changes the worker encoder, but
  /// realistically it won't.
  final String mseCodec;

  /// MIME + codec string for the static idle / emote / frame /
  /// transition MP4s served off the CDN. **MOID** (avatar_input_spec §8
  /// Q1). Inferred to match the live stream codec; Mason to confirm
  /// whether the bake pipeline actually produces the same profile or
  /// something higher (High 4.0, etc.).
  final String staticMp4Codec;

  /// Video frame rate for all avatar assets (idle, talk source, emote,
  /// frame, transition). VPC — MuseTalk + Wav2Lip both process at 25
  /// fps (see `wav2lipreal.py:73`, `PIPELINE_SPEC_V1.3.md:258`).
  final int videoFps;

  /// Sample rate (Hz) for voice reference clips uploaded to Qwen3's
  /// ref_audio store. **MOID** (avatar_input_spec §8 Q2). Inferred
  /// from Qwen3 defaults; Mason to confirm.
  final int voiceRefSampleRateHz;

  /// Duration of the animated WebP outfit-preview loop. MOID; from
  /// [avatars.ts:38-44](../../../../clg_penthouse_pets/frontend/src/lean/avatars.ts).
  final int previewLoopSeconds;

  /// Frame rate for the animated WebP outfit preview. MOID; from
  /// same source as [previewLoopSeconds].
  final int previewFps;

  /// Whether idle clips are muted at playback. Player mutes idles
  /// today; **MOID** (avatar_input_spec §8 Q6) — Mason to confirm
  /// whether idles could carry ambient audio in the future.
  final bool idlesAreMuted;

  // ──────────────────────────────────────────────────────────────────
  // UX PARITY — PHASE 3 (Penthouse port)
  // ──────────────────────────────────────────────────────────────────

  /// When true, the SDK honors the OS-level reduced-motion preference
  /// (`MediaQuery.disableAnimations`) by zeroing crossfade durations
  /// and skipping scene transition films. Default false so behavior
  /// doesn't change silently for existing consumers.
  ///
  /// Consumer widgets that render animations should gate them on:
  /// ```dart
  /// final reduce = config.respectReducedMotion &&
  ///     MediaQuery.of(context).disableAnimations;
  /// ```
  final bool respectReducedMotion;

  /// When true, the SDK inserts a subtle silence-filler between reply
  /// audio chunks to smooth over server-side inter-chunk gaps. Default
  /// true — flag-gated per the 2026-08-08 wiki A/B ("recall silence-
  /// filler fallback, verdict keep"). Consumer apps that want the raw
  /// gap-through behavior (Penthouse pre-2026-08) set false.
  ///
  /// **Wire integration TBD.** Field is exposed today so consumers can
  /// set it; the SDK's audio-pipeline hook that consumes it lands in a
  /// follow-up.
  final bool silenceFillerEnabled;

  // ──────────────────────────────────────────────────────────────────

  /// Compute the reconnect backoff delay for a given attempt number.
  /// Attempt 1 = base, doubling each attempt, capped at [reconnectMaxBackoff].
  ///
  /// | attempt | delay |
  /// | ------- | ----- |
  /// | 1       | 1s    |
  /// | 2       | 2s    |
  /// | 3       | 4s    |
  /// | 4       | 8s    |
  /// | 5       | 16s   |
  Duration backoffForAttempt(int attempt) {
    if (attempt < 1) return Duration.zero;
    final base = reconnectBaseBackoff.inMilliseconds;
    final scaled = base * (1 << (attempt - 1));
    final capped = scaled > reconnectMaxBackoff.inMilliseconds
        ? reconnectMaxBackoff.inMilliseconds
        : scaled;
    return Duration(milliseconds: capped);
  }
}
