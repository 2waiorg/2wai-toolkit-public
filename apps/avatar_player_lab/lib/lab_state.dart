// LabState — single source of truth for what the exerciser is currently
// showing. Follows the "everything on by default" principle: initial
// state has all features on, all defaults at VPC (Verified Production
// Constants). Panels dial values back through the setters.
//
// Two categories of knobs:
//   - Construction knobs (avatar, outfit, transport, env, idle kind,
//     sink override, credentials, autoConnect, pathPrefix, fadeDuration)
//     — changing these bumps rebuildToken and forces a TwaiPlayer
//     re-mount via the shell.
//   - Runtime toggles (immersive layout wrappers, streams-panel filters)
//     — changing these just notifies listeners; shell doesn't re-mount.
//
// currentHandle is set by the shell after each re-mount so the streams
// + runtime-methods panels can grab it without prop-drilling.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart';

import 'known_avatars.dart';

// ---- Event log --------------------------------------------------------------

/// Kinds of events the exerciser aggregates from a live handle. Matches
/// the 7 broadcast streams a TwaiPlayerHandle exposes.
enum LabEventKind { status, replyText, speaking, mood, xp, levelUp, overlay }

class LabEvent {
  final DateTime at;
  final LabEventKind kind;
  final String text;
  const LabEvent({required this.at, required this.kind, required this.text});
}

// ---- Enums for construction knobs ------------------------------------------

enum IdleKind {
  network,          // NetworkVideoIdle (default — uses outfit's idleUrl)
  asset,            // AssetVideoIdle (planned; needs bundled asset)
  posterNetwork,    // NetworkPosterIdle (planned)
  posterAsset,      // AssetPosterIdle (planned)
  solid,            // SolidColorIdle
  none,             // NoIdle (transparent placeholder)
  transparent,      // TransparentVideoIdle (alpha video)
  // TODO(P2.3): playlist — curated idle playlist rotation (player v46)
}

enum SinkKind {
  auto,             // let the SDK pick per platform (default)
  webMse,           // WebMseStreamSink (web)
  videoPlayer,      // VideoPlayerMseStreamSink (iOS/Android/desktop fallback)
  mediaKit,         // MediaKitMseStreamSink (Windows tail-follow)
}

enum EnvKind {
  staging,          // TwaiEnvironment.twaiStaging (default)
  prod,             // TwaiEnvironment.twaiProd
  twaiApi,          // TwaiEnvironment.twaiApi
}

enum CredKind {
  anonymous,        // default for staging
  publicKey,        // pk_ tenant key
  viewToken,        // gen-2wai view tokens
  bearerJwt,        // customer JWTs (Lumara pattern)
  apiKeyDevOnly,    // sk_ in browser — dev only, warning banner
}

/// Mint-proxy reachability — drives the PING PROXY indicator.
enum ProxyStatus {
  unknown,   // never pinged (or URL just changed)
  checking,  // ping in flight
  ok,        // last ping returned 2xx
  fail,      // last ping timed out, 4xx/5xx, or errored
}

// ---- LabState --------------------------------------------------------------

class LabState extends ChangeNotifier {
  // ---- Current subject ----------------------------------------------------
  SeededAvatar _avatar = kBootAvatar;
  SeededAvatar get avatar => _avatar;
  set avatar(SeededAvatar v) {
    if (identical(_avatar, v)) return;
    _avatar = v;
    _outfitSlug = v.avatar.outfits.first.slug;
    _rebuildToken++;
    notifyListeners();
  }

  String _outfitSlug = kBootAvatar.avatar.outfits.first.slug;
  String get outfitSlug => _outfitSlug;
  set outfitSlug(String v) {
    if (_outfitSlug == v) return;
    _outfitSlug = v;
    notifyListeners();  // handled at runtime via handle.switchOutfit, no rebuild
  }

  PlayerOutfit get currentOutfit =>
      _avatar.avatar.outfits.firstWhere((o) => o.slug == _outfitSlug);

  // ---- Adapter override ---------------------------------------------------
  LabTransport? _transportOverride;
  LabTransport? get transportOverride => _transportOverride;
  LabTransport get effectiveTransport =>
      _transportOverride ?? _avatar.transport;
  set transportOverride(LabTransport? v) {
    if (_transportOverride == v) return;
    _transportOverride = v;
    _rebuildToken++;
    notifyListeners();
  }

  // ---- Mint-proxy URL (Adapter 4) -----------------------------------------
  // Enables the twai-api transport for Mila / Dr. Alman. Defaults to
  // the enlighten reference wire — http://localhost:8787 (Node reference
  // proxy at apps/mint_proxy_examples/node/server.js).
  //
  // To activate: run the proxy in a second terminal —
  //   cd apps/mint_proxy_examples/node
  //   $env:TWAI_SK = "sk_test_..."    # your developer-portal key
  //   node server.js
  // — then load the app. Mila renders. The run.ps1 launcher can start
  // this for you (see -Proxy flag).
  //
  // Override via --dart-define=MINT_PROXY_URL=https://your-server.
  // Set to null via CLEAR to disable Adapter 4 entirely.
  static const _kBootProxyUrl = String.fromEnvironment(
    'MINT_PROXY_URL',
    defaultValue: 'http://localhost:8787',
  );
  String? _milaProxyUrl =
      _kBootProxyUrl.isEmpty ? null : _kBootProxyUrl;
  String? get milaProxyUrl => _milaProxyUrl;
  set milaProxyUrl(String? v) {
    final trimmed = (v ?? '').trim();
    final next = trimmed.isEmpty ? null : trimmed;
    if (_milaProxyUrl == next) return;
    _milaProxyUrl = next;
    _proxyStatus = ProxyStatus.unknown;
    _proxyPingMs = null;
    _rebuildToken++;
    notifyListeners();
  }

  // ---- API DIRECT MODE (sk_ key against api.2wai.ai) ----------------------
  // Alternative to mint proxy: consumer sets a sk_test / sk_live key
  // and the shell constructs a twai-api handle directly against
  // api.2wai.ai (Mason's CORS opt-in makes this viable for browser
  // dev). DEV ONLY — sk_ keys in the browser are a firing offense
  // in production. Wins over milaProxyUrl when both are set.
  //
  // Boot-time source: --dart-define=TWAI_SK=sk_... auto-populates on
  // start so you don't paste every launch. Default empty — direct
  // mode is opt-in. The primary Adapter-4 path is the mint proxy
  // below, mirroring apps/enlighten's reference wiring.
  static const _kBootApiKey = String.fromEnvironment('TWAI_SK', defaultValue: '');
  String? _directApiKey = _kBootApiKey.isEmpty ? null : _kBootApiKey;
  String? get directApiKey => _directApiKey;

  /// True when the current key came from a --dart-define at boot (as
  /// opposed to being typed manually). The picker uses this to badge
  /// the key source so testers can see "this was auto-loaded from your
  /// build env, not something you accidentally left in the box."
  bool get directApiKeyFromEnv =>
      _directApiKey != null &&
      _kBootApiKey.isNotEmpty &&
      _directApiKey == _kBootApiKey;
  set directApiKey(String? v) {
    final trimmed = (v ?? '').trim();
    final next = trimmed.isEmpty ? null : trimmed;
    if (_directApiKey == next) return;
    _directApiKey = next;
    _rebuildToken++;
    notifyListeners();
  }

  // ---- Proxy health state (drives the PING PROXY indicator) ---------------
  ProxyStatus _proxyStatus = ProxyStatus.unknown;
  int? _proxyPingMs;
  String? _proxyPingError;
  ProxyStatus get proxyStatus => _proxyStatus;
  int? get proxyPingMs => _proxyPingMs;
  String? get proxyPingError => _proxyPingError;
  void setProxyStatus(ProxyStatus status, {int? ms, String? error}) {
    _proxyStatus = status;
    _proxyPingMs = ms;
    _proxyPingError = error;
    notifyListeners();
  }

  // ---- Construction knobs (rebuild-required) ------------------------------
  EnvKind _env = EnvKind.staging;
  EnvKind get env => _env;
  set env(EnvKind v) {
    if (_env == v) return;
    _env = v;
    _rebuildToken++;
    notifyListeners();
  }

  IdleKind _idleKind = IdleKind.network;
  IdleKind get idleKind => _idleKind;
  set idleKind(IdleKind v) {
    if (_idleKind == v) return;
    _idleKind = v;
    _rebuildToken++;
    notifyListeners();
  }

  SinkKind _sinkKind = SinkKind.auto;
  SinkKind get sinkKind => _sinkKind;
  set sinkKind(SinkKind v) {
    if (_sinkKind == v) return;
    _sinkKind = v;
    _rebuildToken++;
    notifyListeners();
  }

  CredKind _credKind = CredKind.anonymous;
  CredKind get credKind => _credKind;
  set credKind(CredKind v) {
    if (_credKind == v) return;
    _credKind = v;
    _rebuildToken++;
    notifyListeners();
  }

  bool _autoConnect = true;
  bool get autoConnect => _autoConnect;
  set autoConnect(bool v) {
    if (_autoConnect == v) return;
    _autoConnect = v;
    _rebuildToken++;
    notifyListeners();
  }

  String? _pathPrefixOverride;
  String? get pathPrefixOverride => _pathPrefixOverride;
  set pathPrefixOverride(String? v) {
    if (_pathPrefixOverride == v) return;
    _pathPrefixOverride = v;
    _rebuildToken++;
    notifyListeners();
  }

  Duration _fadeDuration = const Duration(milliseconds: 200);
  Duration get fadeDuration => _fadeDuration;
  set fadeDuration(Duration v) {
    if (_fadeDuration == v) return;
    _fadeDuration = v;
    _rebuildToken++;
    notifyListeners();
  }

  // ---- PlayerConfig (all 35 fields as one composed value) -----------------
  // The config-panel builds a fresh PlayerConfig via a copyWith extension
  // and writes it back through this setter. Bumps rebuildToken so the
  // shell's TwaiPlayer picks up the new values on next mount.
  PlayerConfig _config = const PlayerConfig();
  PlayerConfig get config => _config;
  set config(PlayerConfig v) {
    if (identical(_config, v)) return;
    _config = v;
    _rebuildToken++;
    notifyListeners();
  }

  /// Convenience — resets [config] back to VPC defaults.
  void resetConfigToDefaults() {
    if (identical(_config, const PlayerConfig())) return;
    _config = const PlayerConfig();
    _rebuildToken++;
    notifyListeners();
  }

  // ---- Immersive wrapper toggles (rebuild-required) ----------------------
  bool _showImmersiveLayout = true;
  bool get showImmersiveLayout => _showImmersiveLayout;
  set showImmersiveLayout(bool v) {
    if (_showImmersiveLayout == v) return;
    _showImmersiveLayout = v;
    _rebuildToken++;
    notifyListeners();
  }

  bool _showConnectionOverlay = true;
  bool get showConnectionOverlay => _showConnectionOverlay;
  set showConnectionOverlay(bool v) {
    if (_showConnectionOverlay == v) return;
    _showConnectionOverlay = v;
    _rebuildToken++;
    notifyListeners();
  }

  bool _showThemedChat = false;   // off by default in the exerciser — right
                                  // pane already carries the chat via other
                                  // panels; also on stage would collide
  bool get showThemedChat => _showThemedChat;
  set showThemedChat(bool v) {
    if (_showThemedChat == v) return;
    _showThemedChat = v;
    _rebuildToken++;
    notifyListeners();
  }

  bool _showSceneNavigator = false;   // scenes are a multi-scene concept;
                                      // exerciser boots single-scene
  bool get showSceneNavigator => _showSceneNavigator;
  set showSceneNavigator(bool v) {
    if (_showSceneNavigator == v) return;
    _showSceneNavigator = v;
    _rebuildToken++;
    notifyListeners();
  }

  bool _showCinematicPlayer = false;   // full-bleed cinematic mode — hides
                                       // the panels; opt-in
  bool get showCinematicPlayer => _showCinematicPlayer;
  set showCinematicPlayer(bool v) {
    if (_showCinematicPlayer == v) return;
    _showCinematicPlayer = v;
    _rebuildToken++;
    notifyListeners();
  }

  // ---- Phase 3 stage knobs ------------------------------------------------
  StageZoomLevel _zoomLevel = StageZoomLevel.full;
  StageZoomLevel get zoomLevel => _zoomLevel;
  set zoomLevel(StageZoomLevel v) {
    if (_zoomLevel == v) return;
    _zoomLevel = v;
    notifyListeners();  // Transform.scale rebuilds on state change; no full remount
  }

  bool _panLock = false;
  bool get panLock => _panLock;
  set panLock(bool v) {
    if (_panLock == v) return;
    _panLock = v;
    notifyListeners();
  }

  bool _chatAutoScroll = true;
  bool get chatAutoScroll => _chatAutoScroll;
  set chatAutoScroll(bool v) {
    if (_chatAutoScroll == v) return;
    _chatAutoScroll = v;
    notifyListeners();
  }

  // ---- Widget-rebuild token ----------------------------------------------
  int _rebuildToken = 0;
  int get rebuildToken => _rebuildToken;
  void bumpRebuild() {
    _rebuildToken++;
    notifyListeners();
  }

  // ---- Shared handle reference -------------------------------------------
  // The shell sets this after each rebuild so panels (streams,
  // runtime-methods) can talk to the live handle without prop-drilling.
  //
  // On every re-bind we attach a lab-level subscription to all 7 handle
  // streams — the panels themselves used to subscribe, but a broadcast
  // stream doesn't replay past events to late subscribers, so the initial
  // `connecting → ready` status transition would fire before the panel
  // finished building (especially when the streams panel is on a tab that
  // hasn't been visited yet). LabState is always-on, so nothing gets lost.
  TwaiPlayerHandle? _currentHandle;
  TwaiPlayerHandle? get currentHandle => _currentHandle;
  final Map<LabEventKind, StreamSubscription<dynamic>> _eventSubs = {};

  // Transport 0 (LiveKit engine) is captured here in parallel to the
  // handle so lab panels can dispatch send() / disconnect() to it
  // without prop-drilling. On the LiveKit adapter the two are
  // MUTUALLY EXCLUSIVE — Transport 0 does not build a
  // TwaiPlayerHandle.
  LiveKitEngine? _transport0Engine;
  LiveKitEngine? get currentTransport0Engine => _transport0Engine;

  void bindTransport0Engine(LiveKitEngine? engine) {
    if (identical(_transport0Engine, engine)) return;
    _detachTransport0Streams();
    _transport0Engine = engine;
    if (engine != null) _attachTransport0Streams(engine);
    notifyListeners();
  }

  final Map<String, StreamSubscription<dynamic>> _t0Subs = {};
  VoidCallback? _t0StateTick;
  LiveKitEngine? _t0StateSource;

  void _detachTransport0Streams() {
    for (final s in _t0Subs.values) {
      s.cancel();
    }
    _t0Subs.clear();
    final tick = _t0StateTick;
    final source = _t0StateSource;
    if (tick != null && source != null) source.state.removeListener(tick);
    _t0StateTick = null;
    _t0StateSource = null;
  }

  void _attachTransport0Streams(LiveKitEngine engine) {
    // Fan the engine's typed streams into the same eventLog the
    // existing STREAMS panel already tails, so a LiveKit turn shows
    // up in that panel even though it's a completely different wire.
    void tick() =>
        pushEvent(LabEventKind.status, 'state → ${engine.state.value.name}');
    engine.state.addListener(tick);
    _t0StateTick = tick;
    _t0StateSource = engine;
    _t0Subs['warming'] = engine.onWarming.listen(
        (e) => pushEvent(LabEventKind.status, 'warming (room=${e.room})'));
    _t0Subs['ready'] = engine.onReady.listen(
        (e) => pushEvent(LabEventKind.status, 'ready (room=${e.room})'));
    _t0Subs['speaking'] = engine.onSpeaking.listen((e) => pushEvent(
        LabEventKind.speaking, 'speaking: ${e.active ? "start" : "stop"}'));
    _t0Subs['replyText'] = engine.onReplyText.listen((e) => pushEvent(
        LabEventKind.replyText,
        'reply: ${e.text.length > 80 ? "${e.text.substring(0, 80)}…" : e.text}'));
    _t0Subs['replyComplete'] = engine.onReplyComplete.listen((e) => pushEvent(
        LabEventKind.replyText, 'reply DONE (${e.kind.name}): ${e.text.length} chars'));
    _t0Subs['ended'] = engine.onEnded.listen(
        (e) => pushEvent(LabEventKind.status, 'ended: ${e.cause.name}'));
    _t0Subs['notice'] = engine.onNotice.listen(
        (e) => pushEvent(LabEventKind.status, 'notice: ${e.kind.name}'));
  }

  void bindHandle(TwaiPlayerHandle? h) {
    if (identical(_currentHandle, h)) return;
    _detachStreams();
    _currentHandle = h;
    if (h != null) _attachStreams(h);
    notifyListeners();
  }

  void _detachStreams() {
    for (final s in _eventSubs.values) {
      s.cancel();
    }
    _eventSubs.clear();
  }

  void _attachStreams(TwaiPlayerHandle h) {
    // Latch controller.currentStatus so subscribers see the current state
    // even if `connecting` fired before they mounted.
    pushEvent(LabEventKind.status,
        'status = ${h.controller.currentStatus.name} (latched)');
    _eventSubs[LabEventKind.status] = h.status.listen(
        (e) => pushEvent(LabEventKind.status, 'status → ${e.status.name}'));
    _eventSubs[LabEventKind.replyText] = h.replyText.listen((t) => pushEvent(
        LabEventKind.replyText,
        'reply: ${t.length > 80 ? "${t.substring(0, 80)}…" : t}'));
    _eventSubs[LabEventKind.speaking] = h.speakingEvents.listen(
        (e) => pushEvent(LabEventKind.speaking, 'speaking: ${e.toString()}'));
    _eventSubs[LabEventKind.mood] = h.moodEvents.listen(
        (e) => pushEvent(LabEventKind.mood, 'mood → ${e.toString()}'));
    _eventSubs[LabEventKind.xp] = h.xpEvents.listen((e) =>
        pushEvent(LabEventKind.xp, 'xp +${e.amount} (${e.band.name})'));
    _eventSubs[LabEventKind.levelUp] = h.levelUpEvents.listen((e) =>
        pushEvent(LabEventKind.levelUp, 'level → ${e.newLevel}'));
    _eventSubs[LabEventKind.overlay] = h.overlayEvents.listen((e) => pushEvent(
        LabEventKind.overlay, 'overlay: ${e.kind.name} · ${e.url}'));
  }

  // ---- Event log ---------------------------------------------------------
  static const _maxEventLog = 500;
  final List<LabEvent> _eventLog = [];
  List<LabEvent> get eventLog => List.unmodifiable(_eventLog);
  int _eventSeq = 0;
  int get eventSeq => _eventSeq;

  void pushEvent(LabEventKind kind, String text) {
    _eventLog.add(LabEvent(at: DateTime.now(), kind: kind, text: text));
    if (_eventLog.length > _maxEventLog) {
      _eventLog.removeRange(0, _eventLog.length - _maxEventLog);
    }
    _eventSeq++;
    notifyListeners();
  }

  void clearEventLog() {
    if (_eventLog.isEmpty) return;
    _eventLog.clear();
    notifyListeners();
  }

  // ---- Live roster fetched from staging /ext-api-muse/query_avatar --------
  // Populated by the REFRESH LIVE ROSTER button in the ADAPTER panel.
  // Each entry is just the raw avatar_name string returned by the muse
  // stack — the roster is huge (100+ Talk variants) so the panel groups
  // them by base-name prefix for readability.
  List<String>? _liveRoster;
  DateTime? _liveRosterFetchedAt;
  String? _liveRosterError;
  bool _liveRosterFetching = false;
  List<String>? get liveRoster => _liveRoster;
  DateTime? get liveRosterFetchedAt => _liveRosterFetchedAt;
  String? get liveRosterError => _liveRosterError;
  bool get liveRosterFetching => _liveRosterFetching;

  void beginLiveRosterFetch() {
    _liveRosterFetching = true;
    _liveRosterError = null;
    notifyListeners();
  }

  void setLiveRoster(List<String> names) {
    _liveRoster = names;
    _liveRosterFetchedAt = DateTime.now();
    _liveRosterFetching = false;
    _liveRosterError = null;
    notifyListeners();
  }

  void setLiveRosterError(String error) {
    _liveRosterFetching = false;
    _liveRosterError = error;
    notifyListeners();
  }
}
