import 'overlay.dart';
import 'player_controller.dart';

/// One expression / emote clip attached to an avatar. Short (1–3s),
/// muted-on-playback, seams to `defaultIdleUrl` on completion.
///
/// **Mirrors the reference `Gesture` type** from
/// `c:\Dev\clg_penthouse_pets\frontend\src\lean\controller.ts` +
/// `/ext-api/gestures/{slug}` server contract. See port spec §4.8 and
/// `docs/avatar_input_spec.md` §4.1 for the artifact contract.
///
/// [outfitSlug] semantics:
/// - `null` — this gesture is shared across all outfits of its avatar.
///   The overlay video should look outfit-neutral (e.g. face-only).
/// - non-null — only render this gesture when its owning outfit is
///   the active one. The overlay video is authored to match that
///   outfit's appearance.
///
/// [isUnlocked] is decided by the backend based on the caller's tier
/// + level + kit ownership. The SDK does not compute unlock state
/// locally — it just renders what the server sends.
class PlayerGesture {
  const PlayerGesture({
    required this.id,
    required this.slug,
    required this.displayName,
    required this.videoUrl,
    required this.isUnlocked,
    this.thumbnailUrl,
    this.unlockLevel,
    this.outfitSlug,
  });

  /// Server-side identifier (opaque UUID or similar).
  final String id;

  /// Stable slug (e.g. `'wave'`, `'kiss'`, `'heart-hands'`).
  final String slug;

  /// Human-visible name for panel tiles (e.g. `'Blows Kiss'`).
  final String displayName;

  /// MP4 URL. 1–3s typical, muted playback, seam-authored to
  /// `defaultIdleUrl` frame 0.
  final String videoUrl;

  /// Optional thumbnail for the panel tile. `null` → the panel
  /// renders a text-only tile.
  final String? thumbnailUrl;

  /// Whether the current user is allowed to trigger this gesture.
  /// Comes from the backend based on tier + level + kit ownership.
  final bool isUnlocked;

  /// Optional display-only level requirement — shown as a badge on
  /// locked tiles. Backend still owns actual gating via [isUnlocked].
  final int? unlockLevel;

  /// Optional per-outfit restriction — see class-level docstring.
  final String? outfitSlug;
}

/// One frame clip attached to an avatar's outfit. Longer than a
/// gesture (5–10s), plays with sound, always outfit-scoped.
///
/// **Mirrors the reference `Frame` type** from
/// `/ext-api/frames/{slug}` server contract. Port spec §4.9 and
/// `docs/avatar_input_spec.md` §4.2.
///
/// Distinct from [PlayerGesture]:
/// - Longer clips (5–10s vs 1–3s)
/// - Plays with sound (gesture is muted)
/// - Always outfit-scoped ([outfitSlug] is required, not nullable)
/// - Often themed / narrative (e.g. "beach walk", "coffee")
class PlayerFrame {
  const PlayerFrame({
    required this.id,
    required this.slug,
    required this.frameNumber,
    required this.outfitSlug,
    required this.unlockLevel,
    required this.mainClipUrl,
    required this.isUnlocked,
    this.thumbnailUrl,
  });

  /// Server-side identifier.
  final String id;

  /// Stable slug.
  final String slug;

  /// Ordering / position within the outfit's frame set. Zero-based.
  final int frameNumber;

  /// Which outfit this frame belongs to. Required — frames don't
  /// float across outfits.
  final String outfitSlug;

  /// Display-only level requirement. Backend owns actual gating.
  final int unlockLevel;

  /// MP4 URL. 5–10s typical, plays with sound.
  final String mainClipUrl;

  /// Optional thumbnail for the panel tile.
  final String? thumbnailUrl;

  /// Whether the current user is allowed to trigger this frame.
  final bool isUnlocked;
}

/// Filter a gesture list to those valid for the current outfit and
/// (optionally) the caller's unlock state.
///
/// A gesture matches when:
/// - Its [PlayerGesture.outfitSlug] is `null` (shared across all
///   outfits) OR matches [outfitSlug]
/// - AND when [unlockedOnly] is true, [PlayerGesture.isUnlocked] is
///   `true`
///
/// Pass [outfitSlug] `null` to get gestures usable across every
/// outfit (i.e. only the shared / outfit-neutral ones).
Iterable<PlayerGesture> filterGestures(
  Iterable<PlayerGesture> gestures, {
  required String? outfitSlug,
  bool unlockedOnly = false,
}) {
  return gestures.where((g) {
    if (g.outfitSlug != null && g.outfitSlug != outfitSlug) return false;
    if (unlockedOnly && !g.isUnlocked) return false;
    return true;
  });
}

/// Filter a frame list to those belonging to the given outfit and
/// (optionally) the caller's unlock state.
///
/// A frame matches when [PlayerFrame.outfitSlug] matches [outfitSlug]
/// exactly. Frames don't have a "shared across outfits" concept —
/// they always belong to one outfit.
Iterable<PlayerFrame> filterFrames(
  Iterable<PlayerFrame> frames, {
  required String outfitSlug,
  bool unlockedOnly = false,
}) {
  return frames.where((f) {
    if (f.outfitSlug != outfitSlug) return false;
    if (unlockedOnly && !f.isUnlocked) return false;
    return true;
  });
}

/// Opt-in composition helpers on [TwaiAvatarPlayerController] for
/// apps that use the [PlayerGesture] / [PlayerFrame] content-layer
/// types. Extension methods are compile-time only, so apps that
/// never use gestures/frames never pay any cost.
///
/// Both helpers forward to [TwaiAvatarPlayerController.playOverlay]
/// with the muting defaults port spec §2.6 documents:
/// - Gestures play muted (short, no audio track worth playing)
/// - Frames play with sound (their own audio matters)
extension GestureAwareController on TwaiAvatarPlayerController {
  /// Play a [PlayerGesture] as an overlay. Mutes the live audio for
  /// the duration.
  void playGesture(PlayerGesture gesture) {
    playOverlay(
      kind: OverlayKind.gesture,
      url: gesture.videoUrl,
      muteLive: true,
      id: gesture.id,
      slug: gesture.slug,
    );
  }

  /// Play a [PlayerFrame] as an overlay. Frames have their own audio
  /// — the live audio is NOT muted.
  void playFrame(PlayerFrame frame) {
    playOverlay(
      kind: OverlayKind.frame,
      url: frame.mainClipUrl,
      muteLive: false,
      id: frame.id,
      slug: frame.slug,
    );
  }
}
