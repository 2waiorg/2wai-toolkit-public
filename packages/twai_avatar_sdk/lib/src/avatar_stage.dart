import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

import 'avatar_idle_source.dart';
import 'video_sink.dart';

/// The canonical customer-facing widget for rendering a conversational
/// avatar. Layers a caller-supplied [idleSource] (poster / looping
/// idle video / anything) behind the concrete [VideoSink]'s widget, so
/// the idle↔conversation↔idle state machine is transparent to the
/// customer app.
///
/// **The customer-app contract:**
///
/// ```dart
/// TwaiAvatarStage(
///   session: twai.mseStreamSession(pathPrefix: avatar.stack.pathPrefix),
///   avatar: avatar,
///   sinkFactory: () => MediaKitMseStreamSink(),   // or video_player, etc.
///   idleSource: NetworkVideoIdle(
///     Uri.parse('https://2waiassets.blob.core.windows.net/…/Idle1.mp4'),
///   ),
/// )
/// ```
///
/// That's the whole customer surface. No manual sink wiring, no
/// placeholder plumbing, no state-machine bookkeeping.
///
/// **What the widget owns internally:**
/// - Sink construction via [sinkFactory] (widget disposes the sink on
///   unmount — caller does NOT need to).
/// - Sink `.attach(session)` on first frame.
/// - `session.connect(avatar)` if [autoConnect] is true and the caller
///   hasn't already connected.
/// - Layering the sink's widget above [idleSource]'s widget in a Stack.
///
/// **What the caller still owns:**
/// - The [ChatSession] lifecycle — construction (via [TwaiClient]),
///   sendMessage calls, close(). Widget does not close the session on
///   unmount because most customer apps reuse the session across
///   several stages (e.g. hot-swap avatars in place).
///
/// **Sink choice per platform (customer picks):**
/// - Windows: `MediaKitMseStreamSink` — libmpv handles the sink's
///   sealed fMP4 correctly. Recommended today.
/// - iOS / Android / macOS / web: `VideoPlayerMseStreamSink`.
///   `media_kit` is unusable on iOS due to a `volume_controller`
///   transitive dep that crashes at plugin registration on iOS 26.5.
///
/// Wrapping the platform pick in a helper is customer-app work —
/// intentional, because SDK-core doesn't depend on either sink
/// package (customers choose which they ship to keep binary size
/// tight).
class TwaiAvatarStage extends StatefulWidget {
  const TwaiAvatarStage({
    super.key,
    required this.session,
    required this.avatar,
    required this.sinkFactory,
    this.idleSource = const NoIdle(),
    this.autoConnect = true,
    this.onConnectFailed,
    this.onConnected,
  });

  /// The chat session the sink drains. Caller constructs, caller owns
  /// lifecycle. Widget does NOT close on unmount.
  final ChatSession session;

  /// Avatar to connect to when [autoConnect] is true.
  final Avatar avatar;

  /// Zero-arg factory the widget calls once at mount to construct its
  /// internal [VideoSink]. Widget owns + disposes the returned sink.
  final VideoSink Function() sinkFactory;

  /// What renders during idle time (pre-first-turn + between turns).
  /// Layered behind the sink; sink is transparent when idle, so this
  /// shows through. Default [NoIdle] renders nothing — customer sees
  /// their scaffold background. Real customer apps almost always pass
  /// an [AssetVideoIdle], [NetworkVideoIdle], or [AssetPosterIdle].
  final AvatarIdleSource idleSource;

  /// If true (default), the widget calls `session.connect(avatar)` on
  /// first mount. Set false when the caller has already connected the
  /// session before mounting the stage.
  final bool autoConnect;

  /// Called with the connect exception when [autoConnect] fires and
  /// throws. Widget swallows the error otherwise; caller should log
  /// or surface a UI affordance (retry button etc.).
  final void Function(Object error)? onConnectFailed;

  /// Called after [autoConnect] fires and `session.connect()` completes
  /// without throwing. Transport-agnostic — fires for MSE (WS accepted),
  /// v1.3 (local no-op returns), and on-device (providers initialize).
  /// Use this to flip UI status → connected instead of gating on
  /// first-byte arrival, which is MSE-specific.
  final void Function()? onConnected;

  @override
  State<TwaiAvatarStage> createState() => _TwaiAvatarStageState();
}

class _TwaiAvatarStageState extends State<TwaiAvatarStage> {
  VideoSink? _sink;

  @override
  void initState() {
    super.initState();
    _wireUp();
  }

  Future<void> _wireUp() async {
    // Sink lifecycle: constructed once here, disposed in dispose().
    // Never expose to the caller — internal to the widget.
    final sink = widget.sinkFactory();
    try {
      await sink.attach(widget.session);
    } catch (e) {
      // Attach failure is unusual (sinks reject double-attach etc.)
      // but shouldn't crash the widget tree. Report + bail.
      if (mounted && widget.onConnectFailed != null) {
        widget.onConnectFailed!(e);
      }
      await sink.dispose();
      return;
    }
    if (!mounted) {
      await sink.dispose();
      return;
    }
    setState(() => _sink = sink);
    if (widget.autoConnect) {
      try {
        await widget.session.connect(widget.avatar);
        if (mounted && widget.onConnected != null) {
          widget.onConnected!();
        }
      } catch (e) {
        if (mounted && widget.onConnectFailed != null) {
          widget.onConnectFailed!(e);
        }
      }
    }
  }

  @override
  void dispose() {
    // Sink is ours — dispose it. Session is the caller's — leave alone.
    // ignore: discarded_futures
    _sink?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1 — customer's idle content. Always drawn.
        widget.idleSource.build(context),
        // Layer 2 — the sink. Transparent (SizedBox.expand default)
        // when idle, so Layer 1 shows through. Opaque with video
        // during conversation.
        if (_sink != null) _sink!.buildWidget(),
      ],
    );
  }
}
