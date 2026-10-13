import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';
import 'package:twai_avatar_sdk_video_player/twai_avatar_sdk_video_player.dart';
import 'package:twai_avatar_sdk_web_mse/twai_avatar_sdk_web_mse.dart';

import 'avatar_idle_source.dart';
import 'avatar_player_stage.dart';
import 'video_sink.dart';

/// A [Sink] typedef used by [TwaiPlayer.sinkFactory] callers who want
/// to override the default platform sink pick (e.g. to swap in the
/// libmpv-backed sink on Windows). The factory receives the current
/// [TwaiAvatarPlayerController] so the sink can subscribe to its
/// broadcast streams.
typedef TwaiSinkFactory = VideoSink Function(
  TwaiAvatarPlayerController controller,
);

/// **The 2wai Avatar Player widget.**
///
/// One widget, one call. Handles everything the pipeline exposes —
/// connect, chat, mood, gestures / frames, XP, level-ups, reconnect
/// discipline, layered idle/live composition. Constructing this
/// widget with just an [avatar] is the "just call the player" path
/// Jim's asked for:
///
/// ```dart
/// TwaiPlayer(avatar: krystal)   // fastest path, everything auto-managed
/// ```
///
/// # Optional external controller — for imperative send + observe
///
/// When you need to call `send()` from an `onPressed` outside the
/// widget tree, construct a [TwaiPlayerHandle] separately and pass
/// it as [controller]. Same widget class works for both use cases —
/// the Flutter idiom (matches `TextField` + `TextEditingController`,
/// `Scrollable` + `ScrollController`, etc):
///
/// ```dart
/// final player = TwaiPlayerHandle(avatar: krystal);
///
/// TwaiPlayer(controller: player, avatar: krystal),
///
/// IconButton(
///   onPressed: () => player.send(text),
///   icon: Icon(Icons.send),
/// ),
/// ```
///
/// When [controller] is null the widget owns the handle's lifecycle
/// (creates on init, disposes on unmount when [autoDispose] is true).
/// When [controller] is non-null the app owns lifecycle; the widget
/// never calls `dispose()` on it.
///
/// # Platform sink dispatch
///
/// The widget picks a sink automatically based on platform:
/// - **Flutter web** → [WebMseStreamSink] (real MSE tail-follower
///   with the full clamp/jitter/PTS-gate discipline)
/// - **Everything else** → [VideoPlayerMseStreamSink]
///   (accumulate-then-play; cross-platform, ~2s tail-window delay)
///
/// Advanced apps override via [sinkFactory] — pass a function that
/// returns your preferred sink (e.g. `MediaKitMseStreamSink()` on
/// Windows once the libmpv tail-follow lands in Phase B2).
///
/// # Overriding auto-behaviors
///
/// Every auto-fetch / auto-fire behavior on [TwaiPlayerHandle] is
/// exposed here as a param defaulting to on. Turn off the ones your
/// app doesn't want. See [TwaiPlayerHandle] for the full menu.
class TwaiPlayer extends StatefulWidget {
  const TwaiPlayer({
    super.key,
    required this.avatar,
    this.controller,
    this.outfit,
    // ─── environment / auth ───
    this.env,
    this.publishableKey,
    this.authToken,
    // ─── content-layer overrides (null → SDK auto-fetches) ───
    this.gestures,
    this.frames,
    // ─── auto-behavior toggles ───
    this.autoFetchGestures = true,
    this.autoFetchFrames = true,
    this.autoFetchProgress = true,
    this.autoAwardXp = true,
    this.autoFetchStateBlock = true,
    this.autoRecordReply = true,
    this.config,
    this.autoConnect = true,
    this.autoDispose = true,
    this.pathPrefix = '/ext-api-muse',
    // ─── widget-level overrides ───
    this.idleSource,
    this.sinkFactory,
    this.fadeDuration = const Duration(milliseconds: 200),
    // ─── Adapter 4 (twai-api /v1/*) opt-in ───
    // When [twaiApiRestClient] is non-null the widget builds a
    // [TwaiPlayerHandle.forApiSession] under the hood instead of the
    // default Adapter 1 handle. Penthouse-side auto-behaviors
    // (autoFetchGestures, -Frames, -Progress, autoAwardXp,
    // -StateBlock, autoRecordReply) are all forced off in that mode
    // because twai-api doesn't serve those endpoints. Passing an
    // external [controller] wins over both paths — the caller owns
    // the handle in that case.
    this.twaiApiRestClient,
    this.brain,
    this.streamingBrain,
  });

  /// The avatar to render. Carries the outfit list; the widget uses
  /// [outfit] (or `avatar.outfits.first` if that's null) as the
  /// initial pick.
  final PlayerAvatar avatar;

  /// Optional external handle. When non-null, the widget uses it +
  /// does NOT dispose it. When null, the widget constructs its own
  /// internal handle and disposes on unmount (if [autoDispose] is
  /// true).
  final TwaiPlayerHandle? controller;

  final PlayerOutfit? outfit;
  final TwaiEnvironment? env;
  final String? publishableKey;
  final String? authToken;
  final List<PlayerGesture>? gestures;
  final List<PlayerFrame>? frames;
  final bool autoFetchGestures;
  final bool autoFetchFrames;
  final bool autoFetchProgress;
  final bool autoAwardXp;
  final bool autoFetchStateBlock;
  final bool autoRecordReply;
  final PlayerConfig? config;
  final bool autoConnect;
  final bool autoDispose;

  /// Pipeline path prefix forwarded to the internal
  /// [TwaiPlayerHandle]. Default `'/ext-api-muse'` (production muse
  /// stack). Override to route through a proxy or an alternate stack;
  /// see [TwaiPlayerHandle.pathPrefix] for the full story.
  ///
  /// Ignored when [controller] is non-null (external handles own
  /// their own pathPrefix — set it on the handle at construction).
  final String pathPrefix;

  /// Optional idle content override. When null, the widget renders
  /// the resolved outfit's `idleUrl` via [NetworkVideoIdle].
  final AvatarIdleSource? idleSource;

  /// Optional sink factory override. When null, picks
  /// [WebMseStreamSink] on Flutter web and [VideoPlayerMseStreamSink]
  /// elsewhere.
  final TwaiSinkFactory? sinkFactory;

  /// Fade duration for the idle↔speaking sink opacity transition.
  /// See [TwaiAvatarPlayerStage.fadeDuration].
  final Duration fadeDuration;

  /// Non-null → route through Adapter 4 (twai-api `/v1/*`). See the
  /// constructor doc for the mode split.
  final TwaiApiRestClient? twaiApiRestClient;

  /// Optional brain callback for Adapter 4 (user text → reply). Ignored
  /// unless [twaiApiRestClient] is also non-null. `null` = echo mode
  /// (avatar says the literal user text).
  final TwaiBrainCallback? brain;

  /// Optional streaming brain callback for Adapter 4. Mutually exclusive
  /// with [brain]. When set, the brain implementation drives /speak per
  /// sentence itself as it streams — dramatically lower time-to-first-word
  /// than [brain]'s single-shot pattern. Ignored unless [twaiApiRestClient]
  /// is also non-null. See [TwaiStreamingBrainCallback] docs.
  final TwaiStreamingBrainCallback? streamingBrain;

  @override
  State<TwaiPlayer> createState() => _TwaiPlayerState();
}

class _TwaiPlayerState extends State<TwaiPlayer> {
  late TwaiPlayerHandle _handle;
  late VideoSink _sink;
  bool _ownsHandle = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _handle = widget.controller!;
      _ownsHandle = false;
    } else {
      _handle = _buildHandle();
      _ownsHandle = true;
    }
    _sink = (widget.sinkFactory ?? _defaultSinkFactory)(_handle.controller);
    // Bridge the controller's broadcast feed into the sink's
    // session-shaped attach() surface. Without this, non-web sinks
    // (VideoPlayerMseStreamSink, MediaKitMseStreamSink) get
    // constructed but never subscribe — the idle-video layer plays
    // underneath but real speech video/audio never routes to the
    // sink. Text replies still arrive because they're on the
    // controller's replyText, not the sink.
    //
    // Regression 2026-07-21 (Jim): facade profile in jesus rendered
    // Krystal's idle + accepted input + text replies came back
    // (after the state-block timeout fix), but no voice. Root cause
    // was this missing attach.
    //
    // WebMseStreamSink subscribes internally at construction (takes
    // controller: ctrl in its constructor); its attach() is a no-op
    // in that case. Safe to call either way.
    // ignore: discarded_futures
    _sink.attach(_ControllerFeedShim(_handle.controller));
  }

  @override
  void dispose() {
    // Sink always owned by the widget — always dispose it.
    // ignore: discarded_futures
    _sink.dispose();
    // Handle: dispose only when we constructed it AND autoDispose
    // is on. External handles are the app's responsibility.
    if (_ownsHandle && widget.autoDispose) {
      // ignore: discarded_futures
      _handle.dispose();
    }
    super.dispose();
  }

  TwaiPlayerHandle _buildHandle() {
    // Adapter 4 opt-in: caller passed a twai-api REST client. Use the
    // factory that bakes the right auto-behavior defaults (all
    // penthouse-side fetches off; twai-api doesn't serve them).
    if (widget.twaiApiRestClient != null) {
      return TwaiPlayerHandle.forApiSession(
        avatar: widget.avatar,
        outfit: widget.outfit,
        env: widget.env,
        config: widget.config,
        autoConnect: widget.autoConnect,
        restClient: widget.twaiApiRestClient!,
        brain: widget.brain,
        streamingBrain: widget.streamingBrain,
      );
    }
    // Default: Adapter 1 (penthouse MSE-over-WS).
    return TwaiPlayerHandle(
      avatar: widget.avatar,
      outfit: widget.outfit,
      env: widget.env,
      publishableKey: widget.publishableKey,
      authToken: widget.authToken,
      gestures: widget.gestures,
      frames: widget.frames,
      autoFetchGestures: widget.autoFetchGestures,
      autoFetchFrames: widget.autoFetchFrames,
      autoFetchProgress: widget.autoFetchProgress,
      autoAwardXp: widget.autoAwardXp,
      autoFetchStateBlock: widget.autoFetchStateBlock,
      autoRecordReply: widget.autoRecordReply,
      config: widget.config,
      autoConnect: widget.autoConnect,
      pathPrefix: widget.pathPrefix,
    );
  }

  VideoSink _defaultSinkFactory(TwaiAvatarPlayerController ctrl) {
    if (kIsWeb) {
      return WebMseStreamSink(controller: ctrl);
    }
    // TODO(sink): pick MediaKitMseStreamSink on Windows once Path B
    // Phase 2 lands the libmpv tail-follow. For now, video_player
    // sink works cross-platform (accumulate-then-play).
    // debugLog: true — temporary, for diagnosing streaming-brain per-clause
    // sealing behavior on Android. Revert once counter-based sealing is
    // confirmed working end-to-end.
    return VideoPlayerMseStreamSink(debugLog: true);
  }

  @override
  Widget build(BuildContext context) {
    // Idle source: explicit override wins; else derive from the
    // resolved outfit's idleUrl (populated after connect); else fall
    // back to the first outfit's URL as a static default.
    final idleUrl = _handle.currentOutfit?.idleUrl ??
        widget.avatar.outfits.first.idleUrl;
    final idleSource =
        widget.idleSource ?? NetworkVideoIdle(Uri.parse(idleUrl));

    return TwaiAvatarPlayerStage(
      controller: _handle.controller,
      sink: _sink,
      idleSource: idleSource,
      fadeDuration: widget.fadeDuration,
    );
  }
}

/// Adapts a [TwaiAvatarPlayerController]'s broadcast feed into the
/// [ChatSession] surface that [VideoSink.attach] expects. Only the
/// two streams the built-in sinks actually consume are wired —
/// [videoBytes] + [speakingEvents]. Everything else on the
/// [ChatSession] contract throws [UnsupportedError], because a sink
/// has no business calling connect/send/close/etc. on the shim (the
/// real session lifecycle lives inside the controller).
///
/// The shim is a runtime bridge, not a public API — kept private so
/// nothing accidentally extends its contract. If we ever grow a
/// proper controller-driven `VideoSink.attachFeed` primitive on the
/// interface, this shim goes away and TwaiPlayer calls that instead.
class _ControllerFeedShim implements ChatSession {
  _ControllerFeedShim(this._controller);
  final TwaiAvatarPlayerController _controller;

  /// Late-subscriber init replay for NON-web sinks (iOS
  /// `VideoPlayerMseStreamSink`, Windows `MediaKitMseStreamSink`).
  ///
  /// Companion to the equivalent fix in `WebMseStreamSink`. Same
  /// root cause: `controller.videoBytes` is a broadcast stream; muse
  /// sends the fMP4 init segment (ftyp+moov) as the FIRST binary WS
  /// frame per session and never repeats. When multiple `TwaiPlayer`
  /// widgets in the tree each call `sink.attach(shim)` at different
  /// times, only the shim attached before WS-connect sees the init.
  ///
  /// On non-web accumulate-then-play sinks, missing the init means
  /// the accumulated file starts with `moof/mdat` fragments — an
  /// invalid MP4 — and video_player / media_kit fail to decode.
  /// Symptom: idle plays, text replies work, no speech video/audio
  /// (identical to the pre-fix Chrome bug).
  ///
  /// Fix: prepend `controller.cachedInitSegment` to the videoBytes
  /// stream we expose. New subscribers get init at stream position
  /// 0 before any live bytes. If no init has been cached yet
  /// (subscribing before WS-connect), the concat degenerates to the
  /// live stream unchanged.
  @override
  Stream<Uint8List> get videoBytes {
    final init = _controller.cachedInitSegment;
    if (init == null) return _controller.videoBytes;
    // Emit the cached init first, then delegate to the live stream.
    // Uses async* so the init emit is bound to the subscriber's
    // listen() call — each late subscriber gets its own init copy
    // followed by the live stream from its subscribe moment on.
    return _prependInit(init, _controller.videoBytes);
  }

  static Stream<Uint8List> _prependInit(
    Uint8List init,
    Stream<Uint8List> tail,
  ) async* {
    yield init;
    yield* tail;
  }

  @override
  Stream<SpeakingEvent> get speakingEvents => _controller.speakingEvents;

  // Passed through so non-web accumulate-then-play sinks can seal
  // per-clause when the customer uses TwaiStreamingBrainCallback.
  // On Adapter 1 / 2 the controller forwards an empty stream — harmless.
  @override
  Stream<void> get speakBoundaries => _controller.speakBoundaries;

  // ── The rest of ChatSession — the sinks should never touch these.
  //    Fail loudly if they do so we catch mistakes early. ────────────

  @override
  Future<void> connect(Avatar avatar) =>
      throw UnsupportedError('_ControllerFeedShim.connect');

  @override
  Future<void> sendMessage(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) =>
      throw UnsupportedError('_ControllerFeedShim.sendMessage');

  @override
  Stream<String> get replyText => const Stream<String>.empty();

  @override
  Future<ChatSessionEndReason> get done => Completer<ChatSessionEndReason>().future;

  @override
  Future<void> close() async {
    // No-op — the shim doesn't own any state; the controller owns
    // the real session lifecycle. When TwaiPlayer disposes it just
    // calls _sink.dispose(); the shim gets garbage-collected.
  }
}
