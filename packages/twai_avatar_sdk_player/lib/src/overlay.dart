/// Overlay-playback orchestration types.
///
/// The reference player renders a THIRD video element (`emoteVid`)
/// stacked between the idle and live layers for short clip overlays:
///
/// - **Gestures** (emotes) — 1–3s muted clips (`wave`, `kiss`,
///   `heart-hands`, etc). Triggered by user tap. Live audio is muted
///   during playback so the two clips don't fight.
/// - **Frames** — 5–10s outfit-scoped clips with sound. Longer,
///   narrative-flavored. Live audio muted.
/// - **Transitions** — 1.5–4s bridges between outfit swaps. Silent.
/// - **Greetings** — pre-rendered opening clips for return visits.
///
/// The SDK player owns the *event dispatch* — the app tells the
/// controller "play this URL," the controller emits an
/// [OverlayEvent] on [overlayEvents], and the app renders the actual
/// video element (the sink pane, an overlay widget, whatever). When
/// playback finishes the app calls
/// [TwaiAvatarPlayerController.notifyOverlayEnded] and the controller
/// clears its `isOverlayPlaying` flag.
///
/// Ports the mechanism-agnostic part of port spec §2.6 / §7. The
/// mute/unmute discipline against the live audio is exposed as
/// [OverlayEvent.muteLive] so the app knows what to do.
library;

/// What kind of overlay is being played. Drives the muting default +
/// analytics event names.
enum OverlayKind {
  /// A short muted expression clip (`emoteVid` in the reference).
  gesture,

  /// A longer per-outfit clip with sound.
  frame,

  /// An outfit-swap bridge.
  transition,

  /// A pre-rendered greeting clip.
  greeting,
}

/// A single overlay-play request emitted on
/// [TwaiAvatarPlayerController.overlayEvents]. The app subscribes and
/// renders playback of [url] in its overlay widget.
class OverlayEvent {
  const OverlayEvent({
    required this.kind,
    required this.url,
    required this.muteLive,
    this.id,
    this.slug,
  });

  /// Classification of the clip.
  final OverlayKind kind;

  /// MP4 URL the app plays.
  final String url;

  /// Whether the app should mute the live-video audio track while
  /// this overlay plays. Reference behavior:
  /// - `gesture` → muted (silent clips fighting live audio confuses)
  /// - `frame` → NOT muted (frames have their own audio track)
  /// - `transition` → muted
  /// - `greeting` → app decides — reference plays with sound
  final bool muteLive;

  /// Server-side identifier of the clip (for analytics beacons).
  final String? id;

  /// Human-readable slug (`'wave'`, `'kiss'`, etc). Analytics.
  final String? slug;

  @override
  String toString() =>
      'OverlayEvent(${kind.name}, ${slug ?? id ?? '?'}, muteLive=$muteLive)';
}
