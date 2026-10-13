import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

import 'avatar_idle_source.dart';
import 'video_sink.dart';

/// Widget that composes a [TwaiAvatarPlayerController] + [VideoSink] +
/// [AvatarIdleSource] into a full avatar pane matching the reference
/// player's layering.
///
/// # Layering (bottom → top)
///
/// 1. **Idle layer** — [idleSource].build(). Always drawn. Typically a
///    looping outfit idle video or a poster image.
/// 2. **Live layer** — [sink].buildWidget() wrapped in [AnimatedOpacity].
///    Faded IN when [controller.status] transitions to
///    [PlayerStatus.speaking], faded OUT otherwise. Between turns the
///    sink stays mounted (so its SourceBuffer keeps consuming bytes),
///    but its widget is transparent so the idle layer shows through.
///
/// # Controller-flavored counterpart to [TwaiAvatarStage]
///
/// Where [TwaiAvatarStage] takes a [ChatSession] and owns the sink
/// lifecycle internally, this widget takes a pre-built controller +
/// sink and just renders them. The inversion is because the new player
/// is session-agnostic — sessions rotate transparently under the
/// controller, so the sink lifecycle exceeds any one session's.
///
/// # Ownership
///
/// The caller owns both [controller] and [sink]. Their `dispose()` is
/// **not** called when this widget unmounts. The app decides when to
/// tear them down (typically on profile-swap or app-dispose). This
/// matches how the reference controller and sink outlive their widget
/// hosting.
class TwaiAvatarPlayerStage extends StatefulWidget {
  const TwaiAvatarPlayerStage({
    required this.controller,
    required this.sink,
    this.idleSource = const NoIdle(),
    this.fadeDuration = const Duration(milliseconds: 200),
    super.key,
  });

  /// The player controller whose status drives idle↔speaking
  /// transitions and whose broadcast streams feed the [sink].
  final TwaiAvatarPlayerController controller;

  /// The live-video sink. On Flutter web this is typically a
  /// `WebMseStreamSink`; on other platforms the app supplies a
  /// bridge / fallback sink.
  final VideoSink sink;

  /// Content behind the sink. Renders during idle time. Default
  /// [NoIdle] draws nothing — the customer's scaffold background
  /// shows through.
  final AvatarIdleSource idleSource;

  /// How long the sink's opacity transition takes between
  /// idle↔speaking. 200ms feels natural without being sluggish.
  final Duration fadeDuration;

  @override
  State<TwaiAvatarPlayerStage> createState() =>
      _TwaiAvatarPlayerStageState();
}

class _TwaiAvatarPlayerStageState extends State<TwaiAvatarPlayerStage> {
  StreamSubscription<PlayerStatusEvent>? _statusSub;
  bool _showLive = false;

  @override
  void initState() {
    super.initState();
    // Prime from current controller state — if we're wired to a
    // controller that's already mid-session, we shouldn't have to
    // wait for a transition to see the correct visual.
    _showLive =
        widget.controller.currentStatus == PlayerStatus.speaking;
    _statusSub = widget.controller.status.listen(_onStatus);
  }

  @override
  void didUpdateWidget(covariant TwaiAvatarPlayerStage old) {
    super.didUpdateWidget(old);
    if (widget.controller != old.controller) {
      _statusSub?.cancel();
      _statusSub = widget.controller.status.listen(_onStatus);
      _showLive =
          widget.controller.currentStatus == PlayerStatus.speaking;
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  void _onStatus(PlayerStatusEvent ev) {
    final showLive = ev.status == PlayerStatus.speaking;
    if (showLive != _showLive && mounted) {
      setState(() => _showLive = showLive);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Idle layer — always drawn. When the sink's opacity is 0,
        // this is what the user sees.
        widget.idleSource.build(context),
        // Live layer — sink widget with animated opacity. Sink stays
        // mounted so its SourceBuffer keeps consuming bytes across
        // the idle↔speaking flip; only visibility changes.
        //
        // PORT NOTE (2026-07-20): Reference uses `emoteVid.dataset
        // .active = '0'/'1'` toggled from JS + CSS transitions on
        // the always-present `<video>` element. Same outcome (video
        // fades in/out on speaking, element stays mounted), different
        // mechanism because Flutter doesn't have that CSS/DOM path.
        // AnimatedOpacity around HtmlElementView (or any VideoSink
        // widget) is the Flutter-idiomatic equivalent.
        // Sink is visible when EITHER the controller reports the
        // pipeline is speaking (continuous-stream sinks like
        // WebMseStreamSink need this) OR the sink itself reports it
        // has decoded content to display (accumulate-then-play sinks
        // like VideoPlayerMseStreamSink need this — they seal + play
        // AFTER speaking:stop and the controller has already flipped
        // back to `ready`). The OR keeps both classes of sink working
        // without either overriding the other.
        ValueListenableBuilder<bool>(
          valueListenable: widget.sink.isRenderingContent,
          builder: (context, sinkRendering, _) {
            return AnimatedOpacity(
              opacity: (_showLive || sinkRendering) ? 1.0 : 0.0,
              duration: widget.fadeDuration,
              child: widget.sink.buildWidget(),
            );
          },
        ),
      ],
    );
  }
}
