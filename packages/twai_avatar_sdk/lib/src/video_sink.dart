import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

/// Renders avatar video from a [ChatSession]'s `videoBytes` stream.
///
/// One sink per session. The sink owns its rendering resources
/// (controllers, temp files, native surfaces) and releases them via
/// [dispose].
///
/// Concrete implementations:
/// - `PipelineV13VideoSink` — `package:video_player` backed sink for
///   Adapter 2 (one complete MP4 per turn).
/// - (Future) `MseStreamVideoSink` — MediaSource / WebView-backed sink
///   for Adapter 1 (fragmented MP4 over WS).
abstract class VideoSink {
  /// Subscribe to [session]'s `videoBytes` (and optionally
  /// `speakingEvents`) and start rendering. Calling [attach] more than
  /// once is implementation-defined — most sinks will reject it.
  Future<void> attach(ChatSession session);

  /// Build the widget that displays the avatar. Safe to call before
  /// [attach] — the widget should render a "waiting" placeholder until
  /// the first video chunk arrives.
  Widget buildWidget();

  /// Cancel subscriptions, dispose controllers, delete temp files.
  Future<void> dispose();

  /// True while the sink is actively rendering a decoded avatar frame
  /// on-screen — used by the composition layer (e.g.
  /// [TwaiAvatarPlayerStage]) to keep the sink widget visible past the
  /// `speaking:stop` event.
  ///
  /// # Why this exists
  ///
  /// The default stage gates the sink's widget behind an
  /// AnimatedOpacity tied to `PlayerStatus.speaking`, which fits the
  /// web-MSE sink (tail-follows into a live SourceBuffer — visible only
  /// during the speaking window). But accumulate-then-play sinks
  /// (`VideoPlayerMseStreamSink`, `MediaKitMseStreamSink`) can't seal
  /// their MP4 until AFTER `speaking:stop`, so they start rendering the
  /// sealed clip AFTER the controller has already returned to `ready`
  /// — the widget's opacity is already fading to 0, and the decoded
  /// video renders into an invisible surface. Audio still plays (audio
  /// path doesn't route through the Opacity widget) but the user sees
  /// only idle.
  ///
  /// Sinks that self-gate visibility (know when they have content to
  /// display) should return a `ValueListenable<bool>` that flips true
  /// on first frame + false when playback ends. The stage OR-combines
  /// this with the speaking flag so the sink stays visible for the
  /// full duration of any sealed clip.
  ///
  /// Default: an always-false listenable. Sinks that don't need
  /// self-gating (web MSE tail-follow) inherit this — stage falls back
  /// to speaking-status gating alone, unchanged from before.
  ValueListenable<bool> get isRenderingContent => alwaysNotRendering;
}

/// Shared always-false [ValueListenable] for sinks that don't self-gate
/// visibility. Single instance reused across all such sinks so we don't
/// leak per-sink notifiers for the common case. Immutable at runtime —
/// nobody is expected to call `.value = true` on this.
final ValueListenable<bool> alwaysNotRendering = ValueNotifier<bool>(false);
