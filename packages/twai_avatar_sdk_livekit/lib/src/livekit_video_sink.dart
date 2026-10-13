/// [VideoSink] that renders a LiveKit remote video track instead of an
/// fMP4 stream.
///
/// LiveKit owns the decoder + renderer end-to-end via WebRTC. The
/// [VideoSink] interface asks for a `Widget buildWidget()` — we return
/// [lk.VideoTrackRenderer] pointed at whichever track the
/// [LiveKitChatSession] currently has subscribed. The `videoBytes`
/// stream on the session is deliberately empty (LiveKit doesn't hand
/// us fMP4 bytes to append), so we ignore [ChatSession.videoBytes] and
/// subscribe to the LiveKit-specific `videoTrackStream` instead.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import 'livekit_chat_session.dart';

/// Renders whichever agent video track the current [LiveKitChatSession]
/// holds in its `videoTrack` state slot.
///
/// Same discipline as Mason's JS engine + avatar-player: the session
/// owns the current-track reference, the consumer's render surface is
/// bound to it directly. Here that means wrapping `session.videoTrack`
/// (a [ValueListenable]) with a [ValueListenableBuilder] around a
/// [lk.VideoTrackRenderer]. The widget always exists, always reflects
/// the current track. No stream subscription, no race window between
/// the sink binding and `TrackSubscribedEvent` firing.
class LiveKitVideoSink implements VideoSink {
  /// The controller is the only path back to the live
  /// [LiveKitChatSession]. `TwaiPlayer.attach()` hands us a private
  /// `_ControllerFeedShim` that only exposes
  /// `videoBytes`/`speakingEvents`/`speakBoundaries` — it strips the
  /// WebRTC-specific `videoTrack` slot the renderer needs. So we
  /// bypass the shim and read `controller.currentSession` directly,
  /// rebinding on every status transition (reconnects rotate the
  /// session instance).
  LiveKitVideoSink({required this.controller});

  final TwaiAvatarPlayerController controller;

  // LiveKit video is a CONTINUOUS WebRTC track — once subscribed
  // (typically ~4s after connect) it keeps sending frames until the
  // session ends, whether the agent is speaking or idle. That is the
  // opposite of the accumulate-then-play MSE sinks the stage's
  // `sinkRendering || _showLive` OR gate was written for. If we set
  // `isRenderingContent = true` whenever a track is bound, the OR
  // pins sink opacity to 1 for the whole session, the idle layer
  // never re-appears between turns, and the agent's continuous
  // stream looks like "he never stops talking." Constant `false`
  // here delegates visibility entirely to `_showLive` (which
  // follows the `livealman` speaking events), matching Mason's
  // engine — that never hides its video element and expects the
  // speaking signal to be the sole visibility cue.
  static final ValueNotifier<bool> _neverRenders = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get isRenderingContent => _neverRenders;

  @override
  Widget buildWidget() => _LiveKitTrackView(sinkController: controller);

  @override
  Future<void> attach(ChatSession session) async {
    // The `session` argument is the shim, not our LK session. We do
    // not need to bind anything: the widget reads currentSession
    // from the controller on every rebuild via StreamBuilder(status).
  }

  @override
  Future<void> dispose() async {
    // Stateless sink — nothing to tear down.
  }
}

class _LiveKitTrackView extends StatelessWidget {
  const _LiveKitTrackView({required this.sinkController});
  final TwaiAvatarPlayerController sinkController;

  @override
  Widget build(BuildContext context) {
    // The bound session's identity can rotate under us (reconnect);
    // rebuild on every controller status event so we read the
    // latest currentSession, then wire the renderer against THAT
    // session's videoTrack listenable.
    return StreamBuilder<PlayerStatusEvent>(
      stream: sinkController.status,
      builder: (context, _) {
        final s = sinkController.currentSession;
        if (s is! LiveKitChatSession) return const SizedBox.expand();
        return ValueListenableBuilder<lk.RemoteVideoTrack?>(
          valueListenable: s.videoTrack,
          builder: (context, track, _) {
            if (track == null) return const SizedBox.expand();
            // fit: contain preserves the 9:16 portrait; the stage's
            // AspectRatio wrapper handles letterboxing on landscape.
            return lk.VideoTrackRenderer(
              track,
              fit: lk.VideoViewFit.contain,
              mirrorMode: lk.VideoViewMirrorMode.off,
            );
          },
        );
      },
    );
  }
}
