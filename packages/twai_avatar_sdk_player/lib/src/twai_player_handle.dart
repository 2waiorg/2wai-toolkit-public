import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

import 'api/twai_api_client.dart';
import 'api/twai_api_types.dart';
import 'gesture.dart';
import 'known_avatars.dart';
import 'outfit.dart';
import 'overlay.dart';
import 'player_config.dart';
import 'player_controller.dart';
import 'player_state.dart';
import 'progression.dart';

/// **The 2wai Avatar Player facade.**
///
/// This is the developer-facing API. Construct once with an avatar +
/// (optionally) auth, and every server call the pipeline exposes runs
/// automatically:
///
/// - WebSocket connect + streaming video
/// - Chat send + reply text + mood parsing
/// - `/api/gamification/progress/avatar/{slug}` at connect
/// - `/api/avatars/{slug}/gestures` + `/api/avatars/{slug}/frames`
///   at connect (and re-fetched on level-up)
/// - `/api/gamification/award-message` fires parallel with every
///   `send()` — XP + level-up events land on the handle's streams
///   with the deferred-while-speaking discipline
/// - `/api/avatars/{slug}/state-block` feeds brain context inline
/// - `/api/gamification/record-assistant-message` audit-persists
///   each reply (fire-and-forget)
///
/// Every auto-behavior is an optional param defaulting to on — Mason
/// gets the full pipeline out of the box; devs turn off what they
/// don't want. Overrides:
///
/// - Pass explicit `gestures:` / `frames:` to skip the fetch
/// - Pass `autoAwardXp: false` to skip XP scoring per send
/// - Pass `autoFetchStateBlock: false` for a simpler chat body
/// - Pass `autoRecordReply: false` to skip audit persistence
/// - Pass `autoConnect: false` to defer WS handshake to `connect()`
///
/// # Layered escape hatches
///
/// The facade never hides the layered core. When 5% of use cases need
/// direct access:
///
/// ```dart
/// player.controller     // TwaiAvatarPlayerController — full state machine
/// player.apiClient      // TwaiApiClient — raw /api/* calls
/// ```
///
/// # Phase-1 status (2026-07-20)
///
/// This slice ships the shape + auto-fetch on connect. Send-time
/// fanout (award-message / state-block / record-reply) lands in
/// Phase 2. The [TwaiPlayer] widget lands in Phase 3.
class TwaiPlayerHandle {
  TwaiPlayerHandle({
    required this.avatar,
    PlayerOutfit? outfit,
    // ─── environment / auth ───
    TwaiEnvironment? env,
    this.publishableKey,
    this.authToken,
    TwaiCredentials? credentials,
    // ─── content-layer overrides (null = SDK auto-fetches) ───
    List<PlayerGesture>? gestures,
    List<PlayerFrame>? frames,
    // ─── auto-behavior toggles (all on by default) ───
    this.autoFetchGestures = true,
    this.autoFetchFrames = true,
    this.autoFetchProgress = true,
    this.autoAwardXp = true,
    this.autoFetchStateBlock = true,
    this.autoRecordReply = true,
    // ─── dial-in ───
    PlayerConfig? config,
    this.autoConnect = true,
    this.pathPrefix = '/ext-api-muse',
    TwaiApiClient? apiClient,
    ChatSession Function()? sessionFactory,
    // ─── Adapter 4 (twai-api /v1/*) opt-in ───
    // When [twaiApiRestClient] is non-null, [_sessionFactory] returns a
    // [TwaiApiChatSession] pointed at that REST client instead of the
    // default Adapter 1 [MseStreamChatSession]. Pass a client from
    // [TwaiApiRestClient](baseUrl: yourMintProxy, credentials:
    // AnonymousCredentials()) for the prod split-plane path, or from
    // [TwaiClient](secretKey: sk_...).apiSession()'s underlying rest
    // client for dev direct.
    //
    // The customer picks the adapter; the widget just plumbs it through.
    // In Adapter 4 mode, callers must ALSO disable the penthouse-side
    // auto-behaviors (autoFetchGestures / -Frames / -Progress /
    // autoAwardXp / autoFetchStateBlock / autoRecordReply) because
    // twai-api doesn't expose /api/gamification/* or /api/avatars/*.
    // See [TwaiPlayerHandle.forApiSession] for a factory that bakes
    // those defaults in.
    this.twaiApiRestClient,
    TwaiBrainCallback? brain,
    TwaiStreamingBrainCallback? streamingBrain,
  })  : assert(brain == null || streamingBrain == null,
            'Pass either brain OR streamingBrain, not both.'),
        env = env ?? TwaiEnvironment.twaiProd,
        outfit = outfit ?? avatar.outfits.first,
        config = config ?? const PlayerConfig(),
        credentials = credentials ??
            (authToken != null && authToken.isNotEmpty
                ? BearerJwtCredentials(authToken)
                : const AnonymousCredentials()),
        _explicitGestures = gestures,
        _explicitFrames = frames,
        _sessionFactoryOverride = sessionFactory,
        _brain = brain,
        _streamingBrain = streamingBrain {
    _twai = TwaiClient(env: this.env, publishableKey: publishableKey);
    _apiClient = apiClient ??
        TwaiApiClient(
          baseUrl: this.env.baseUrl,
          credentials: this.credentials,
        );
    _controller = TwaiAvatarPlayerController(
      sessionFactory: _sessionFactory,
      config: this.config,
    );
    // Legacy `/ext-api` prefix was retired on penthouse staging
    // 2026-07-23 (wav2lip Phase 2 sunset — see
    // `reference_penthouse_staging_state.md` memory). Anyone still
    // routing through it will 404 on staging + prod. The SDK's default
    // is `/ext-api-muse`; this guard only fires when a caller has
    // explicitly overridden. Warning-only (not throwing) so an app
    // proxying to a self-hosted deployment that still serves `/ext-api`
    // isn't forced to fork the SDK.
    if (pathPrefix == '/ext-api') {
      developer.log(
        'TwaiPlayerHandle: pathPrefix "/ext-api" was retired on '
        'penthouse staging 2026-07-23 (wav2lip Phase 2 sunset). Use '
        '"/ext-api-muse" (the SDK default) unless you are hitting a '
        'self-hosted deployment that still serves the legacy prefix.',
        name: 'twai_avatar_sdk_player',
        level: 900, // between INFO (800) and SEVERE (1000)
      );
    }
    if (autoConnect) {
      // ignore: discarded_futures
      connect();
    }
  }

  /// Resolve an avatar by slug and construct a [TwaiPlayerHandle].
  /// The one-line-API path for "give me an avatar named X":
  ///
  /// ```dart
  /// final handle = await TwaiPlayerHandle.fromSlug(
  ///   'krystal-harper',
  ///   env: TwaiEnvironment.twaiStaging,
  /// );
  /// ```
  ///
  /// # Resolve order
  ///
  /// 1. **Wire fetch** — hits `/api/gen/catalog/owner/name` (when
  ///    slug contains `/`) or `/api/avatars/{slug}` on the pipeline.
  ///    Wins when the response includes per-outfit `pipelineName` +
  ///    `idle_url` (gen-2wai does today; the pipeline's endpoint
  ///    doesn't yet — that's a backend gap).
  /// 2. **Bundled fallback** — [KnownAvatars] holds a hand-curated
  ///    playable catalog for muse-baked avatars whose wire response
  ///    is thin. Bridge until the backend catches up.
  /// 3. **Throw** — when both are empty, throws [StateError] with a
  ///    message pointing at the two possible fixes (add the avatar
  ///    to [KnownAvatars], or land the backend fields).
  ///
  /// All other params are forwarded to the regular constructor. See
  /// class doc for the auto-behavior toggles.
  static Future<TwaiPlayerHandle> fromSlug(
    String slug, {
    TwaiEnvironment? env,
    String? publishableKey,
    String? authToken,
    TwaiCredentials? credentials,
    PlayerOutfit? outfit,
    List<PlayerGesture>? gestures,
    List<PlayerFrame>? frames,
    bool autoFetchGestures = true,
    bool autoFetchFrames = true,
    bool autoFetchProgress = true,
    bool autoAwardXp = true,
    bool autoFetchStateBlock = true,
    bool autoRecordReply = true,
    PlayerConfig? config,
    bool autoConnect = true,
    String pathPrefix = '/ext-api-muse',
    TwaiApiClient? apiClient,
    ChatSession Function()? sessionFactory,
  }) async {
    final resolvedEnv = env ?? TwaiEnvironment.twaiProd;
    final client = apiClient ??
        TwaiApiClient(
          baseUrl: resolvedEnv.baseUrl,
          authToken: authToken,
          credentials: credentials,
        );

    // Try the wire first — succeeds when the backend response is
    // complete (gen-2wai today; pipeline eventually).
    PlayerAvatar? avatar;
    final wire = await client.fetchAvatarCatalog(slug);
    avatar = wire?.toPlayerAvatar();

    // Bridge fallback — KnownAvatars for muse-baked avatars whose
    // wire response is thin (no pipelineName per outfit).
    avatar ??= KnownAvatars.lookup(slug);

    if (avatar == null) {
      // Close the ephemeral client if we owned it.
      if (apiClient == null) client.close();
      throw StateError(
        'TwaiPlayerHandle.fromSlug: no catalog entry for "$slug". '
        'Either add the avatar to KnownAvatars (bridge), or land '
        'per-outfit pipelineName + idle_url in the backend\'s '
        '/api/avatars/{slug} response.',
      );
    }

    return TwaiPlayerHandle(
      avatar: avatar,
      outfit: outfit,
      env: resolvedEnv,
      publishableKey: publishableKey,
      authToken: authToken,
      credentials: credentials,
      gestures: gestures,
      frames: frames,
      autoFetchGestures: autoFetchGestures,
      autoFetchFrames: autoFetchFrames,
      autoFetchProgress: autoFetchProgress,
      autoAwardXp: autoAwardXp,
      autoFetchStateBlock: autoFetchStateBlock,
      autoRecordReply: autoRecordReply,
      config: config,
      autoConnect: autoConnect,
      pathPrefix: pathPrefix,
      // Pass the client through so we don't build a second one.
      apiClient: client,
      sessionFactory: sessionFactory,
    );
  }

  /// Factory for the twai-api (`/v1/*`) Adapter-4 path. Constructs a
  /// [TwaiPlayerHandle] with all penthouse-side auto-behaviors
  /// pre-disabled (twai-api doesn't expose `/api/gamification/*` or
  /// `/api/avatars/*`, so calling them would just log 404s), and the
  /// [_sessionFactory] wired to return a [TwaiApiChatSession] each
  /// reconnect.
  ///
  /// [restClient] is either a dev-direct `TwaiApiRestClient(baseUrl:
  /// env.baseUrl, credentials: TwaiApiKeyCredentials.devOnly(sk_...))`
  /// or — for prod split-plane — a `TwaiApiRestClient(baseUrl:
  /// yourMintProxyUrl, credentials: AnonymousCredentials())` where
  /// the customer's mint proxy holds the sk_ server-side.
  ///
  /// [brain] is the optional user-text → reply callback (null → echo).
  ///
  /// [streamingBrain] is the optional per-sentence-streaming variant.
  /// When set, the brain implementation drives /speak itself per sentence
  /// as it streams from an LLM — dramatically lower time-to-first-word
  /// than [brain]'s single-shot pattern. Mutually exclusive with [brain];
  /// see [TwaiStreamingBrainCallback] for the contract.
  factory TwaiPlayerHandle.forApiSession({
    required PlayerAvatar avatar,
    required TwaiApiRestClient restClient,
    TwaiBrainCallback? brain,
    TwaiStreamingBrainCallback? streamingBrain,
    PlayerOutfit? outfit,
    PlayerConfig? config,
    bool autoConnect = true,
    TwaiEnvironment? env,
  }) {
    return TwaiPlayerHandle(
      avatar: avatar,
      outfit: outfit,
      env: env,
      config: config,
      autoConnect: autoConnect,
      twaiApiRestClient: restClient,
      brain: brain,
      streamingBrain: streamingBrain,
      // Penthouse-only auto-behaviors — twai-api doesn't serve any
      // of these endpoints, so hitting them would log 404s per turn.
      autoFetchGestures: false,
      autoFetchFrames: false,
      autoFetchProgress: false,
      autoAwardXp: false,
      autoFetchStateBlock: false,
      autoRecordReply: false,
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // Constructor params (kept as fields for introspection)
  // ══════════════════════════════════════════════════════════════════

  final PlayerAvatar avatar;
  final PlayerOutfit outfit;
  final TwaiEnvironment env;
  final String? publishableKey;
  final String? authToken;

  /// Resolved credentials the handle attaches to every `/api/*`
  /// call. Non-null; defaults to [AnonymousCredentials]. Anything
  /// beyond a plain JWT (view-token rotation, publishable key) goes
  /// here rather than the flat [authToken] field.
  final TwaiCredentials credentials;
  final PlayerConfig config;
  final bool autoConnect;

  /// Pipeline path prefix the WS session targets. Default
  /// `'/ext-api-muse'` (production muse stack). Override to point at
  /// a proxy that fronts the pipeline (e.g. 2wai-edu's
  /// `edu-avatar-proxy` uses an empty root — set `pathPrefix: ''`),
  /// or to route through an unusual path (`'/ext-api-onnx'` for the
  /// dev ONNX stack).
  ///
  /// This is Group E's WS-proxy support (2026-07-20 requirements
  /// survey) — a customer wrapping the pipeline behind their own
  /// auth/routing proxy just points here + optionally passes
  /// `env: TwaiEnvironment.register(...)` to override the origin.
  final String pathPrefix;

  final bool autoFetchGestures;
  final bool autoFetchFrames;
  final bool autoFetchProgress;
  final bool autoAwardXp;
  final bool autoFetchStateBlock;
  final bool autoRecordReply;

  /// Non-null → Adapter 4 (twai-api /v1/*). The [_sessionFactory]
  /// returns a [TwaiApiChatSession] pointed at this REST client on
  /// every connect + reconnect. See [TwaiPlayerHandle.forApiSession]
  /// for the ergonomic factory that flips off the penthouse-side
  /// auto-behaviors at the same time.
  final TwaiApiRestClient? twaiApiRestClient;

  /// Adapter 4 brain callback (only consulted when [twaiApiRestClient]
  /// is non-null). See [TwaiApiChatSession] docs.
  final TwaiBrainCallback? _brain;

  /// Adapter 4 streaming brain callback (only consulted when
  /// [twaiApiRestClient] is non-null). Mutually exclusive with [_brain].
  /// Enables per-sentence /speak driven by the brain implementation for
  /// low time-to-first-word — see [TwaiStreamingBrainCallback] docs.
  final TwaiStreamingBrainCallback? _streamingBrain;

  final List<PlayerGesture>? _explicitGestures;
  final List<PlayerFrame>? _explicitFrames;

  /// Optional session-factory override — for tests + advanced apps
  /// that want to substitute a custom [ChatSession] (fake, adapter,
  /// tunneled). When null, the facade builds an
  /// [MseStreamChatSession] targeting the muse stack.
  final ChatSession Function()? _sessionFactoryOverride;

  // ══════════════════════════════════════════════════════════════════
  // Internal composition
  // ══════════════════════════════════════════════════════════════════

  late final TwaiClient _twai;
  late final TwaiApiClient _apiClient;
  late final TwaiAvatarPlayerController _controller;

  ResolvedOutfit? _resolvedOutfit;

  List<PlayerGesture> _gestures = const [];
  List<PlayerFrame> _frames = const [];
  PetProgress? _progress;

  StreamSubscription<String>? _replySub;

  /// Session-scoped counter for level-ups. Feeds the `n/total`
  /// display in the reference's level-up modal.
  int _sessionLevelUpCount = 0;

  bool _connectStarted = false;
  bool _disposed = false;

  // ══════════════════════════════════════════════════════════════════
  // Escape hatches to the layered core
  // ══════════════════════════════════════════════════════════════════

  /// The layered state-machine controller — for the 5% who need
  /// direct sink integration, `notifyStall`, `computeClampTargetSec`,
  /// etc.
  TwaiAvatarPlayerController get controller => _controller;

  /// The raw `/api/*` HTTP client — for endpoints the facade doesn't
  /// wrap yet, or one-off calls the app wants to make with the same
  /// auth headers.
  TwaiApiClient get apiClient => _apiClient;

  // ══════════════════════════════════════════════════════════════════
  // Snapshots (populated by auto-fetch)
  // ══════════════════════════════════════════════════════════════════

  /// The outfit variant picked for this session — populated after
  /// `connect()` completes the initial resolve. Null before connect.
  ResolvedOutfit? get currentOutfit => _resolvedOutfit;

  /// Emote catalog. When [autoFetchGestures] is true, populated
  /// from `/api/avatars/{slug}/gestures` at connect. Otherwise
  /// populated from the constructor's `gestures:` param (or empty).
  List<PlayerGesture> get gestures => List.unmodifiable(_gestures);

  /// Frame catalog. Same rules as [gestures].
  List<PlayerFrame> get frames => List.unmodifiable(_frames);

  /// Current-level snapshot (initial fetch + running total updated
  /// by award-message responses in Phase 2). Null until Phase 2
  /// wires the update path.
  int? get currentLevel => _progress?.currentLevel;

  int? get currentXpInLevel => _progress?.currentXpInLevel;
  int? get xpRequiredToNext => _progress?.xpRequiredToNext;
  bool get isAtCap => _progress?.atCap ?? false;

  // ══════════════════════════════════════════════════════════════════
  // Reactive streams — pass-through from the layered controller
  // ══════════════════════════════════════════════════════════════════

  Stream<PlayerStatusEvent> get status => _controller.status;
  Stream<String> get replyText => _controller.replyText;
  Stream<Uint8List> get videoBytes => _controller.videoBytes;
  Stream<SpeakingEvent> get speakingEvents => _controller.speakingEvents;
  Stream<MoodEvent> get moodEvents => _controller.moodEvents;
  Stream<XpEvent> get xpEvents => _controller.xpEvents;
  Stream<LevelUpEvent> get levelUpEvents => _controller.levelUpEvents;
  Stream<OverlayEvent> get overlayEvents => _controller.overlayEvents;

  PlayerStatus get currentStatus => _controller.currentStatus;
  MoodEvent? get currentMood => _controller.currentMood;
  bool get isOverlayPlaying => _controller.isOverlayPlaying;

  Future<PlayerEndReason> get done => _controller.done;

  // ══════════════════════════════════════════════════════════════════
  // Actions
  // ══════════════════════════════════════════════════════════════════

  /// Kick off the pipeline connection + auto-fetch fanout. Idempotent
  /// — a second call while a connect is in flight is a no-op. Called
  /// automatically from the constructor unless `autoConnect: false`
  /// was passed.
  Future<void> connect() async {
    _assertNotDisposed();
    if (_connectStarted) return;
    _connectStarted = true;

    // Subscribe reply text — feeds the auto-record-assistant-message
    // fire-and-forget audit POST (reference `record-assistant-message`
    // at controller.ts:4168-4176).
    if (autoRecordReply) {
      _replySub = _controller.replyText.listen(_onReply);
    }

    // Resolve outfit rotation (random pick from pipelineNames /
    // idleUrls per port spec §12.1.3). Reconnects re-resolve inside
    // the controller.
    final resolved = resolveOutfit(outfit);
    _resolvedOutfit = resolved;

    // Kick the pipeline connect + parallel /api/* fanout. All three
    // AUX fetches are independent + fail-open; we don't await them
    // as a group — the controller connect drives the main path.
    // ignore: discarded_futures
    _fetchInitialContent();
    await _controller.connect(resolved.toAvatar(voiceId: effectiveVoiceId));
  }

  /// Send a user message with the full reference-style parallel
  /// fanout — mirrors `controller.ts:4022-4034`.
  ///
  /// Three server calls fire in parallel:
  /// 1. `GET /api/avatars/{slug}/state-block` — awaited before the
  ///    chat gateway so it can be passed inline as `avatarStateBlock`.
  ///    Feeds the brain the current mood / pose / outfit context.
  /// 2. `POST /ext-api-muse/human` — the chat send itself, dispatched
  ///    through the controller's held-send / duplicate-debounce /
  ///    watchdog discipline.
  /// 3. `POST /api/gamification/award-message` — XP + level scoring.
  ///    Server-side, doesn't touch the brain; runs in parallel with
  ///    the reply so a slow XP path never delays render.
  ///
  /// After the reply text arrives on [replyText], a fire-and-forget
  /// `POST /api/gamification/record-assistant-message` fires for
  /// audit persistence (see [_onReply]).
  ///
  /// All three parallel calls fail open — a network / HTTP error on
  /// state-block, award, or record doesn't block the chat.
  ///
  /// **Divergence from reference:** the controller's held-send
  /// discipline (§12.1.8) may stash [text] rather than sending it
  /// immediately. When a held message drains, the drain path
  /// bypasses this facade — no re-fetch of state-block or
  /// award-message on the drained delivery. Held sends drain
  /// without the fanout. Rare in practice (held-send only fires
  /// during a reconnect gap or greeting lock); accepted MVP
  /// tradeoff. A future slice can add a drain callback on the
  /// controller to close this gap.
  Future<void> send(String text) async {
    _assertNotDisposed();

    // Fire the state-block + award-message calls up front, so both
    // begin before we await anything.
    final stateBlockFuture = autoFetchStateBlock
        ? _apiClient.fetchStateBlock(avatar.slug)
        : Future<String?>.value(null);
    final awardFuture = autoAwardXp
        ? _apiClient.awardMessage(
            avatarSlug: avatar.slug,
            message: text,
          )
        : Future<AwardMessageResponse?>.value(null);

    // Wait for the state-block so it can be passed inline (parallel
    // with the running-in-background award call).
    final stateBlock = await stateBlockFuture;

    // Fire the chat send. Controller enforces held-send / debounce /
    // watchdogs; may return without actually sending if the message
    // is stashed (see divergence note above).
    await _controller.send(
      text,
      gamificationLevel: currentLevel,
      avatarStateBlock: stateBlock,
    );

    // Handle award response when it arrives (fire-and-forget for
    // send's caller — XP + level-up events land on the streams via
    // the controller's defer-while-speaking discipline).
    // ignore: discarded_futures
    awardFuture.then(_handleAwardResponse);
  }

  /// Swap to a different outfit mid-session. Resolves the new
  /// outfit's rotation, updates `currentOutfit`, and forces a fresh
  /// session with the new pipeline avatar name.
  Future<void> switchOutfit(PlayerOutfit next) async {
    _assertNotDisposed();
    final resolved = resolveOutfit(next);
    _resolvedOutfit = resolved;
    await _controller.changeAvatar(
      resolved.toAvatar(voiceId: effectiveVoiceId),
    );
  }

  /// The voice ID currently in use — [switchVoice] override wins over
  /// the constructor-time [PlayerAvatar.voiceId]. Consumers can read
  /// this to render a "current voice" badge.
  String get effectiveVoiceId => _voiceOverride ?? avatar.voiceId;

  /// Runtime voice override — set via [switchVoice]. Null means the
  /// avatar's default voice is in use.
  String? _voiceOverride;

  /// Swap to a different voice mid-session without changing outfit.
  ///
  /// Voice is bound to the transport `Avatar` object at session
  /// construction, so both adapters need to reconstruct the session
  /// with a fresh voice ID:
  ///   - Adapter 1 (penthouse): [TwaiAvatarPlayerController.changeAvatar]
  ///     with the current resolved outfit + new voice ID. Fast; keeps
  ///     the current pipeline name (no outfit rotation re-roll).
  ///   - Adapter 4 (twai-api): same shape — [changeAvatar] tears down
  ///     the WS + POSTs a fresh `/v1/sessions` with the new voice.
  ///
  /// Fires before the first [connect] is a no-op — the override is
  /// stored, and the eventual connect uses it via [effectiveVoiceId].
  Future<void> switchVoice(String voiceId) async {
    _assertNotDisposed();
    _voiceOverride = voiceId;
    final resolved = _resolvedOutfit;
    if (resolved == null) return; // no live session yet
    await _controller.changeAvatar(
      resolved.toAvatar(voiceId: voiceId),
    );
  }

  /// Trigger a gesture overlay. Emits an [OverlayEvent] on
  /// [overlayEvents] with the reference's muting default (gestures
  /// muted, frames not). App renders the overlay `<video>` and calls
  /// [notifyOverlayEnded] when it finishes.
  void playGesture(PlayerGesture gesture) =>
      _controller.playGesture(gesture);

  /// Trigger a frame overlay.
  void playFrame(PlayerFrame frame) => _controller.playFrame(frame);

  /// Notify the SDK the current overlay finished playing.
  void notifyOverlayEnded() => _controller.notifyOverlayEnded();

  /// Manual reconnect after the auto-recovery has been exhausted.
  /// Must be called from a user gesture callback (iOS
  /// `ManagedMediaSource` requires it — see port spec §12.1.1).
  Future<void> manualReconnect() => _controller.manualReconnect();

  /// Manual XP award — for apps that compute progression client-side
  /// or fire from a non-standard server source. When [autoAwardXp]
  /// is on, the SDK also auto-fires this from the pipeline's
  /// award-message response (Phase 2).
  void awardXp(int amount, {required XpBand band, String? reason}) =>
      _controller.awardXp(amount, band: band, reason: reason);

  /// Manual level-up notification — same override rules as [awardXp].
  void notifyLevelUp(
    int newLevel, {
    int? previousLevel,
    String? rewardTitle,
    String? rewardThumbnailUrl,
    int? sessionLevelUpIndex,
    int? sessionLevelUpTotal,
  }) =>
      _controller.notifyLevelUp(
        newLevel,
        previousLevel: previousLevel,
        rewardTitle: rewardTitle,
        rewardThumbnailUrl: rewardThumbnailUrl,
        sessionLevelUpIndex: sessionLevelUpIndex,
        sessionLevelUpTotal: sessionLevelUpTotal,
      );

  /// Dispose the handle + its controller + API client.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _replySub?.cancel();
    _replySub = null;
    await _controller.dispose();
    _apiClient.close();
  }

  // ══════════════════════════════════════════════════════════════════
  // Send-time fanout handlers (Phase 2)
  // ══════════════════════════════════════════════════════════════════

  /// Fold an [AwardMessageResponse] into local progress state + fire
  /// [XpEvent] and (if [AwardMessageResponse.leveledUp]) [LevelUpEvent]
  /// through the controller's defer-while-speaking discipline.
  ///
  /// On level-up, also re-fetches gestures + frames — the backend
  /// blanks locked URLs, so a newly-unlocked reward's `video_url` /
  /// `main_clip_url` doesn't populate until we refetch. Reference:
  /// `controller.ts:5129-5138`.
  void _handleAwardResponse(AwardMessageResponse? r) {
    if (r == null || _disposed) return;

    // Update the running progress snapshot in place. Matches the
    // reference's `lastPetProgress` update pattern at controller.ts:5119-5126.
    final prior = _progress;
    if (prior != null) {
      _progress = PetProgress(
        currentLevel: r.currentLevel,
        currentXpInLevel: r.currentXpInLevel,
        xpRequiredToNext: r.xpRequiredToNext,
        lifetimeXp: prior.lifetimeXp + r.xpAwarded,
        messagesSent: prior.messagesSent + 1,
        atCap: r.atCap,
        streakCount: r.streakCount ?? prior.streakCount,
        streakLongest: prior.streakLongest,
      );
    }

    // Fire XP through the controller — deferred-while-speaking
    // discipline applies (port spec §11).
    _controller.awardXp(r.xpAwarded, band: r.band);

    if (r.leveledUp) {
      _sessionLevelUpCount += 1;
      // Pull the first reward's metadata for the modal display; the
      // reference shows the primary reward with the rest listed below.
      final reward =
          r.rewardsUnlocked.isNotEmpty ? r.rewardsUnlocked.first : null;
      _controller.notifyLevelUp(
        r.currentLevel,
        previousLevel: r.levelBefore,
        rewardTitle: reward?.name,
        rewardThumbnailUrl: reward?.thumbnailUrl,
        sessionLevelUpIndex: _sessionLevelUpCount,
      );
      // Refetch catalogs — locked URLs get populated on unlock.
      // ignore: discarded_futures
      _refetchCatalogs();
    }
  }

  /// Fire-and-forget audit persistence after each assistant reply.
  /// Subscribed from [connect] when [autoRecordReply] is on.
  void _onReply(String reply) {
    if (_disposed || reply.isEmpty) return;
    // ignore: discarded_futures
    _apiClient.recordAssistantMessage(
      avatarSlug: avatar.slug,
      reply: reply,
    );
  }

  /// Re-fetch gesture + frame catalogs after a level-up so newly-
  /// unlocked rewards' URLs populate. Called from
  /// [_handleAwardResponse].
  Future<void> _refetchCatalogs() async {
    if (_disposed) return;
    final futures = <Future<void>>[];
    if (autoFetchGestures) {
      futures.add(_apiClient.fetchGestures(avatar.slug).then((v) {
        if (!_disposed) _gestures = v;
      }));
    }
    if (autoFetchFrames) {
      futures.add(_apiClient.fetchFrames(avatar.slug).then((v) {
        if (!_disposed) _frames = v;
      }));
    }
    await Future.wait(futures);
  }

  // ══════════════════════════════════════════════════════════════════
  // Internals
  // ══════════════════════════════════════════════════════════════════

  /// Session factory the controller calls on every connect +
  /// reconnect. Uses the constructor's `sessionFactory:` override
  /// when provided (for tests); otherwise builds an
  /// [MseStreamChatSession] targeting the muse stack, using the
  /// resolved outfit's pipeline name (which re-resolves in
  /// [switchOutfit]).
  ChatSession _sessionFactory() {
    final override = _sessionFactoryOverride;
    if (override != null) return override();
    // Adapter-4 opt-in: customer passed a TwaiApiRestClient. Build a
    // twai-api /v1/* session against it. Brain is optional — null
    // means echo (avatar says the literal user text; useful for demos
    // and TTS-style integrations).
    final apiRest = twaiApiRestClient;
    if (apiRest != null) {
      return TwaiApiChatSession(
        restClient: apiRest,
        brain: _brain,
        streamingBrain: _streamingBrain,
      );
    }
    // Default: Adapter 1 (penthouse MSE-over-WS).
    // Per-avatar delivery override wins over the handle's pathPrefix
    // constructor argument — a mixed-catalog consumer sets
    // `deliveryOverride` on each PlayerAvatar and the SDK routes
    // automatically without recomputing pathPrefix per session.
    final resolvedPath =
        avatar.deliveryOverride?.pathPrefix ?? pathPrefix;
    return _twai.mseStreamSession(
      ttsSelection: avatar.ttsSelection,
      pathPrefix: resolvedPath,
    );
  }

  /// Fan out the load-at-mount `/api/*` calls in parallel. All three
  /// fail open — the reference tolerates any of them missing.
  Future<void> _fetchInitialContent() async {
    final futures = <Future<void>>[];

    if (_explicitGestures != null) {
      _gestures = List<PlayerGesture>.from(_explicitGestures);
    } else if (autoFetchGestures) {
      futures.add(_apiClient.fetchGestures(avatar.slug).then((v) {
        if (!_disposed) _gestures = v;
      }));
    }

    if (_explicitFrames != null) {
      _frames = List<PlayerFrame>.from(_explicitFrames);
    } else if (autoFetchFrames) {
      futures.add(_apiClient.fetchFrames(avatar.slug).then((v) {
        if (!_disposed) _frames = v;
      }));
    }

    if (autoFetchProgress) {
      futures.add(_apiClient.fetchProgress(avatar.slug).then((v) {
        if (!_disposed) _progress = v;
      }));
    }

    // Fire-and-forget: fetch failures are silent, don't block connect.
    await Future.wait(futures);
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('TwaiPlayerHandle has been disposed');
    }
  }
}
