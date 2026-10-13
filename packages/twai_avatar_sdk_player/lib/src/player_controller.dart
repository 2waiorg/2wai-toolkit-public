import 'dart:async';
import 'dart:typed_data';

import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

import 'overlay.dart';
import 'player_config.dart';
import 'player_state.dart';
import 'progression.dart';

/// **The 2wai Avatar Player controller.**
///
/// Bit-for-bit port target of the production reference controller at
/// `c:\Dev\clg_penthouse_pets\frontend\src\lean\controller.ts`. See
/// `docs/port_spec_avatar_player.md` for the load-bearing spec this
/// class is porting, and `docs/prd_2026_07_18.md` §5 for the strategic
/// framing.
///
/// **This is the imperative composition root of the SDK player.** It
/// owns:
///
/// - a rotating [ChatSession] (concrete = [MseStreamChatSession]) for
///   transport — built via [sessionFactory] on every connect / reconnect
/// - the connection state machine, reconnect discipline, watchdogs
/// - the message-flow discipline (held-send, greeting lock, speak
///   watchdog, duplicate debounce)
/// - the streaming discipline (jitter margin, live-edge clamp, buffer
///   eviction — enforced through a video sink attached externally)
///
/// # Session lifecycle model
///
/// The controller **rotates sessions**: each connect attempt builds a
/// fresh [ChatSession] via [sessionFactory], because
/// [ChatSession.connect] throws on second call. The controller pipes
/// the rotating session's streams ([videoBytes], [speakingEvents],
/// [replyText]) into its own broadcast streams so consumer
/// subscriptions survive reconnects without rewiring.
///
/// # Port status (2026-07-19)
///
/// - [x] Package structure + config surface + state enum
/// - [x] `connectAttemptId` + `stale()` guard
/// - [x] Public API shape (connect, send, dispose, status, streams)
/// - [x] Single-flight `_ensureConnected` funnel
/// - [x] Exponential backoff scheduler + max-attempts exhaustion
/// - [x] Session rotation + stable broadcast streams for consumers
/// - [x] Clean teardown discipline (stale guards + resource release)
/// - [x] `ready` fires on first-frame arrival (not handshake success)
/// - [x] Liveness heartbeat + zombie-WS detection (iOS)
/// - [x] Speak watchdog + `awaitingSpeakingForChat` flag (§12.1.6)
/// - [x] Resume-recovery watchdog (iOS MMS wedge)
/// - [x] Held-send + duplicate-send debounce (§12.1.8, §3)
/// - [x] PTS-gated speaking events (§5.1) — via [updatePlaybackTime]
/// - [x] Greeting flow + `/seen` gate (§2.7, §12.2.3, §12.4.3)
/// - [x] Live-edge clamp + adaptive jitter margin (§5.1, §12.1.3, §12.1.5)
/// - [x] Mood forwarding + sticky [currentMood] (§4.11, §11)
/// - [x] Avatar-switch primitive [changeAvatar] (controller-side of
///       outfit switching §2.5 — transition overlay/idle-swap
///       remain sink/app concerns)
/// - [x] Overlay orchestration [playOverlay] + [overlayEvents] +
///       [isOverlayPlaying] / [notifyOverlayEnded] (§2.6, §7).
///       App renders the overlay video; controller emits events +
///       tracks the flag.
/// - [x] XP + level-up event dispatch [awardXp] / [notifyLevelUp]
///       with deferred-while-speaking discipline (§11).
/// - [ ] Outfit switch + transition overlay
/// - [ ] Emote / frame / transition playback
/// - [ ] Mood icon
/// - [ ] Level-up modal / XP toasts
class TwaiAvatarPlayerController {
  TwaiAvatarPlayerController({
    required this.sessionFactory,
    PlayerConfig? config,
  }) : config = config ?? const PlayerConfig();

  /// Factory the controller calls to build a fresh [ChatSession] on
  /// every connect + reconnect. Typically `() =>
  /// twai.mseStreamSession(pathPrefix: '/ext-api-muse')`.
  ///
  /// **Called on the initial `connect()` and on every reconnect.**
  /// Called synchronously from the reconnect scheduler — must be
  /// side-effect-light (no I/O). Must produce a fresh, un-connected
  /// session; the controller calls [ChatSession.connect] itself.
  final ChatSession Function() sessionFactory;

  /// Timing constants + inferred defaults. Sensible defaults; override
  /// on construction if needed.
  final PlayerConfig config;

  // ══════════════════════════════════════════════════════════════════
  // Public status surface
  // ══════════════════════════════════════════════════════════════════

  final StreamController<PlayerStatusEvent> _status =
      StreamController<PlayerStatusEvent>.broadcast();

  /// Live status snapshots. Every state transition emits one event.
  Stream<PlayerStatusEvent> get status => _status.stream;

  /// The controller's current status.
  PlayerStatus get currentStatus => _currentStatus;
  PlayerStatus _currentStatus = PlayerStatus.connecting;

  /// `true` after auto-recovery has been exhausted — no more retries
  /// are scheduled and the app is expected to show a "tap to
  /// reconnect" gesture overlay wired to [manualReconnect]. Clears
  /// when a subsequent connect (auto or manual) reaches
  /// [PlayerStatus.ready]. Port spec §2.3.
  bool get hasExhaustedAutoRecovery => _exhausted;
  bool _exhausted = false;

  /// `true` while a greeting is playing — user input is being held.
  /// The app typically renders the composer as disabled while this is
  /// true. Set by [beginGreeting]; auto-clears after
  /// [PlayerConfig.greetingInputLock] (or the override passed to
  /// [beginGreeting]). Port spec §2.7.
  bool get greetingLockActive => _greetingLockActive;

  /// Current per-session jitter margin (seconds). Starts at `0` on
  /// every fresh session; bumps by [PlayerConfig.jitterMarginStepSec]
  /// on each mid-speech stall reported via [notifyStall], capped at
  /// [PlayerConfig.jitterMarginMaxSec]. Widens the live-edge clamp
  /// target so jittery connections trade snappy latency for smooth
  /// playback. Port spec §12.1.3.
  ///
  /// Read this from the video sink when computing the seek target
  /// via [computeClampTargetSec].
  double get jitterMarginSec => _jitterMarginSec;

  final Completer<PlayerEndReason> _done = Completer<PlayerEndReason>();

  /// Resolves when the controller's session lifecycle terminally ends
  /// (dispose, permanent failure, or auto-recovery exhausted).
  /// Auto-reconnect episodes do NOT resolve this future.
  Future<PlayerEndReason> get done => _done.future;

  /// The current reconnect attempt number. `0` on initial connect and
  /// after any successful `ready` transition. `1..maxReconnectAttempts`
  /// during backoff-retry episodes.
  int get reconnectAttempt => _reconnectAttempts;

  // ══════════════════════════════════════════════════════════════════
  // Streaming — owned broadcast streams that survive session rotation
  // ══════════════════════════════════════════════════════════════════

  final StreamController<Uint8List> _videoBytes =
      StreamController<Uint8List>.broadcast();
  final StreamController<SpeakingEvent> _speakingEvents =
      StreamController<SpeakingEvent>.broadcast();
  // Forwarded from the current session's speakBoundaries. See
  // [speakBoundaries] getter for the full contract.
  final StreamController<void> _speakBoundaries =
      StreamController<void>.broadcast();
  final StreamController<String> _replyText =
      StreamController<String>.broadcast();
  final StreamController<MoodEvent> _moodEvents =
      StreamController<MoodEvent>.broadcast();
  final StreamController<XpEvent> _xpEvents =
      StreamController<XpEvent>.broadcast();
  final StreamController<LevelUpEvent> _levelUpEvents =
      StreamController<LevelUpEvent>.broadcast();
  final StreamController<OverlayEvent> _overlayEvents =
      StreamController<OverlayEvent>.broadcast();

  /// Progression events queued while the avatar is speaking. Drained
  /// on the next [PlayerStatus.ready] transition, filtered against
  /// [PlayerConfig.pendingLevelUpMaxDelay] (stale events dropped).
  /// Port spec §11.
  final List<XpEvent> _pendingXp = [];
  final List<LevelUpEvent> _pendingLevelUp = [];

  /// Raw video bytes from the current session, forwarded through a
  /// broadcast stream that survives reconnects. Consumers pipe this
  /// into their sink and stay subscribed across reconnects.
  Stream<Uint8List> get videoBytes => _videoBytes.stream;

  /// The fMP4 init segment (ftyp+moov, ~600 bytes) as delivered by
  /// muse as the FIRST binary WS frame per session. Retained here so
  /// LATE sink subscribers can prepend it before their SourceBuffer
  /// starts appending mid-stream `moof`/`mdat` fragments — without
  /// this the demuxer fails with `CHUNK_DEMUXER_ERROR_APPEND_FAILED /
  /// RunSegmentParserLoop: stream parsing failed`.
  ///
  /// Cleared on session teardown / rotation so a reconnect's fresh
  /// init segment replaces the old one.
  ///
  /// This is the fix for the multi-`TwaiPlayer` bug (2026-07-24):
  /// apps with multiple TwaiPlayer widgets in the tree (e.g. layout
  /// swap between portrait and landscape) create multiple
  /// WebMseStreamSinks. The first sink alive at WS-connect time gets
  /// the init segment; every sink created afterward misses it and
  /// its `<video>` never advances past `readyState=0`.
  Uint8List? get cachedInitSegment => _cachedInitSegment;
  Uint8List? _cachedInitSegment;

  /// Speaking-state transitions from the current session. Port work
  /// will add PTS gating so events don't fire until playback time
  /// passes the PTS (see port spec §5.1).
  Stream<SpeakingEvent> get speakingEvents => _speakingEvents.stream;

  /// Forwarded from the current session's `speakBoundaries` — fires
  /// after each SDK-driven `/speak` REST completes. Empty for Adapter 1
  /// / Adapter 2 (server-side or per-turn brains). Used by native
  /// accumulate-then-play sinks to short-circuit their post-`stop`
  /// tail-window when the next clause is on its way. See
  /// [ChatSession.speakBoundaries] for the full contract.
  Stream<void> get speakBoundaries => _speakBoundaries.stream;

  /// Text replies from the current session.
  Stream<String> get replyText => _replyText.stream;

  /// Brain-inferred mood transitions forwarded from the current
  /// session. Only fires when the underlying session is
  /// [MseStreamChatSession] (Adapter 1) — v1.3 and on-device sessions
  /// have no mood path, per the port spec §4.11 and §11.
  ///
  /// The mood is per-turn: the server emits at most one event per
  /// `sendMessage` reply, carried on the `X-Mood` +
  /// `X-Mood-Humanized` response headers on `POST /ext-api/human`.
  /// See `Mood` enum and `MoodEvent` in `twai_avatar_sdk_core` for
  /// the wire format details.
  ///
  /// **Survives session rotation.** Subscriptions on this stream
  /// stay live across reconnects; the controller re-attaches to the
  /// fresh session's mood stream on each connect.
  Stream<MoodEvent> get moodEvents => _moodEvents.stream;

  /// The last mood observed, or `null` before the first mood event
  /// of the controller's lifetime. Persists across session rotation
  /// (a reconnect keeps the last mood visible until the next turn's
  /// server response overwrites it — matches the reference which
  /// treats mood as sticky per-avatar).
  MoodEvent? get currentMood => _currentMood;
  MoodEvent? _currentMood;

  /// XP awards. Fires immediately when [awardXp] is called during
  /// [PlayerStatus.ready] / non-speech; queued while
  /// [PlayerStatus.speaking] and drained on the next `ready`
  /// transition. Stale events (queued longer than
  /// [PlayerConfig.pendingLevelUpMaxDelay]) are dropped rather than
  /// fired. Port spec §11.
  ///
  /// The SDK does not classify XP amounts into bands or compute
  /// level thresholds — the app is authoritative on progression math
  /// (server-derived). This stream is a delivery discipline, not a
  /// gamification engine.
  Stream<XpEvent> get xpEvents => _xpEvents.stream;

  /// Level threshold crossings. Same delivery discipline as
  /// [xpEvents] — deferred while speaking, drained on `ready`, stale
  /// events dropped. Consumed by an app-side level-up modal.
  Stream<LevelUpEvent> get levelUpEvents => _levelUpEvents.stream;

  /// Overlay-clip play requests. Fires once per [playOverlay] call
  /// (or the extension helpers `playGesture` / `playFrame`). The app
  /// subscribes and renders the overlay video against its own widget;
  /// when playback ends the app calls [notifyOverlayEnded]. Port
  /// spec §2.6 / §7.
  ///
  /// **Not deferred while speaking** — the reference lets user-tap
  /// emotes fire immediately, overlaying the live speech. Muting of
  /// the live audio during the overlay is app-side (guided by
  /// [OverlayEvent.muteLive]).
  Stream<OverlayEvent> get overlayEvents => _overlayEvents.stream;

  /// `true` between an overlay play request and the app's
  /// [notifyOverlayEnded] callback. Apps can use this to gate other
  /// overlay-triggering UI (e.g. disable the emote panel while an
  /// emote is playing to avoid stacking).
  bool get isOverlayPlaying => _isOverlayPlaying;
  bool _isOverlayPlaying = false;

  // ══════════════════════════════════════════════════════════════════
  // Internal state (reference controller.ts equivalents)
  // ══════════════════════════════════════════════════════════════════

  /// The active session. Rotates on every connect + reconnect.
  ChatSession? _session;

  /// Read-only view of the active session for sinks that need adapter-
  /// specific streams the shim doesn't expose (e.g. LiveKitVideoSink
  /// reads the WebRTC video-track stream off LiveKitChatSession — the
  /// [_ControllerFeedShim] only surfaces `videoBytes`/`speakingEvents`
  /// which are wire-agnostic MSE concepts). Null before first connect;
  /// rotates on every connect + reconnect.
  ChatSession? get currentSession => _session;

  /// Subscriptions to the current session's streams. Cancelled + reset
  /// on every teardown.
  StreamSubscription<Uint8List>? _videoSub;
  StreamSubscription<SpeakingEvent>? _speakingSub;
  StreamSubscription<String>? _replySub;
  StreamSubscription<void>? _speakBoundarySub;
  StreamSubscription<MoodEvent>? _moodSub;

  /// Stashed avatar from the first [connect]. Used to reconnect with
  /// the same target without the caller having to pass it again.
  Avatar? _avatar;

  /// Every connect attempt bumps this. Every async callback that
  /// straddles a potential teardown captures the value at entry and
  /// checks [_stale] before touching controller state. Port spec §12.1.7.
  int _connectAttemptId = 0;

  /// `true` while a reconnect is in flight. Enforces single-flight
  /// through [_ensureConnected]. Port spec §2.2.
  bool _reconnecting = false;

  /// Reconnect attempt counter for the current disconnect episode.
  /// Resets to 0 on successful `ready`. Port spec §2.3.
  int _reconnectAttempts = 0;

  /// Timer for the current backoff wait. Cancelled on teardown /
  /// dispose / manualReconnect.
  Timer? _reconnectTimer;

  /// Periodic tick that checks WS liveness by comparing
  /// [_lastWsMessageTsMs] against [PlayerConfig.wsSilence]. Started
  /// on first-frame arrival; cancelled on teardown/dispose. Detects
  /// iOS zombie WebSockets where `readyState` still reports OPEN but
  /// no frames arrive. Port spec §12.1.2.
  Timer? _livenessTimer;

  /// Fires [PlayerConfig.speakWatchdog] after a `send()` call if no
  /// [SpeakingState.start] event has arrived yet. Backstop for stuck
  /// TTS / render pipeline. Port spec §12.1.6.
  Timer? _speakWatchdog;

  /// Fires [PlayerConfig.resumeRecovery] after a connect if no video
  /// frame has arrived yet. Covers the iOS `ManagedMediaSource`
  /// gesture-less wedge — session handshake succeeds but the decoder
  /// never starts producing. Port spec §12.1.1.
  Timer? _resumeRecoveryTimer;

  /// Mid-reply "stuck talking" watchdog. Armed when speaking:start
  /// fires; disarmed when speaking:stop fires. Between those, checks
  /// [PlayerConfig.stuckTalkingCeiling] since the last liveness
  /// signal (playhead advance / new speaking event / new video bytes).
  /// On fire: forces status back to [PlayerStatus.ready] to unstick
  /// the crossfade. Absorbed from 2wai-edu's Watchdog B.
  Timer? _stuckTalkingTimer;

  /// Wall-clock ms of the most recent liveness signal during a
  /// speaking-state window (playhead advance, new speaking event,
  /// or new video bytes). Reset on each speaking:start; nulled on
  /// speaking:stop. See [_notifyLiveness] + [_stuckTalkingTimer].
  int? _lastLivenessMs;

  /// Wall-clock timestamp of the most recent WS message (video-bytes
  /// frame). Read by the liveness heartbeat (port spec §12.1.2 — iOS
  /// zombie WS detection). `0` before the first message of the current
  /// session.
  // ignore: unused_field
  int _lastWsMessageTsMs = 0;

  /// Wall-clock timestamp of the most recent successful `ready`
  /// transition. Used to distinguish a mid-turn drop (worth notifying
  /// the user about) from a fresh-session flap. Port spec §12.4.4.
  /// Currently tracked but not read — feeds the "disconnect episode"
  /// dedup logic in a subsequent slice.
  // ignore: unused_field
  int _lastSuccessfulConnectTsMs = 0;

  /// Set on `sendMessage` and cleared on the first speaking event of
  /// the turn (or watchdog fire). Prevents false-positive speak
  /// watchdog fires. Port spec §12.1.6.
  // ignore: unused_field
  bool _awaitingSpeakingForChat = false;

  /// Per-session jitter margin (seconds). Bumps by
  /// [PlayerConfig.jitterMarginStepSec] on each mid-speech stall,
  /// caps at [PlayerConfig.jitterMarginMaxSec], resets on connect.
  /// Port spec §12.1.3.
  ///
  /// Read by the sink through [jitterMarginSec] when computing where
  /// to land a live-edge seek. Higher margin = smoother playback on
  /// jittery links, at the cost of higher latency.
  double _jitterMarginSec = 0.0;

  /// Wall-clock timestamp of the last jitter-margin bump. Used by
  /// [notifyStall] to enforce [PlayerConfig.stallDebounce] — don't
  /// bump on every stall, batch them. Port spec §3
  /// (`stallDebounce = 2000ms`).
  int _lastStallBumpMs = 0;

  /// Held message awaiting the next [PlayerStatus.ready] transition.
  /// Populated when [send] is called while the session isn't ready.
  /// Auto-drains via [_doSend] on first-frame arrival. **Survives
  /// [_teardownCurrentSession]** so a held message reaches the fresh
  /// session — port spec §12.1.8.
  String? _pendingSend;

  /// Most recent text that actually reached [ChatSession.sendMessage].
  /// Used for the duplicate-send debounce (port spec §3 —
  /// `DUPLICATE_SEND_WINDOW_MS = 3000`).
  String? _lastSentText;
  int _lastSentAtMs = 0;

  /// Last playback time reported by the caller via
  /// [updatePlaybackTime]. Used to PTS-gate speaking events per port
  /// spec §5.1 ("PTS-gated speaking events"). `null` means no sink
  /// integration is providing playback time — events fire immediately.
  double? _lastPlaybackTimeSec;

  /// Pure, DOM-free pts-gate for speaking events (ported bit-for-bit
  /// from twai-web-sdk/packages/core/src/speakingGate.ts, conformance
  /// vectors at `twai_avatar_sdk_core/test/conformance/`). Reset on
  /// teardown — pts values belong to the ended session's timeline.
  /// Fires the state transition via [_fireSpeakingTransition] once
  /// the playhead reaches an enqueued event's pts.
  late final SpeakingGate _speakingGate = SpeakingGate(
    onFire: _fireSpeakingTransition,
  );

  /// `true` while a greeting is playing and user input should be
  /// held. Port spec §2.7 / §12.4.3 — the lock **survives session
  /// teardown**, so a reconnect during the greeting doesn't unlock
  /// user input.
  bool _greetingLockActive = false;
  Timer? _greetingLockTimer;

  /// If non-null, the first user [send] after the greeting must
  /// await this future (with [PlayerConfig.heldSendTimeout] safety
  /// timeout) before the message reaches the transport. This is the
  /// load-bearing race fix from port spec §12.2.3 — without it, the
  /// user's first reply lands at the brain **before** the greeting
  /// has been logged to conversation_history, and the brain answers
  /// with something like "who is that?".
  ///
  /// Cleared after the first send; subsequent sends bypass. Set via
  /// [beginGreeting], cleared on [dispose] and after successful drain.
  Future<void>? _firstGreetingSeenPromise;

  bool _disposed = false;

  // ══════════════════════════════════════════════════════════════════
  // Public API
  // ══════════════════════════════════════════════════════════════════

  /// Connect the controller to [avatar] and start the state machine.
  ///
  /// The avatar is stashed so reconnect episodes can reuse it. To
  /// switch avatars, call [dispose] and construct a new controller.
  ///
  /// This method awaits the initial connection outcome. On success it
  /// returns after [PlayerStatus.ready] is emitted. On transient
  /// failure it may return after the first backoff schedule is armed
  /// (with status = connecting) — the caller does NOT need to await
  /// the reconnect episode.
  ///
  /// Idempotent: calling twice while a session is live is a no-op.
  Future<void> connect(Avatar avatar) async {
    _assertNotDisposed();
    _avatar = avatar;
    await _ensureConnected(force: false);
  }

  /// Send a chat message.
  ///
  /// **Held-send / duplicate-debounce / greeting-lock gating not yet
  /// ported.** Currently throws if the session is not
  /// [PlayerStatus.ready]. Port spec §4.5 + §12.1.8.
  /// Send a chat message.
  ///
  /// **Duplicate-send debounce:** if [text] matches the most recent
  /// message that reached the transport within
  /// [PlayerConfig.duplicateSendWindow], the call is silently dropped.
  /// Rapid re-taps of the SEND button collapse to a single wire send.
  /// Port spec §3 (`DUPLICATE_SEND_WINDOW_MS = 3000`).
  ///
  /// **Held-send discipline:** if the session isn't [PlayerStatus.ready]
  /// (e.g. mid-reconnect, waiting for first frame), the message is
  /// stashed as [_pendingSend] and auto-resent when the next `ready`
  /// transition fires. The held message **survives session teardown**
  /// — port spec §12.1.8. If a new [send] arrives before the previous
  /// held message drains, the new text replaces the held one (most-
  /// recent-wins).
  Future<void> send(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) async {
    _assertNotDisposed();

    // Duplicate-send debounce (port spec §3).
    if (_lastSentText == text) {
      final ageMs =
          DateTime.now().millisecondsSinceEpoch - _lastSentAtMs;
      if (ageMs < config.duplicateSendWindow.inMilliseconds) {
        return;
      }
    }

    // Greeting input lock (port spec §2.7). Held-send equivalent —
    // the message stashes and drains when the lock expires.
    if (_greetingLockActive) {
      _pendingSend = text;
      return;
    }

    // Held-send discipline (port spec §12.1.8).
    final session = _session;
    if (session == null || _currentStatus != PlayerStatus.ready) {
      _pendingSend = text;
      return;
    }

    await _doSend(
      session,
      text,
      gamificationLevel: gamificationLevel,
      avatarStateBlock: avatarStateBlock,
    );
  }

  /// Notify the controller that a greeting is being played by the app.
  ///
  /// This does NOT play the greeting — the app owns the fetch (e.g.
  /// `GET /chat/greeting/{slug}`) and the playback (via its sink or
  /// an overlay video element). What this method does is enforce the
  /// two SDK-level disciplines around greeting:
  ///
  /// 1. **Input lock** — user [send] calls are held for
  ///    [lockDuration] (default [PlayerConfig.greetingInputLock] =
  ///    5s). Draining happens automatically when the timer expires,
  ///    so a message typed during the greeting reaches the transport
  ///    as soon as the lock lifts.
  ///
  /// 2. **`/seen` race gate** — if [firstGreetingSeen] is non-null,
  ///    the very first user [send] after the greeting awaits it
  ///    (with [PlayerConfig.heldSendTimeout] safety) before the
  ///    message reaches the transport. This is the port spec §12.2.3
  ///    fix — without it, the user's first reply can outrun the
  ///    greeting's `/seen` POST and the brain answers with an empty
  ///    conversation-history reply ("Alex, who is that?").
  ///
  /// Both the input lock and the pending future **survive session
  /// teardown** (port spec §12.4.3). A reconnect during the greeting
  /// does not unlock the composer or drop the `/seen` gate.
  ///
  /// Pass `firstGreetingSeen: null` for return-visit greetings (the
  /// server has already logged the greeting; no `/seen` POST needed).
  void beginGreeting({
    Duration? lockDuration,
    Future<void>? firstGreetingSeen,
  }) {
    _assertNotDisposed();
    _greetingLockActive = true;
    _firstGreetingSeenPromise = firstGreetingSeen;
    _greetingLockTimer?.cancel();
    _greetingLockTimer = Timer(lockDuration ?? config.greetingInputLock, () {
      _greetingLockTimer = null;
      _greetingLockActive = false;
      _drainPendingSend();
    });
  }

  /// The wire send. Extracted from [send] so held messages can drain
  /// through the same path without re-triggering the duplicate-send
  /// debounce (a held message re-sending isn't a duplicate — it's the
  /// same message reaching the wire for the first time).
  Future<void> _doSend(
    ChatSession session,
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) async {
    // First-greeting `/seen` race gate (port spec §12.2.3). Both the
    // send() path AND the drain-on-lock-expiry path funnel through
    // here, so the gate applies uniformly regardless of how the send
    // was queued.
    await _maybeWaitForGreetingSeen();
    _lastSentText = text;
    _lastSentAtMs = DateTime.now().millisecondsSinceEpoch;
    // Set BEFORE sendMessage returns, so that if the brain-side
    // pipeline fires {speaking:start} while sendMessage is still
    // awaiting, the flag has already been armed and the handler in
    // _handleSpeakingEvent clears it correctly. Port spec §12.1.6.
    _awaitingSpeakingForChat = true;
    await session.sendMessage(
      text,
      gamificationLevel: gamificationLevel,
      avatarStateBlock: avatarStateBlock,
    );
    if (_awaitingSpeakingForChat) {
      _armSpeakWatchdog();
    }
  }

  /// If a first-greeting `/seen` promise is pending, await it with a
  /// safety timeout so a wedged POST never blocks chat indefinitely.
  /// After the first call, clears the promise so subsequent sends
  /// don't re-await.
  Future<void> _maybeWaitForGreetingSeen() async {
    final p = _firstGreetingSeenPromise;
    if (p == null) return;
    _firstGreetingSeenPromise = null;
    try {
      await p.timeout(config.heldSendTimeout);
    } catch (_) {
      // Timeout OR app-side rejection — either way, don't block the
      // user. The reference behavior treats /seen as best-effort with
      // a safety cap; matches here.
    }
  }

  /// Update the player's known video playback time (seconds). Enables
  /// PTS-gated speaking events per port spec §5.1: when a
  /// [SpeakingEvent] arrives with `pts > lastPlaybackTime`, the state
  /// transition is queued until playback catches up. Without this
  /// gating, speech-onset UI (composer disable, etc.) fires before the
  /// avatar actually starts moving.
  ///
  /// **Wire this from the video sink's playhead callback** (typically
  /// once per rendered frame or on `timeupdate`). If never called,
  /// speaking events fire immediately on arrival — that's a legitimate
  /// mode for callers that don't need speech-onset precision.
  void updatePlaybackTime(double seconds) {
    _lastPlaybackTimeSec = seconds;
    _speakingGate.tick(seconds);
    // Liveness ping for the stuck-talking watchdog: any playhead
    // advance during a speaking-state window resets the ceiling.
    // Cheap (just a timestamp write) so calling on every frame is
    // fine — the watchdog only reads it when armed.
    if (_currentStatus == PlayerStatus.speaking) {
      _notifyLiveness();
    }
  }

  /// Notify the controller that the user just earned XP. Fires an
  /// [XpEvent] on [xpEvents] immediately if the avatar is not
  /// speaking; otherwise queues until the next [PlayerStatus.ready]
  /// transition, dropping the event if it's still queued after
  /// [PlayerConfig.pendingLevelUpMaxDelay]. Port spec §11.
  ///
  /// [amount], [band], and optional [reason] come from the server /
  /// app's progression system — the controller doesn't classify or
  /// compute anything, just disciplines delivery.
  void awardXp(int amount, {required XpBand band, String? reason}) {
    _assertNotDisposed();
    final ev = XpEvent(
      amount: amount,
      band: band,
      timestamp: DateTime.now(),
      reason: reason,
    );
    if (_currentStatus == PlayerStatus.speaking) {
      _pendingXp.add(ev);
    } else if (!_xpEvents.isClosed) {
      _xpEvents.add(ev);
    }
  }

  /// Notify the controller that the user just crossed a level
  /// threshold. Same delivery discipline as [awardXp]. The
  /// [LevelUpEvent] carries the metadata the app renders in its
  /// level-up modal (reward thumbnail, session progress, etc).
  void notifyLevelUp(
    int newLevel, {
    int? previousLevel,
    String? rewardTitle,
    String? rewardThumbnailUrl,
    int? sessionLevelUpIndex,
    int? sessionLevelUpTotal,
  }) {
    _assertNotDisposed();
    final ev = LevelUpEvent(
      newLevel: newLevel,
      previousLevel: previousLevel,
      timestamp: DateTime.now(),
      rewardTitle: rewardTitle,
      rewardThumbnailUrl: rewardThumbnailUrl,
      sessionLevelUpIndex: sessionLevelUpIndex,
      sessionLevelUpTotal: sessionLevelUpTotal,
    );
    if (_currentStatus == PlayerStatus.speaking) {
      _pendingLevelUp.add(ev);
    } else if (!_levelUpEvents.isClosed) {
      _levelUpEvents.add(ev);
    }
  }

  /// Emit an overlay-play request on [overlayEvents]. The app
  /// subscribes and renders playback; when it finishes, the app
  /// calls [notifyOverlayEnded].
  ///
  /// This is the transport-agnostic primitive. Apps that use the
  /// [PlayerGesture] / [PlayerFrame] content-layer types can call
  /// the extension helpers `playGesture` / `playFrame` for the
  /// obvious composition.
  void playOverlay({
    required OverlayKind kind,
    required String url,
    required bool muteLive,
    String? id,
    String? slug,
  }) {
    _assertNotDisposed();
    _isOverlayPlaying = true;
    if (!_overlayEvents.isClosed) {
      _overlayEvents.add(OverlayEvent(
        kind: kind,
        url: url,
        muteLive: muteLive,
        id: id,
        slug: slug,
      ));
    }
  }

  /// Notify the controller that the current overlay finished playing
  /// (via the app's video element's `onended` / `onerror` / user
  /// interrupt). Clears [isOverlayPlaying].
  void notifyOverlayEnded() {
    if (_disposed) return;
    _isOverlayPlaying = false;
  }

  /// Fire queued XP + level-up events whose timestamps are still
  /// within [PlayerConfig.pendingLevelUpMaxDelay]. Drop stale ones.
  /// Called from [_emitStatus] on transitions into
  /// [PlayerStatus.ready].
  void _drainPendingProgression() {
    if (_pendingXp.isEmpty && _pendingLevelUp.isEmpty) return;
    final now = DateTime.now();
    final maxAge = config.pendingLevelUpMaxDelay;
    for (final ev in _pendingXp) {
      if (now.difference(ev.timestamp) > maxAge) continue;
      if (!_xpEvents.isClosed) _xpEvents.add(ev);
    }
    _pendingXp.clear();
    for (final ev in _pendingLevelUp) {
      if (now.difference(ev.timestamp) > maxAge) continue;
      if (!_levelUpEvents.isClosed) _levelUpEvents.add(ev);
    }
    _pendingLevelUp.clear();
  }

  /// Notify the controller that the video sink observed a mid-speech
  /// stall (e.g. MSE `waiting` event). Bumps [jitterMarginSec] by
  /// [PlayerConfig.jitterMarginStepSec], capped at
  /// [PlayerConfig.jitterMarginMaxSec]. **Debounced by
  /// [PlayerConfig.stallDebounce]** — rapid consecutive stalls
  /// collapse into a single bump so a jittery connection doesn't
  /// saturate the margin in one bad second. Port spec §12.1.3.
  ///
  /// Should be called ONLY for stalls that happen during active
  /// speech (i.e. while [PlayerStatus] is [PlayerStatus.speaking]).
  /// Idle-time stalls are the sink's problem, not the state
  /// machine's.
  void notifyStall() {
    _assertNotDisposed();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastStallBumpMs > 0 &&
        now - _lastStallBumpMs < config.stallDebounce.inMilliseconds) {
      return; // debounce window still active
    }
    _lastStallBumpMs = now;
    final bumped = _jitterMarginSec + config.jitterMarginStepSec;
    _jitterMarginSec = bumped > config.jitterMarginMaxSec
        ? config.jitterMarginMaxSec
        : bumped;
  }

  /// Compute where the video sink should seek the playhead, given the
  /// current playback position and buffered live-edge position.
  ///
  /// Returns `null` when no clamp is needed (either the lag is under
  /// [PlayerConfig.clampTriggerLagSec] or the target would land at or
  /// behind current playback). Returns a target time (seconds) when
  /// the sink should `seek(target)`.
  ///
  /// The target lands [PlayerConfig.clampTargetBehindSec] behind the
  /// live edge, widened by the current [jitterMarginSec]. If a queued
  /// speaking-start event's PTS is within
  /// [PlayerConfig.speechOnsetPrerollSec] of the computed target, the
  /// target is held back to `pts - speechOnsetPrerollSec` so speech
  /// onset isn't cut short by a mid-seek. Port spec §5.1 + §12.1.5.
  double? computeClampTargetSec({
    required double playbackTimeSec,
    required double bufferEndSec,
  }) {
    if (_disposed) return null;

    // Hard-refuse-seek while currently speaking. Jumping the playhead
    // during a reply would skip past rendered audio — the user hears
    // the avatar cut off mid-word or lose content entirely. Wait for
    // the stop transition (i.e. status flips back to ready) before
    // clamping. Verified against 2wai-edu's useMseAvatarPlayer
    // (lines 195-207 + 231-240) — same discipline.
    if (_currentStatus == PlayerStatus.speaking) return null;

    final lag = bufferEndSec - playbackTimeSec;
    if (lag < config.clampTriggerLagSec) return null;

    var target =
        bufferEndSec - config.clampTargetBehindSec - _jitterMarginSec;

    // Speech-onset preroll — never seek past a pending speaking:start
    // by more than [config.speechOnsetPrerollSec]. Otherwise the
    // avatar starts talking mid-seek and looks broken.
    for (final ev in _speakingGate.pendingEvents) {
      if (ev.value != SpeakingState.start) continue;
      // Skip null-pts (legacy no-pts) events — SpeakingGate coerces
      // them to -Infinity to fire immediately on the next tick;
      // they're transient in the queue and carry no seek constraint.
      if (!ev.pts.isFinite) continue;
      final maxSeek = ev.pts - config.speechOnsetPrerollSec;
      if (target > maxSeek) target = maxSeek;
    }

    if (target <= playbackTimeSec) return null;
    return target;
  }

  /// Manual reconnect entry — called from the "tap to reconnect"
  /// gesture overlay after [PlayerConfig.maxReconnectAttempts] have
  /// been exhausted. Resets the attempt counter and retries once.
  ///
  /// This method MUST be called from a user-gesture callback on
  /// mobile/web — iOS `ManagedMediaSource` requires a live gesture
  /// for autoplay to succeed (port spec §12.1.1).
  Future<void> manualReconnect() async {
    _assertNotDisposed();
    _reconnectAttempts = 0;
    _exhausted = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _ensureConnected(force: true);
  }

  /// Swap the target avatar and reconnect mid-session. The primary
  /// primitive apps use to implement outfit / avatar switching
  /// without disposing the controller.
  ///
  /// Effects:
  /// - Stashes [avatar] as the new target (replaces the previous one).
  /// - Clears [currentMood] — mood is per-avatar; the previous
  ///   avatar's mood is no longer relevant.
  /// - Forces a full teardown + fresh session against [avatar] with
  ///   the same discipline as [manualReconnect] (attempt counter
  ///   reset, exhausted flag cleared, backoff timer cancelled). The
  ///   `_teardownCurrentSession` inside `_ensureConnected` resets
  ///   per-session state (jitter margin, playback time, pending
  ///   speaking queue).
  /// - `_pendingSend` is deliberately NOT cleared — if the user
  ///   typed something during the switch, it drains on the fresh
  ///   session's first-frame (port spec §12.1.8 discipline).
  ///
  /// **Ownership contract**: on top of [ChatSession] the app builds
  /// outfit-picking + persona metadata; the controller owns transport
  /// discipline. See `docs/port_spec_avatar_player.md` §2.5 for the
  /// full outfit-switch flow — the transition overlay + idle swap +
  /// prefetch are sink/app concerns and don't belong in the
  /// controller.
  Future<void> changeAvatar(Avatar avatar) async {
    _assertNotDisposed();
    _avatar = avatar;
    _currentMood = null;
    _reconnectAttempts = 0;
    _exhausted = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _ensureConnected(force: true);
  }

  /// Tear down the controller. Cancels any in-flight reconnect,
  /// closes the current session, closes all broadcast streams. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_connectAttemptId; // stale all in-flight async handlers
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _greetingLockTimer?.cancel();
    _greetingLockTimer = null;
    _greetingLockActive = false;
    _firstGreetingSeenPromise = null;
    _pendingSend = null;
    await _teardownCurrentSession();
    await _status.close();
    await _videoBytes.close();
    await _speakingEvents.close();
    await _speakBoundaries.close();
    await _replyText.close();
    await _moodEvents.close();
    await _xpEvents.close();
    await _levelUpEvents.close();
    await _overlayEvents.close();
    _pendingXp.clear();
    _pendingLevelUp.clear();
    _isOverlayPlaying = false;
    if (!_done.isCompleted) {
      _done.complete(const PlayerDisposed());
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Reconnect discipline — port spec §2.2, §2.3, §12.1.7
  // ══════════════════════════════════════════════════════════════════

  /// The single-flight reconnect funnel. Guarantees that at most one
  /// connect-in-flight exists at a time and that a stale reconnect
  /// can't stomp a fresh one.
  ///
  /// Flow (port spec §2.2):
  /// 1. Bail if disposed.
  /// 2. If a reconnect is already in flight — return, let the timer
  ///    chain handle progression.
  /// 3. If not [force] and the current session is healthy (recent
  ///    frames) — no-op.
  /// 4. Bump [_connectAttemptId] to invalidate all previous handlers.
  /// 5. Teardown the current session (cancels subs, closes WS).
  /// 6. Build a fresh session via [sessionFactory] and wire streams.
  /// 7. Call `session.connect(_avatar)`.
  /// 8. On success — reset attempt counter, emit `ready`.
  /// 9. On failure — emit `failed`, schedule backoff retry.
  Future<void> _ensureConnected({required bool force}) async {
    if (_disposed) return;
    if (_reconnecting) return;
    if (_avatar == null) {
      throw StateError(
        '_ensureConnected() before connect() — no avatar stashed.',
      );
    }

    // Liveness shortcut (port spec §2.2 step 3): if force=false and
    // the current session has seen a recent frame, no-op.
    if (!force &&
        _session != null &&
        _currentStatus == PlayerStatus.ready &&
        _lastWsMessageTsMs > 0) {
      final ageMs =
          DateTime.now().millisecondsSinceEpoch - _lastWsMessageTsMs;
      if (ageMs < config.wsSilence.inMilliseconds) return;
    }

    _reconnecting = true;
    final myAttempt = ++_connectAttemptId;

    await _teardownCurrentSession();
    if (_stale(myAttempt)) {
      _reconnecting = false;
      return;
    }

    _emitStatus(PlayerStatus.connecting, attempt: _reconnectAttempts);

    final ChatSession fresh;
    try {
      fresh = sessionFactory();
    } catch (e) {
      _reconnecting = false;
      _emitStatus(PlayerStatus.failed,
          attempt: _reconnectAttempts, cause: e);
      _scheduleReconnect(cause: e);
      return;
    }

    _session = fresh;
    _wireSessionStreams(fresh, myAttempt);
    _armResumeRecovery(myAttempt);

    try {
      await fresh.connect(_avatar!);
      if (_stale(myAttempt)) return;
      // NOTE: handshake succeeded, but per port spec the `ready`
      // status flip happens on FIRST-FRAME arrival, not on connect()
      // return. The videoBytes listener in `_wireSessionStreams`
      // handles that transition + cancels the resume-recovery
      // watchdog + resets `_reconnectAttempts` / `_exhausted`.
      _reconnecting = false;
    } catch (e) {
      if (_stale(myAttempt)) return;
      _reconnecting = false;
      _cancelResumeRecovery();
      _emitStatus(PlayerStatus.failed,
          attempt: _reconnectAttempts, cause: e);
      _scheduleReconnect(cause: e);
    }
  }

  /// Schedule the next reconnect attempt with exponential backoff. If
  /// [PlayerConfig.maxReconnectAttempts] has already been reached,
  /// resolve [done] with [PlayerExhausted] instead of scheduling.
  /// Port spec §2.3.
  void _scheduleReconnect({Object? cause}) {
    if (_disposed) return;
    _reconnectTimer?.cancel();

    if (_reconnectAttempts >= config.maxReconnectAttempts) {
      // Auto-recovery exhausted — flip the state flag + emit failed,
      // but do NOT complete `_done`. Exhaustion is a UI state (per
      // port spec §2.3: "tap to reconnect" gesture overlay), not a
      // terminal one. The app calls `manualReconnect()` on user tap
      // to reset the counter and try again. `_done` only completes
      // on explicit `dispose()` or truly-permanent transport failures
      // flagged by [ChatSessionFailed.isPermanent].
      _exhausted = true;
      _emitStatus(PlayerStatus.failed,
          attempt: _reconnectAttempts, cause: cause);
      return;
    }

    _reconnectAttempts++;
    final delay = config.backoffForAttempt(_reconnectAttempts);
    _emitStatus(
      PlayerStatus.connecting,
      attempt: _reconnectAttempts,
      reconnectDelay: delay,
      cause: cause,
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      // ignore: discarded_futures
      _ensureConnected(force: true);
    });
  }

  /// Subscribe to the fresh session's streams and forward through the
  /// controller's own broadcast streams. Every callback checks
  /// [_stale] to bail cleanly if a teardown has since fired.
  void _wireSessionStreams(ChatSession session, int myAttempt) {
    _videoSub = session.videoBytes.listen((bytes) {
      if (_stale(myAttempt)) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final firstFrame = _lastWsMessageTsMs == 0;
      _lastWsMessageTsMs = now;
      // Any incoming bytes during a speaking-state window count as
      // liveness for the stuck-talking ceiling — even if the playhead
      // is momentarily stalled, the pipeline is still producing.
      if (_currentStatus == PlayerStatus.speaking) {
        _notifyLiveness();
      }
      if (firstFrame) {
        // Cache the init segment (ftyp+moov) so late-mounted sinks
        // can prepend it before appending mid-stream fragments. See
        // [cachedInitSegment] docstring for the multi-TwaiPlayer bug
        // this fixes.
        _cachedInitSegment = bytes;
        // This is the "onPlaying" analog per port spec — the
        // pipeline is producing content. Clear the resume-recovery
        // watchdog and flip to ready. Also the point at which we
        // stamp `_lastSuccessfulConnectTsMs` (used by the disconnect-
        // episode dedup in §12.4.4).
        _cancelResumeRecovery();
        _lastSuccessfulConnectTsMs = now;
        _reconnectAttempts = 0;
        _exhausted = false;
        _startLivenessHeartbeat();
        _emitStatus(PlayerStatus.ready, attempt: 0);
        _drainPendingSend();
      }
      if (!_videoBytes.isClosed) _videoBytes.add(bytes);
    });
    _speakingSub = session.speakingEvents.listen((ev) {
      if (_stale(myAttempt)) return;
      if (!_speakingEvents.isClosed) _speakingEvents.add(ev);
      _handleSpeakingEvent(ev);
    });
    _replySub = session.replyText.listen((text) {
      if (_stale(myAttempt)) return;
      if (!_replyText.isClosed) _replyText.add(text);
    });
    _speakBoundarySub = session.speakBoundaries.listen((_) {
      if (_stale(myAttempt)) return;
      if (!_speakBoundaries.isClosed) _speakBoundaries.add(null);
    });
    // Mood is Adapter 1-specific (X-Mood / X-Mood-Humanized response
    // headers). v1.3 + on-device sessions have no mood path — the
    // narrowing check just skips subscription for those. Port spec
    // §4.11.
    if (session is MseStreamChatSession) {
      _moodSub = session.moodEvents.listen((ev) {
        if (_stale(myAttempt)) return;
        _currentMood = ev;
        if (!_moodEvents.isClosed) _moodEvents.add(ev);
      });
    }
    // Session `done` future signals terminal transport end. Route to
    // the reconnect/exhaust decision.
    // ignore: discarded_futures
    session.done.then((reason) {
      if (_stale(myAttempt)) return;
      _onSessionDone(reason);
    });
  }

  /// Cancel current-session subscriptions, cancel all watchdogs, and
  /// close the current session. Safe to call even if there's no active
  /// session. Errors during close are swallowed — we're already
  /// tearing down.
  Future<void> _teardownCurrentSession() async {
    _cancelResumeRecovery();
    _cancelSpeakWatchdog();
    _cancelStuckTalkingWatchdog();
    _stopLivenessHeartbeat();
    await _videoSub?.cancel();
    _videoSub = null;
    await _speakingSub?.cancel();
    _speakingSub = null;
    await _replySub?.cancel();
    _replySub = null;
    await _speakBoundarySub?.cancel();
    _speakBoundarySub = null;
    await _moodSub?.cancel();
    _moodSub = null;
    // NOTE: `_currentMood` deliberately survives teardown. Mood is
    // sticky per-avatar across reconnects until the next turn's
    // response arrives — matches the reference.
    _lastWsMessageTsMs = 0;
    // Drop the cached init segment — a fresh session will emit its own
    // first-frame init on reconnect. See [cachedInitSegment] docstring.
    _cachedInitSegment = null;
    _awaitingSpeakingForChat = false;
    _jitterMarginSec = 0.0;
    _lastStallBumpMs = 0;
    // Pending speaking events belong to the old session's PTS
    // timeline — drop. `_pendingSend` deliberately survives per port
    // spec §12.1.8; the held message auto-resends on the fresh
    // session's first-frame arrival.
    _speakingGate.reset();
    _lastPlaybackTimeSec = null;
    final s = _session;
    _session = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {
        // Session already dead or errored — nothing more to do.
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Watchdogs — port spec §12.1.1, §12.1.2, §12.1.6
  // ══════════════════════════════════════════════════════════════════

  /// Arm the resume-recovery watchdog. Fires
  /// [PlayerConfig.resumeRecovery] after the connect attempt if no
  /// video frame has arrived by then, forcing a reconnect. The
  /// [expectedAttempt] guard ensures a fire from a stale timer
  /// doesn't affect a subsequent attempt.
  void _armResumeRecovery(int expectedAttempt) {
    _cancelResumeRecovery();
    _resumeRecoveryTimer = Timer(config.resumeRecovery, () {
      _resumeRecoveryTimer = null;
      if (_stale(expectedAttempt)) return;
      if (_currentStatus == PlayerStatus.ready) return; // first frame arrived
      _scheduleReconnect(cause: 'resume recovery timeout');
    });
  }

  void _cancelResumeRecovery() {
    _resumeRecoveryTimer?.cancel();
    _resumeRecoveryTimer = null;
  }

  /// Arm the speak watchdog after a `send()`. Fires
  /// [PlayerConfig.speakWatchdog] if no [SpeakingState.start] arrives.
  /// The `_awaitingSpeakingForChat` flag is the primary defense
  /// against false-positives (see [send] + [_handleSpeakingEvent]);
  /// this timer is the backstop for genuinely stuck TTS/render.
  void _armSpeakWatchdog() {
    _cancelSpeakWatchdog();
    _speakWatchdog = Timer(config.speakWatchdog, () {
      _speakWatchdog = null;
      if (!_awaitingSpeakingForChat) return; // speaking arrived, false alarm
      _awaitingSpeakingForChat = false;
      _scheduleReconnect(cause: 'speak watchdog timeout');
    });
  }

  void _cancelSpeakWatchdog() {
    _speakWatchdog?.cancel();
    _speakWatchdog = null;
  }

  /// Arm the mid-reply stuck-talking watchdog. Called from
  /// [_fireSpeakingTransition] on start-transition fire (playhead has
  /// crossed the start PTS, we are visibly speaking). Fires
  /// [PlayerConfig.stuckTalkingCeiling] after the last liveness
  /// signal — playhead advance, incoming speaking event, or incoming
  /// video bytes. On fire, force status to [PlayerStatus.ready] so
  /// the crossfade returns to idle rather than freezing on a stuck
  /// speaking layer.
  ///
  /// This is Watchdog B in 2wai-edu's naming (useMseAvatarPlayer.ts:332-340).
  /// Distinct from [_armSpeakWatchdog] (Watchdog A, connect-side —
  /// fires if speaking:start never arrived).
  void _armStuckTalkingWatchdog() {
    _cancelStuckTalkingWatchdog();
    _notifyLiveness();
    _stuckTalkingTimer =
        Timer.periodic(config.livenessHeartbeat, (_) {
      if (_disposed) return;
      // Auto-disarm if we're no longer speaking.
      if (_currentStatus != PlayerStatus.speaking) {
        _cancelStuckTalkingWatchdog();
        return;
      }
      final since = _lastLivenessMs;
      if (since == null) return;
      final quietMs = DateTime.now().millisecondsSinceEpoch - since;
      if (quietMs >= config.stuckTalkingCeiling.inMilliseconds) {
        // Force-emit ready to unstick the crossfade. Don't schedule a
        // reconnect — the socket might be healthy, we just lost the
        // stop signal. If a fresh speaking:start arrives later, it'll
        // re-arm the watchdog through the normal transition path.
        _cancelStuckTalkingWatchdog();
        _emitStatus(PlayerStatus.ready, attempt: _reconnectAttempts);
      }
    });
  }

  void _cancelStuckTalkingWatchdog() {
    _stuckTalkingTimer?.cancel();
    _stuckTalkingTimer = null;
    _lastLivenessMs = null;
  }

  /// Reset the stuck-talking liveness marker. Called on any signal
  /// that indicates the reply is genuinely in-flight: playhead
  /// advance ([updatePlaybackTime]), incoming speaking event
  /// ([_handleSpeakingEvent]), or incoming video bytes (session
  /// videoBytes listener). Cheap enough to call on every tick — just
  /// stamps a timestamp.
  void _notifyLiveness() {
    _lastLivenessMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// Start the periodic liveness heartbeat. Compares
  /// [_lastWsMessageTsMs] against [PlayerConfig.wsSilence]; if the
  /// current session hasn't seen a frame in that window, force a
  /// reconnect. Started on first-frame arrival (so
  /// `_lastWsMessageTsMs > 0` is guaranteed), stopped on teardown.
  /// Detects iOS zombie WS sockets (readyState=OPEN but no frames
  /// arriving). Port spec §12.1.2.
  void _startLivenessHeartbeat() {
    _stopLivenessHeartbeat();
    _livenessTimer = Timer.periodic(config.livenessHeartbeat, (_) {
      if (_disposed) return;
      if (_lastWsMessageTsMs == 0) return;
      final ageMs =
          DateTime.now().millisecondsSinceEpoch - _lastWsMessageTsMs;
      if (ageMs > config.wsSilence.inMilliseconds) {
        // Zombie WS — force reconnect. Note this fires while status
        // may still read `ready` because the socket looks fine from
        // the transport layer's view. This is the load-bearing iOS
        // fix (§12.1.2).
        // ignore: discarded_futures
        _ensureConnected(force: true);
      }
    });
  }

  void _stopLivenessHeartbeat() {
    _livenessTimer?.cancel();
    _livenessTimer = null;
  }

  void _handleSpeakingEvent(SpeakingEvent ev) {
    // The awaiting-flag + watchdog cancel happen on event ARRIVAL,
    // not on state-transition fire. The server told us TTS is
    // starting; the render pipeline is not stuck. Doing this before
    // any PTS gating so the flag is correct even when the transition
    // is queued. Port spec §12.1.6.
    if (ev.value == SpeakingState.start) {
      _awaitingSpeakingForChat = false;
      _cancelSpeakWatchdog();
    }
    // Any incoming speaking frame during a speaking-state window is
    // a liveness signal for the stuck-talking watchdog — the pipeline
    // is still narrating even if playhead / bytes are momentarily
    // stalled.
    if (_currentStatus == PlayerStatus.speaking) {
      _notifyLiveness();
    }
    // PTS-gate the state transition (port spec §5.1). Fire
    // immediately if:
    // - no sink integration provides playback time
    //   (`_lastPlaybackTimeSec == null`)
    // - the event has pts == 0 (legacy variant / no gating requested)
    // - playback time has already crossed the PTS
    // Otherwise queue; [updatePlaybackTime] drains as time advances.
    final now = _lastPlaybackTimeSec;
    // Fire immediately when:
    //   - no sink is providing playback time (`now == null`), or
    //   - pts is null (legacy pre-2026-05 no-pts events per
    //     twai-protocol conformance vector `legacy_no_pts_fires_immediately`), or
    //   - pts is 0 (Adapter-1 convention for stream-start events)
    // Otherwise route through the gate; `.tick()` on the current
    // playhead drains any events already past.
    if (now == null || (ev.pts ?? 0) == 0) {
      _fireSpeakingTransition(ev.value);
    } else {
      _speakingGate.enqueueEvent(ev);
      _speakingGate.tick(now);
    }
  }

  void _fireSpeakingTransition(SpeakingState value) {
    switch (value) {
      case SpeakingState.start:
        _emitStatus(PlayerStatus.speaking, attempt: _reconnectAttempts);
        // Arm the mid-reply stuck-talking watchdog. Auto-disarms if
        // the stop transition arrives normally.
        _armStuckTalkingWatchdog();
      case SpeakingState.stop:
        _emitStatus(PlayerStatus.ready, attempt: _reconnectAttempts);
        _cancelStuckTalkingWatchdog();
    }
  }

  /// Drain the held message if one is stashed. Called from the
  /// first-frame callback (i.e. right after the `ready` transition
  /// fires) so the held message reaches the fresh session with a
  /// known-ready pipeline. Uses [_doSend] to bypass the debounce
  /// check — the held message re-sending isn't a duplicate.
  void _drainPendingSend() {
    final held = _pendingSend;
    if (held == null) return;
    _pendingSend = null;
    final session = _session;
    if (session == null) return;
    // ignore: discarded_futures
    _doSend(session, held);
  }

  /// Dispatch a session-terminal event into either a reconnect
  /// attempt or a terminal [PlayerExhausted]. Called from the
  /// session's `done` future.
  void _onSessionDone(ChatSessionEndReason reason) {
    if (_disposed) return;
    // Reference behavior (port spec §2.1): reconnect on any transport
    // close unless the caller explicitly disposed. Server-initiated
    // clean close is treated the same as an abnormal drop from the
    // player's point of view — the app can call `dispose()` if it
    // wants to stop.
    final permanentFailure = reason is ChatSessionFailed && reason.isPermanent;
    if (permanentFailure) {
      final cause = (reason).cause;
      _emitStatus(PlayerStatus.failed,
          attempt: _reconnectAttempts, cause: cause);
      if (!_done.isCompleted) {
        _done.complete(PlayerExhausted(
          'permanent transport failure: ${reason.message}',
        ));
      }
      return;
    }
    // Distinguish flap (<minConnectLifetime after last ready) from
    // stable-then-dropped; both retry, but this classification will
    // become the "disconnect episode" beacon dedup in the next slice
    // (port spec §12.4.4).
    _scheduleReconnect(cause: reason);
  }

  // ══════════════════════════════════════════════════════════════════
  // Internals
  // ══════════════════════════════════════════════════════════════════

  /// The stale guard from port spec §12.1.7. Every async callback
  /// that straddles a teardown must call this at entry and after every
  /// await. If the attempt-id has advanced, the caller is a zombie
  /// from a dead peer — return immediately without touching state.
  bool _stale(int myAttempt) => myAttempt != _connectAttemptId;

  void _emitStatus(
    PlayerStatus status, {
    required int attempt,
    Duration? reconnectDelay,
    Object? cause,
  }) {
    final previous = _currentStatus;
    _currentStatus = status;
    if (_status.isClosed) return;
    _status.add(PlayerStatusEvent(
      status: status,
      attempt: attempt,
      reconnectDelay: reconnectDelay,
      cause: cause,
    ));
    // Drain queued progression events when we return to a
    // non-speaking state — this is the reference's `setLive(false)`
    // hook. Fire from any state → ready OR any state → failed; we
    // don't hold progression indefinitely if the session ends. Port
    // spec §11.
    if (status != PlayerStatus.speaking &&
        previous == PlayerStatus.speaking) {
      _drainPendingProgression();
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('TwaiAvatarPlayerController has been disposed');
    }
  }
}
