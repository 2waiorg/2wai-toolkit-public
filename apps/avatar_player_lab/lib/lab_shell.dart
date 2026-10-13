// LabShell — the persistent split-pane surface.
//   Left  = TwaiPlayer stage (avatar rendered here)
//   Right = tabbed panel bar (all P1-P6 panels)
//
// Everything-on-by-default: boot shows Sophi in date-outfit, all panels
// accessible, dev-mode panels hidden until the flag flips.
//
// The stage rebuilds when LabState.rebuildToken bumps — this drops the
// old handle and constructs a new TwaiPlayer with the current knobs.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:http/http.dart' as http;
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/twai_avatar_sdk_livekit.dart'
    show createLiveKitHandle, liveKitSinkFactory;
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;
import 'package:twai_avatar_sdk_video_player/twai_avatar_sdk_video_player.dart'
    show VideoPlayerMseStreamSink;
import 'package:twai_avatar_sdk_web_mse/twai_avatar_sdk_web_mse.dart'
    show WebMseStreamSink;

import 'dev_mode.dart';
import 'known_avatars.dart' show LabTransport;
import 'lab_state.dart';
import 'panels/adapter_picker.dart';
import 'panels/config_panel.dart' show ConfigPanel, PlayerConfigCopyWith;
import 'panels/construction_panel.dart';
import 'panels/credentials_panel.dart';
import 'panels/debug_overlay_panel.dart';
import 'panels/idle_source_panel.dart';
import 'panels/immersive_panel.dart';
import 'panels/runtime_methods_panel.dart';
import 'panels/sink_panel.dart';
import 'panels/streams_panel.dart';
import 'panels/wire_panel.dart';
import 'panels/wire_recorder_panel.dart';
import 'theme.dart';

class LabShell extends StatefulWidget {
  final LabState state;
  final DevMode devMode;
  const LabShell({super.key, required this.state, required this.devMode});
  @override
  State<LabShell> createState() => _LabShellState();
}

class _LabShellState extends State<LabShell> {
  TwaiPlayerHandle? _handle;
  int _mountedRebuildToken = -1;
  DateTime? _versionChipPressStart;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_syncHandle);
    _syncHandle();
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncHandle);
    _handle?.dispose();
    widget.state.bindHandle(null);
    super.dispose();
  }

  void _syncHandle() {
    if (!mounted) return;
    if (widget.state.rebuildToken == _mountedRebuildToken) return;
    _handle?.dispose();
    // Transport 0 owns its own session lifecycle (see
    // `TwaiTransport0Player`). Building a LiveKit-flavoured
    // `TwaiPlayerHandle` here would race it: the old handle would
    // auto-connect a second `LiveKitChatSession` on every rebuild,
    // fire its own mint request (usually failing with a stale
    // avatar_id from a previous rebuild), and surface the failure
    // through `TwaiConnectionOverlay` while the real T0 session
    // rendered fine underneath. Skip the handle build entirely on
    // the LiveKit path.
    _handle = widget.state.effectiveTransport == LabTransport.liveKit
        ? null
        : _buildHandleFor(widget.state);
    _mountedRebuildToken = widget.state.rebuildToken;
    widget.state.bindHandle(_handle);
    setState(() {});
  }

  static TwaiPlayerHandle _buildHandleFor(LabState s) {
    final env = switch (s.env) {
      EnvKind.staging => TwaiEnvironment.twaiStaging,
      EnvKind.prod => TwaiEnvironment.twaiProd,
      EnvKind.twaiApi => TwaiEnvironment.twaiApi,
    };
    // twai-api transport (Mila, Dr. Alman) — two paths:
    //   1. API DIRECT MODE (sk_ key) wins when set — hits api.2wai.ai
    //      direct via the CORS opt-in Mason shipped 2026-08. Dev-only.
    //   2. Mint proxy URL — the production shape (sk_ never in browser).
    // If neither is set on a twai-api avatar, we fall through to the
    // default Adapter-1 handle (won't reach the avatar, but at least
    // idle plays from the outfit's idleUrl).
    // Adapter-5 (LiveKit) — separate wire from Adapter 4. Gateway
    // brokers a LiveKit participant token via
    // POST /v1/sessions {transport: "livekit"}, and the SDK's
    // LiveKitChatSession joins a room instead of consuming fMP4 over
    // WS. Requires the Dr. Alman avatar row to have
    // livekit_profile="livealman" set on the gateway (see
    // twai-api/gateway/app/routers/admin.py::set_avatar_livekit_profile).
    if (s.effectiveTransport == LabTransport.liveKit) {
      // LiveKit currently only rides the proxy path — sk_ direct hits
      // api.2wai.ai directly and works fine as long as CORS allows it.
      final proxy = s.milaProxyUrl;
      final directKey = s.directApiKey;
      final rest = proxy != null
          ? TwaiApiRestClient(
              baseUrl: Uri.parse(proxy),
              credentials: const AnonymousCredentials(),
            )
          : directKey != null
              ? TwaiApiRestClient(
                  baseUrl: Uri.parse('https://api.2wai.ai'),
                  credentials: TwaiApiKeyCredentials.devOnly(directKey),
                )
              : null;
      if (rest != null) {
        // Three knobs bent for LiveKit -- all three are MSE-wire
        // watchdogs (default 5s / 3s / 2s) that fire on missing fMP4
        // bytes. LiveKit rides a WebRTC track; videoBytes is
        // intentionally empty aside from a single "ready ping" the
        // session emits after the LK track subscribes. Left at
        // defaults, the sequence is:
        //   t=0    connect, ready-ping emitted
        //   t=2s   liveness tick: byte age 2s < 3s -> OK
        //   t=4s   liveness tick: byte age 4s > 3s -> FORCE RECONNECT
        //   ...    loop every 4s (this is what Jim was seeing)
        // Bump all three well past any realistic session lifetime so
        // LiveKit-native reconnect (Room.on(RoomEvent.Reconnecting))
        // owns connection health end-to-end, not the MSE watchdogs.
        //
        // userId omitted: broker validates strictly to `anon-{uuid}`
        // or bare UUID. Gateway synthesises when null.
        final liveKitConfig = s.config.copyWith(
          resumeRecovery: const Duration(days: 1),
          wsSilence: const Duration(days: 1),
          livenessHeartbeat: const Duration(hours: 1),
        );
        return createLiveKitHandle(
          avatar: s.avatar.avatar,
          restClient: rest,
          config: liveKitConfig,
          autoConnect: s.autoConnect,
        );
      }
      // Fall through: no proxy AND no direct key -> Adapter-1 handle
      // that at least renders the idleUrl but can't reach LiveKit.
    }
    if (s.effectiveTransport == LabTransport.twaiApiRestWss) {
      // Adapter-4 pipelines are speak-first — no video bytes flow
      // until user calls /speak. Default 5s resumeRecovery watchdog is
      // an Adapter-1 stall detector; here it fires spuriously before
      // the first send + kills the session ("resume recovery timeout").
      // Merge onto whatever the user has in the CONFIG panel.
      final adapter4Config = s.config.copyWith(
        resumeRecovery: const Duration(minutes: 30),
      );

      final resolved = resolveAdapter4Mode(s);
      if (resolved.transport == AdapterTransport.proxy) {
        final rest = TwaiApiRestClient(
          baseUrl: Uri.parse(resolved.proxyUrl!),
          credentials: const AnonymousCredentials(),
        );
        return TwaiPlayerHandle.forApiSession(
          avatar: s.avatar.avatar,
          restClient: rest,
          streamingBrain: resolved.brain == AdapterBrain.sse
              ? _makeStreamingBrainReply(
                  brainUrl: resolved.brainStreamUrl!,
                  userId: 'lab-${s.avatar.avatar.slug}-'
                      '${DateTime.now().millisecondsSinceEpoch}',
                )
              : _echoBrain,
          config: adapter4Config,
          autoConnect: s.autoConnect,
        );
      }
      if (resolved.transport == AdapterTransport.directKey) {
        final rest = TwaiApiRestClient(
          baseUrl: Uri.parse('https://api.2wai.ai'),
          credentials: TwaiApiKeyCredentials.devOnly(resolved.directKey!),
        );
        return TwaiPlayerHandle.forApiSession(
          avatar: s.avatar.avatar,
          restClient: rest,
          streamingBrain: _echoBrain,  // no /brain/stream on api.2wai.ai
          config: adapter4Config,
          autoConnect: s.autoConnect,
        );
      }
    }
    return TwaiPlayerHandle(
      avatar: s.avatar.avatar,
      env: env,
      autoConnect: s.autoConnect,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.devMode,
        builder: (_, __) => _buildWithMode(context),
      );

  Widget _buildWithMode(BuildContext context) {
    final panels = <_TabDef>[
      _TabDef('ADAPTER', AdapterPickerPanel(state: widget.state)),
      _TabDef('CONSTRUCT', ConstructionPanel(state: widget.state)),
      _TabDef('CREDS', CredentialsPanel(state: widget.state)),
      _TabDef('METHODS', RuntimeMethodsPanel(state: widget.state)),
      _TabDef('STREAMS', StreamsPanel(state: widget.state)),
      _TabDef('IDLE', IdleSourcePanel(state: widget.state)),
      _TabDef('IMMERSIVE', ImmersivePanel(state: widget.state)),
      if (widget.devMode.enabled) ...[
        const _TabDef('DEBUG', DebugOverlayPanel()),
        _TabDef('WIRE', WirePanel(state: widget.state)),
        _TabDef('WIRE REC', WireRecorderPanel(state: widget.state)),
        _TabDef('CONFIG', ConfigPanel(state: widget.state)),
        _TabDef('SINK', SinkPanel(state: widget.state)),
      ],
    ];

    return DefaultTabController(
      length: panels.length,
      child: TwaiKeyboardShortcutsOverlay(
        // Never bind ordinary typing characters globally in an app that has
        // text composers. The SDK also suppresses shortcuts while an editor
        // owns focus, but modifier-qualified lab shortcuts remain safe even
        // if a browser temporarily reports focus incorrectly.
        helpTrigger: const SingleActivator(
          LogicalKeyboardKey.slash,
          alt: true,
        ),
        shortcuts: _shortcutsFor(context),
        // Browser autoplay is a document-level policy, not a video-widget
        // policy. Retry the LiveKit audio unlock on every pointer gesture
        // anywhere in the lab (composer focus, SEND, tabs, stage, etc.).
        // Listener runs on pointer-down before the target widget's callback,
        // keeping Room.startAudio() inside the browser user-activation stack.
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            final engine = widget.state.currentTransport0Engine;
            if (engine != null) unawaited(engine.resumePlayback());
          },
          child: Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(children: [
            const Text('AVATAR PLAYER LAB',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                    fontSize: 14)),
            const SizedBox(width: 12),
            _VersionChip(
              devMode: widget.devMode,
              onPressStart: () => _versionChipPressStart = DateTime.now(),
              onPressEnd: () {
                final start = _versionChipPressStart;
                _versionChipPressStart = null;
                if (start == null) return;
                if (DateTime.now().difference(start).inSeconds >= 2) {
                  widget.devMode.enable();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    duration: Duration(seconds: 2),
                    content: Text('Dev mode enabled'),
                    backgroundColor: LabColors.accent,
                  ));
                }
              },
            ),
          ]),
          actions: [
            AnimatedBuilder(
              animation: widget.state,
              builder: (_, __) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _BrainModeChip(state: widget.state),
                  const SizedBox(width: 6),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: LabColors.chrome,
                    side: const BorderSide(color: LabColors.border),
                    label: Text(widget.state.avatar.avatar.name,
                        style: const TextStyle(
                            color: LabColors.text, fontSize: 11)),
                    avatar: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: LabColors.live,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            // Stage listens to `state` directly so runtime knobs
            // (zoomLevel, panLock, immersive toggles) rebuild the stage
            // without needing a full handle re-mount. Construction knobs
            // still bump rebuildToken and go through _syncHandle above.
            final stage = AnimatedBuilder(
              animation: widget.state,
              builder: (_, __) =>
                  _Stage(state: widget.state, handle: _handle),
            );
            final rightPane = SafeArea(
              top: false,
              child: Column(children: [
                Container(
                  color: LabColors.chrome,
                  child: TabBar(
                    isScrollable: true,
                    tabs: [for (final t in panels) Tab(text: t.label)],
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: TabBarView(
                    children: [for (final t in panels) t.body],
                  ),
                ),
              ]),
            );

            if (wide) {
              return Row(children: [
                SizedBox(width: constraints.maxWidth * 0.55, child: stage),
                const VerticalDivider(width: 1),
                Expanded(child: rightPane),
              ]);
            }
            return Column(children: [
              Expanded(flex: 5, child: stage),
              const Divider(),
              Expanded(flex: 6, child: rightPane),
            ]);
          },
        ),
          ),
        ),
      ),
    );
  }

  /// Real callbacks for the Mason-default shortcuts. Debug toggle flips
  /// dev-mode on/off; immersive/outfits nudge the user into the right
  /// tab of the panel bar (DefaultTabController isn't in scope from
  /// here — deferring the actual tab-switch to a later slice, snack
  /// for now so the shortcut path is at least reachable).
  List<TwaiShortcut> _shortcutsFor(BuildContext context) => [
        TwaiShortcut(
          activator: const SingleActivator(
            LogicalKeyboardKey.keyD,
            shift: true,
            control: true,
          ),
          label: 'Ctrl+Shift+D',
          description: 'Toggle dev mode (debug overlay)',
          onPressed: () {
            if (widget.devMode.enabled) {
              widget.devMode.disable();
            } else {
              widget.devMode.enable();
            }
          },
        ),
        TwaiShortcut(
          activator: const SingleActivator(
            LogicalKeyboardKey.keyM,
            alt: true,
          ),
          label: 'Alt+M',
          description: 'Cycle stage zoom (Full → Mid → Close)',
          onPressed: () {
            widget.state.zoomLevel = widget.state.zoomLevel.next;
          },
        ),
        TwaiShortcut(
          activator: const SingleActivator(
            LogicalKeyboardKey.keyO,
            alt: true,
          ),
          label: 'Alt+O',
          description: 'Cycle to next outfit',
          onPressed: () async {
            final outfits = widget.state.avatar.avatar.outfits;
            final currentIdx = outfits.indexWhere(
                (o) => o.slug == widget.state.outfitSlug);
            final next = outfits[(currentIdx + 1) % outfits.length];
            widget.state.outfitSlug = next.slug;
            await widget.state.currentHandle?.switchOutfit(next);
          },
        ),
        TwaiShortcut(
          activator: const SingleActivator(
            LogicalKeyboardKey.keyR,
            alt: true,
          ),
          label: 'Alt+R',
          description: 'Rebuild stage',
          onPressed: () => widget.state.bumpRebuild(),
        ),
      ];
}

class _TabDef {
  final String label;
  final Widget body;
  const _TabDef(this.label, this.body);
}

class _Stage extends StatelessWidget {
  final LabState state;
  final TwaiPlayerHandle? handle;
  const _Stage({required this.state, required this.handle});
  @override
  Widget build(BuildContext context) {
    // Resolve idle source per state.idleKind. For P1: Network is default
    // (uses outfit.idleUrl via the SDK's built-in NetworkVideoIdle path).
    // Solid, None, Transparent, PosterNetwork wired directly. Asset +
    // PosterAsset are P2+ (would need bundled sample assets).
    AvatarIdleSource? idleOverride;
    switch (state.idleKind) {
      case IdleKind.network:
        idleOverride = null;   // fall back to outfit.idleUrl
        break;
      case IdleKind.solid:
        idleOverride = const SolidColorIdle(Color(0xFF08090C));
        break;
      case IdleKind.none:
        idleOverride = const NoIdle();
        break;
      case IdleKind.transparent:
        // Uses outfit's idleUrl as the (opaque) fallback; alpha
        // variants aren't in the seeded catalog yet — TransparentVideoIdle
        // will still render the fallback in that case.
        final url = state.currentOutfit.idleUrl;
        idleOverride = url.isNotEmpty
            ? TransparentVideoIdle(fallbackVideoUrl: url)
            : const NoIdle();
        break;
      case IdleKind.posterNetwork:
        // No poster URL in outfit yet; fall back to the network idle URL
        // as a poster (video frame will be plausible). P2: proper poster
        // URLs in avatar catalog.
        final url = state.currentOutfit.idleUrl;
        idleOverride = url.isNotEmpty
            ? NetworkPosterIdle(Uri.parse(url))
            : const NoIdle();
        break;
      case IdleKind.asset:
      case IdleKind.posterAsset:
        // P2+: needs bundled sample assets. Fall back to Network for now.
        idleOverride = null;
        break;
    }

    // LiveKit needs a WebRTC-track sink (LiveKitVideoSink); MSE + video_player
    // sinks would consume the empty videoBytes stream and render nothing.
    // Switch by transport, not by the SINK panel picker.
    final sinkFactory = state.effectiveTransport == LabTransport.liveKit
        ? liveKitSinkFactory()
        : _sinkFactoryFor(state.sinkKind);

    // Transport 0 (LiveKit-native) branch: bypass TwaiPlayerHandle entirely
    // and build the engine-native widget. No controller, no shim, no
    // MSE-era OR gate. Requires a mint proxy (or dev-only sk_ key) to
    // resolve a LiveKit token; falls back to the connecting spinner
    // until one is configured.
    final Widget player;
    if (state.effectiveTransport == LabTransport.liveKit) {
      final proxy = state.milaProxyUrl;
      final directKey = state.directApiKey;
      final rest = proxy != null
          ? TwaiApiRestClient(
              baseUrl: Uri.parse(proxy),
              credentials: const AnonymousCredentials(),
            )
          : directKey != null
              ? TwaiApiRestClient(
                  baseUrl: Uri.parse('https://api.2wai.ai'),
                  credentials: TwaiApiKeyCredentials.devOnly(directKey),
                )
              : null;
      if (rest == null) {
        player = const Center(
            child: CircularProgressIndicator(color: LabColors.accent));
      } else {
        player = t0.TwaiTransport0Player(
          key: ValueKey('t0-${state.rebuildToken}'),
          mint: () async {
            try {
              // Gateway expects the PIPELINE id (avt_…) on the outfit,
              // not the PlayerAvatar's slug. The old handle path went
              // through `outfit.toAvatar()` which reads `pipelineName`;
              // sending the slug (`dr-alman`) instead 404s the mint.
              //
              // voice_id is TENANT-SCOPED: the gateway looks up
              // `Voice.id == voice_id` on the tenant DB (sessions.py
              // :62-67) and 404s no_such_voice on miss. PlayerAvatar
              // .voiceId carries either a real `vc_...` row id
              // (Alman) or a Qwen `ref_audio_id` string (`sophi-ft`,
              // `bellav-ft`) that ISN'T a tenant Voice row. Only
              // forward the vc_ shape; for everything else, let the
              // broker's profile config pick the default voice (that
              // matches PP's live behaviour). Do NOT send an empty
              // string — the gateway treats "" as truthy for the
              // lookup gate.
              final rawVoiceId = state.avatar.avatar.voiceId;
              final voiceId =
                  rawVoiceId.startsWith('vc_') ? rawVoiceId : null;
              final mint = await rest.createLiveKitSession(
                TwaiApiLiveKitSessionRequest(
                  avatarId: state.currentOutfit.pipelineName,
                  voiceId: voiceId,
                ),
              );
              return t0.MintResultEnabled(
                url: mint.livekitUrl.toString(),
                token: mint.participantToken,
                room: mint.roomName,
              );
            } on TwaiApiRateLimitedException catch (e) {
              throw t0.MintRateLimited(e.retryAfterSeconds ?? 60);
            } catch (e) {
              throw t0.MintUnavailable('gateway mint failed: $e', cause: e);
            }
          },
          // idleOverride is null when the panel says "network default",
          // which on the old TwaiPlayer meant "fall back to
          // outfit.idleUrl inside AvatarPlayerStage". Transport 0's
          // widget doesn't have that fallback, so translate the
          // signal here: null → NetworkVideoIdle(outfit.idleUrl) when
          // available, else NoIdle. Without this the stage renders
          // pure black in Transport 0 default mode.
          idleBuilder: (ctx) {
            final resolved = idleOverride ??
                (state.currentOutfit.idleUrl.isNotEmpty
                    ? NetworkVideoIdle(Uri.parse(state.currentOutfit.idleUrl))
                    : const NoIdle());
            return resolved.build(ctx);
          },
          fadeDuration: state.fadeDuration,
          autoConnect: state.autoConnect,
          onEngine: (engine) => state.bindTransport0Engine(engine),
          onError: (err) => state.pushEvent(
              LabEventKind.status, 'engine ERROR: $err'),
        );
      }
    } else {
      player = handle == null
          ? const Center(
              child: CircularProgressIndicator(color: LabColors.accent))
          : TwaiPlayer(
              key: ValueKey(state.rebuildToken),
              avatar: state.avatar.avatar,
              outfit: state.currentOutfit,
              controller: handle,
              idleSource: idleOverride,
              fadeDuration: state.fadeDuration,
              autoConnect: state.autoConnect,
              config: state.config,
              sinkFactory: sinkFactory,
            );
    }

    // Wrap in a TwaiSceneStage when zoom or panLock differ from defaults.
    // Otherwise render the bare player — keeps the stage tree minimal for
    // consumers who never touch these knobs.
    Widget stageContent = (state.zoomLevel != StageZoomLevel.full ||
            state.panLock)
        ? TwaiSceneStage(
            feed: player,
            zoomLevel: state.zoomLevel,
            panLock: state.panLock,
          )
        : player;

    // Optional connection overlay — real wrapper primitive from the SDK.
    // Paints a status-aware overlay (connecting spinner + tap-to-retry on
    // failed) on top of the player via a Stack. Needs handle.controller.
    final localHandle = handle;
    if (state.showConnectionOverlay && localHandle != null) {
      stageContent = TwaiConnectionOverlay(
        controller: localHandle.controller,
        connectingBuilder: (_) => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: LabColors.accent),
              SizedBox(height: 10),
              Text('Connecting…',
                  style: TextStyle(
                      color: LabColors.text,
                      fontSize: 12,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        failedBuilder: (_, cause) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 40, color: LabColors.bad),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Connection failed: ${cause ?? "unknown"}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: LabColors.text, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('RETRY'),
                onPressed: () => localHandle.manualReconnect(),
              ),
            ],
          ),
        ),
        child: stageContent,
      );
    }

    // Outer viewport wrapper — TwaiImmersiveLayout when toggled on,
    // otherwise the bare ColoredBox + Center + AspectRatio we've always
    // had. Both lock the stage to a 9/16 portrait; the SDK primitive
    // adds landscape-vs-portrait viewport handling on top.
    final viewportWrap = state.showImmersiveLayout
        ? TwaiImmersiveLayout(
            avatar: stageContent,
            landscapeAspectRatio: 9 / 16,
            portraitFallback: ColoredBox(
              color: Colors.black,
              child: Center(
                child: AspectRatio(
                    aspectRatio: 9 / 16, child: stageContent),
              ),
            ),
          )
        : ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: stageContent,
              ),
            ),
          );

    return Stack(children: [
      Positioned.fill(child: viewportWrap),
      // Always-visible status HUD -- shows the exact PlayerStatus so
      // you never wonder if the pipeline is up. Top-left, small,
      // subclickable pass-through so it doesn't eat gestures.
      Positioned(
        top: 8,
        left: 8,
        child: IgnorePointer(
          child: _StatusHud(handle: handle),
        ),
      ),
    ]);
  }
}

class _StatusHud extends StatefulWidget {
  final TwaiPlayerHandle? handle;
  const _StatusHud({required this.handle});
  @override
  State<_StatusHud> createState() => _StatusHudState();
}

class _StatusHudState extends State<_StatusHud> {
  PlayerStatus? _status;
  StreamSubscription<PlayerStatusEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant _StatusHud old) {
    super.didUpdateWidget(old);
    if (!identical(old.handle, widget.handle)) {
      _sub?.cancel();
      _status = null;
      _attach();
    }
  }

  void _attach() {
    final h = widget.handle;
    if (h == null) return;
    _sub = h.status.listen((e) {
      if (!mounted) return;
      setState(() => _status = e.status);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final (label, color) = switch (s) {
      null => ('IDLE', LabColors.textDim),
      PlayerStatus.connecting => ('CONNECTING', LabColors.wait),
      PlayerStatus.ready => ('READY', LabColors.live),
      PlayerStatus.speaking => ('SPEAKING', LabColors.accent),
      PlayerStatus.failed => ('FAILED', LabColors.bad),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color,
                fontSize: 10,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace')),
      ]),
    );
  }
}

/// App-bar chip that surfaces which brain the current avatar is about
/// to invoke. Hidden for Adapter-1 avatars (Penthouse has its own
/// server-owned brain baked into the wire — no lab-level knob).
///
/// Adapter-4 modes:
///   * BRAIN — SSE via `<proxy>/brain/stream` (Dr. Alman when the
///             mint proxy is up + BRAIN_URL is set server-side).
///   * ECHO  — user text repeats verbatim into /speak (Mila's
///             reflective mode, or any Adapter-4 avatar in direct-key
///             mode since api.2wai.ai has no /brain/stream).
///   * NONE  — no proxy AND no direct key set; Adapter-4 can't reach
///             the pipeline at all yet.
class _BrainModeChip extends StatelessWidget {
  final LabState state;
  const _BrainModeChip({required this.state});
  @override
  Widget build(BuildContext context) {
    // Adapter 5 (LiveKit) — brain runs server-side inside livealman-host.
    // Nothing for the client to choose between echo / SSE / etc, so the
    // chip just marks the wire.
    if (state.effectiveTransport == LabTransport.liveKit) {
      const label = 'LIVEKIT';
      const color = Color(0xFF3F8CFF);   // blue — new + distinct
      return Tooltip(
        message:
            'Adapter 5 — WebRTC via LiveKit. Server-side livealman-host '
            'runs Soniox per-clause TTS and publishes audio + video '
            'tracks the SDK subscribes to. Brain is server-owned; the '
            'reply arrives on the `2wai.reply` LiveKit data topic. '
            'Requires the gateway to have the LiveKit broker configured '
            'AND avatar.livekit_profile set on the tenant.',
        child: _brainChip(label, color),
      );
    }
    if (state.effectiveTransport != LabTransport.twaiApiRestWss) {
      return const SizedBox.shrink();
    }
    final resolved = resolveAdapter4Mode(state);
    late final String label;
    late final Color color;
    late final String tooltip;
    if (resolved.transport == AdapterTransport.none) {
      label = 'NO WIRE';
      color = LabColors.bad;
      tooltip =
          'No mint proxy and no sk_ direct key set. Adapter-4 avatars '
          'can\'t reach the pipeline. Open ADAPTER and either paste an '
          'sk_ key or point at a running mint proxy.';
    } else if (resolved.brain == AdapterBrain.sse) {
      label = 'BRAIN';
      color = LabColors.live;
      tooltip =
          'SSE brain via ${resolved.brainStreamUrl}. Every user turn '
          'POSTs there; the reply streams back as sentence-chunked '
          'SSE and the SDK speaks each clause as it lands. Server-side '
          'BRAIN_URL must be set on your mint proxy (default: the 2wai '
          'brain at http://20.221.72.255, persona: brian-alman).';
    } else {
      label = resolved.transport == AdapterTransport.directKey
          ? 'ECHO (direct)'
          : 'ECHO (proxy)';
      color = LabColors.wait;
      tooltip = resolved.transport == AdapterTransport.directKey
          ? 'Direct sk_ mode — hitting api.2wai.ai/v1/* straight. Direct '
              'mode has no /brain/stream endpoint, so every avatar runs '
              'in echo (repeats your text verbatim). CLEAR the sk_ in '
              'ADAPTER to switch to proxy mode + real brain for '
              'usesBrain=true avatars.'
          : 'Echo mode — user text repeats verbatim into /speak. '
              'Expected for pipeline-only demos (Mila reflective). '
              'For avatars with usesBrain=true (Dr. Alman), an SSE '
              'brain kicks in automatically when the proxy is up.';
    }
    return Tooltip(
      message: tooltip,
      child: _brainChip(label, color),
    );
  }

  Widget _brainChip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace')),
        ]),
      );
}

class _VersionChip extends StatelessWidget {
  final DevMode devMode;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;
  const _VersionChip({
    required this.devMode,
    required this.onPressStart,
    required this.onPressEnd,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: devMode,
        builder: (_, __) => GestureDetector(
          onTapDown: (_) => onPressStart(),
          onTapUp: (_) => onPressEnd(),
          onTapCancel: () => onPressEnd(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(
                color: devMode.enabled ? LabColors.accent : LabColors.border,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              devMode.enabled ? 'v0.1.4 · DEV' : 'v0.1.4',
              style: TextStyle(
                color: devMode.enabled ? LabColors.accent : LabColors.textDim,
                fontSize: 10,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      );
}

// ---- Adapter-4 mode resolution --------------------------------------------
//
// Given LabState, decide (a) which Adapter-4 transport to use (mint
// proxy or direct-key) and (b) which brain to plug in (SSE via
// `<proxy>/brain/stream` or echo). Shared by _buildHandleFor above and
// the BRAIN mode chip in the app bar so both agree on what the user is
// actually about to run.
//
// Precedence:
//   1. Brain avatars (`usesBrain: true`) FORCE proxy when a proxy URL
//      is set — direct mode has no /brain/stream on api.2wai.ai, so a
//      brain avatar in direct mode would silently fall back to echo,
//      which is exactly the "why did Dr. Alman just parrot me?"
//      surprise. Proxy wins for the brain path.
//   2. Otherwise direct-key wins over proxy (matches Adapter DIRECT's
//      "sk_ in browser is opt-in but decisive" contract).
//   3. Fall through to proxy-with-echo (Mila's default shape).

enum AdapterTransport { proxy, directKey, none }
enum AdapterBrain { sse, echo }

class Adapter4Mode {
  final AdapterTransport transport;
  final AdapterBrain brain;
  final String? proxyUrl;
  final String? directKey;
  final String? brainStreamUrl;
  const Adapter4Mode({
    required this.transport,
    required this.brain,
    this.proxyUrl,
    this.directKey,
    this.brainStreamUrl,
  });
}

Adapter4Mode resolveAdapter4Mode(LabState s) {
  final proxy = s.milaProxyUrl;
  final directKey = s.directApiKey;
  final wantsBrain = s.avatar.usesBrain;

  // Brain avatars force proxy when we have one.
  if (wantsBrain && proxy != null) {
    return Adapter4Mode(
      transport: AdapterTransport.proxy,
      brain: AdapterBrain.sse,
      proxyUrl: proxy,
      brainStreamUrl:
          '${proxy.replaceAll(RegExp(r'/+$'), '')}/brain/stream',
    );
  }
  // Otherwise direct-key wins.
  if (directKey != null) {
    return Adapter4Mode(
      transport: AdapterTransport.directKey,
      brain: AdapterBrain.echo,
      directKey: directKey,
    );
  }
  if (proxy != null) {
    return Adapter4Mode(
      transport: AdapterTransport.proxy,
      brain: AdapterBrain.echo,
      proxyUrl: proxy,
    );
  }
  return const Adapter4Mode(
    transport: AdapterTransport.none,
    brain: AdapterBrain.echo,
  );
}

// ---- Streaming brain helpers ----------------------------------------------
//
// Ported verbatim from apps/enlighten/lib/main.dart's _streamingBrainReply,
// including Mason's sentence-chunk constants — a 50-char minimum and
// sentence-end-only split, learned from Qwen3-TTS re-embedding the
// reference voice on tiny fragments in production.

typedef _StreamingBrainReply = Future<String> Function(
  String userText,
  Future<void> Function(String sentence) speak,
);

/// Trivial echo brain — every turn becomes exactly one /speak with the
/// text the user typed. Proven working shape for pipeline-only demos
/// (Mila reflective mode).
Future<String> _echoBrain(
  String userText,
  Future<void> Function(String) speak,
) async {
  await speak(userText);
  return userText;
}

const _kBrainClauseEnders = {'.', '!', '?', '。', '！', '？'};
const _kBrainMinSentenceChars = 50;
final _kBrainEmojiRe = RegExp(
  r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}]+',
  unicode: true,
);
String _cleanClause(String text) =>
    text.toLowerCase().replaceAll(_kBrainEmojiRe, '').trim();

/// Build a streaming brain callback that POSTs to [brainUrl] (mint
/// proxy's SSE route), chunks per Mason's algorithm, and calls
/// speak(clause) per completed sentence.
_StreamingBrainReply _makeStreamingBrainReply({
  required String brainUrl,
  required String userId,
}) {
  return (String userText, Future<void> Function(String) speak) async {
    final client = http.Client();
    try {
      final req = http.Request('POST', Uri.parse(brainUrl))
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode({'text': userText, 'user_id': userId});
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        throw Exception(
            'brain/stream ${resp.statusCode}: '
            '${body.substring(0, body.length > 200 ? 200 : body.length)}');
      }

      String? currentEvent;
      final buf = StringBuffer(); // current unspoken clause
      final full = StringBuffer(); // everything the brain produced

      await for (final line in resp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.isEmpty) {
          currentEvent = null;
          continue;
        }
        if (line.startsWith('event:')) {
          currentEvent = line.substring(6).trim();
          continue;
        }
        if (!line.startsWith('data:')) continue;
        final dataStr = line.substring(5).trim();
        Map<String, dynamic> payload;
        try {
          payload = jsonDecode(dataStr) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        if (currentEvent == 'delta') {
          final msg = (payload['content'] as String?) ?? '';
          if (msg.isEmpty) continue;
          full.write(msg);
          var lastpos = 0;
          for (var i = 0; i < msg.length; i++) {
            if (_kBrainClauseEnders.contains(msg[i])) {
              buf.write(msg.substring(lastpos, i + 1));
              lastpos = i + 1;
              if (buf.toString().trim().length >= _kBrainMinSentenceChars) {
                final clause = _cleanClause(buf.toString());
                buf.clear();
                if (clause.isNotEmpty) await speak(clause);
              }
            }
          }
          buf.write(msg.substring(lastpos));
        } else if (currentEvent == 'final') {
          final content = (payload['content'] as String?) ?? '';
          if (content.isNotEmpty && full.isEmpty) {
            full.write(content);
            buf.clear();
            buf.write(content);
          }
        }
      }

      final tail = _cleanClause(buf.toString());
      if (tail.isNotEmpty) await speak(tail);

      final replyText = full.toString().trim();
      if (replyText.isEmpty) {
        throw Exception('brain stream produced no reply');
      }
      return replyText;
    } finally {
      client.close();
    }
  };
}

/// Build a TwaiSinkFactory for the current [SinkKind]. Null means the
/// SDK's auto-pick runs (WebMse on web, VideoPlayer otherwise).
///
/// WebMse construction throws UnsupportedError on non-web. VideoPlayer
/// works everywhere. MediaKit isn't linked in this app's pubspec so we
/// can't build it here — the SINK panel disables that row.
TwaiSinkFactory? _sinkFactoryFor(SinkKind kind) {
  switch (kind) {
    case SinkKind.auto:
      return null;
    case SinkKind.webMse:
      if (!kIsWeb) return null; // fall back to auto on native — panel warns
      return (ctrl) => WebMseStreamSink(controller: ctrl);
    case SinkKind.videoPlayer:
      return (_) => VideoPlayerMseStreamSink(debugLog: true);
    case SinkKind.mediaKit:
      return null; // package not linked; panel disables the row
  }
}

/// Small utility used across panels — a labeled row with a trailing widget.
class LabRow extends StatelessWidget {
  final String label;
  final String? sub;
  final Widget trailing;
  const LabRow({super.key, required this.label, this.sub, required this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: LabColors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(sub!,
                        style: const TextStyle(
                            color: LabColors.textDim, fontSize: 11)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ]),
      );
}

/// Snack helper shared by panels.
void showLabSnack(BuildContext context, String message, {bool bad = false}) {
  final messenger = ScaffoldMessenger.of(context);
  // Only the newest rapidly changing lab status is useful.
  messenger.removeCurrentSnackBar();
  final controller = messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 2),
    // Never let Flutter's action/accessibility defaults turn this into a
    // persistent status surface.
    persist: false,
    backgroundColor: bad ? LabColors.bad : LabColors.chrome,
    content: Text(message,
        style: TextStyle(color: bad ? Colors.white : LabColors.text)),
    // Failure details are short and transient. Keeping COPY on errors made
    // older/accessibility snackbar implementations hold them indefinitely.
    action: bad
        ? null
        : SnackBarAction(
            label: 'COPY',
            textColor: LabColors.accent,
            onPressed: () => Clipboard.setData(ClipboardData(text: message)),
          ),
  ));
  // Belt-and-suspenders close independent of SnackBar's internal timeout.
  Timer(const Duration(seconds: 2), controller.close);
}
