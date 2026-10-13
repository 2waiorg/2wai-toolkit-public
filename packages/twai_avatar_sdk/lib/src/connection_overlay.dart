import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// Wraps a live-avatar widget with status-aware overlays — a
/// [connectingBuilder] shown while the controller is still opening
/// its transport, and a [failedBuilder] shown after a terminal
/// failure. Both slots are opt-in; leaving one null hides the
/// corresponding overlay.
///
/// The overlay auto-hides once status reaches [PlayerStatus.ready]
/// or [PlayerStatus.speaking] (the "avatar is live" states). Ports
/// 2wai-edu's DemoAvatarDisplay connecting-overlay pattern
/// ([DemoAvatarDisplay.vue:15-46](../../../../2wai-edu/components/scopes/chat/DemoAvatarDisplay.vue))
/// into an SDK-level primitive so every app doesn't rebuild this.
///
/// # Example — spinner + tap-to-retry
///
/// ```dart
/// TwaiConnectionOverlay(
///   controller: handle.controller,
///   connectingBuilder: (ctx) => const Center(
///     child: Column(
///       mainAxisSize: MainAxisSize.min,
///       children: [
///         CircularProgressIndicator(),
///         SizedBox(height: 12),
///         Text('Connecting to Krystal…'),
///       ],
///     ),
///   ),
///   failedBuilder: (ctx, cause) => Center(
///     child: Column(
///       mainAxisSize: MainAxisSize.min,
///       children: [
///         const Icon(Icons.error_outline, size: 48),
///         const SizedBox(height: 8),
///         Text('Connection failed: $cause'),
///         TextButton(
///           onPressed: handle.manualReconnect,
///           child: const Text('Tap to retry'),
///         ),
///       ],
///     ),
///   ),
///   child: TwaiPlayer(controller: handle, avatar: krystal),
/// )
/// ```
///
/// # Why not fold into TwaiPlayer directly?
///
/// [TwaiPlayer] is the "just show the avatar" primitive; adding
/// connecting-state UI to it would force every consumer to opt out
/// of ceremony they may not want. This composable is the opt-in.
class TwaiConnectionOverlay extends StatefulWidget {
  const TwaiConnectionOverlay({
    super.key,
    required this.controller,
    required this.child,
    this.connectingBuilder,
    this.failedBuilder,
    this.background = const Color(0xB3000000),
  });

  /// The controller whose status stream drives the overlay. Accept
  /// either the raw controller (`handle.controller`) or from any
  /// [TwaiPlayerHandle] the app already has.
  final TwaiAvatarPlayerController controller;

  /// Live-avatar widget — typically [TwaiPlayer], [TwaiAvatarPlayerStage],
  /// or a custom composition. Always mounted; overlays paint on top
  /// via a [Stack].
  final Widget child;

  /// Builder invoked when status is [PlayerStatus.connecting] and
  /// not-yet-ready. Null → no connecting overlay (status change is
  /// silent, child is visible immediately).
  final WidgetBuilder? connectingBuilder;

  /// Builder invoked when status is [PlayerStatus.failed]. Receives
  /// the underlying [PlayerStatusEvent.cause] when known so error
  /// text can be specific ("Timed out", "Handshake rejected", etc.).
  /// Null → no failure overlay (child stays visible in its last state).
  final Widget Function(BuildContext, Object? cause)? failedBuilder;

  /// Optional background painted behind the overlay content. Default
  /// 70% opaque black — enough to darken the child underneath
  /// without hiding it entirely.
  final Color background;

  @override
  State<TwaiConnectionOverlay> createState() =>
      _TwaiConnectionOverlayState();
}

class _TwaiConnectionOverlayState extends State<TwaiConnectionOverlay> {
  StreamSubscription<PlayerStatusEvent>? _sub;
  PlayerStatus _status = PlayerStatus.connecting;
  Object? _cause;

  @override
  void initState() {
    super.initState();
    _status = widget.controller.currentStatus;
    _sub = widget.controller.status.listen(_onStatus);
  }

  @override
  void didUpdateWidget(covariant TwaiConnectionOverlay old) {
    super.didUpdateWidget(old);
    if (widget.controller != old.controller) {
      _sub?.cancel();
      _status = widget.controller.currentStatus;
      _sub = widget.controller.status.listen(_onStatus);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onStatus(PlayerStatusEvent ev) {
    if (!mounted) return;
    setState(() {
      _status = ev.status;
      _cause = ev.cause;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget? overlay;
    switch (_status) {
      case PlayerStatus.connecting:
        overlay = widget.connectingBuilder?.call(context);
      case PlayerStatus.failed:
        overlay = widget.failedBuilder?.call(context, _cause);
      case PlayerStatus.ready:
      case PlayerStatus.speaking:
        overlay = null;
    }
    if (overlay == null) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        ColoredBox(color: widget.background, child: overlay),
      ],
    );
  }
}
