/// Progression events — XP awards + level-ups — with the SDK-level
/// discipline the reference player enforces:
///
/// - Both event types **defer while the avatar is speaking**. XP
///   toasts and level-up modals appearing mid-speech would compete
///   with the reply for user attention; the reference queues them
///   until `setLive(false)` (our [PlayerStatus.ready] transition).
/// - Deferred events have a max-defer cap of
///   [PlayerConfig.pendingLevelUpMaxDelay] (default 20s) — if the
///   user goes back into speech before the queue drains, or the
///   status transition lags, we don't fire stale toasts / modals.
///
/// The controller is **stateless** with respect to level/XP values.
/// The app is authoritative on server-derived progression state; the
/// controller only defers, drops-if-stale, and dispatches the events
/// the app hands it. Port spec §11 ("Additional features NOT on
/// Mason's whiteboard") for the full behavioural spec.
library;

/// The XP-value bucket the reference uses for toast styling. The
/// three bands map to different toast visuals (color / prominence /
/// duration) in the production UI. Server-provided; the SDK doesn't
/// classify amounts locally.
enum XpBand {
  /// Small award (e.g. sending a message).
  low,

  /// Mid-tier award (e.g. reaching a scenario milestone).
  medium,

  /// Big award (e.g. crossing a level threshold, unlock trigger).
  high,
}

/// An XP award. The SDK carries these through
/// [TwaiAvatarPlayerController.xpEvents], queued while the avatar is
/// speaking and drained on the next [PlayerStatus.ready] transition.
class XpEvent {
  const XpEvent({
    required this.amount,
    required this.band,
    required this.timestamp,
    this.reason,
  });

  /// Positive XP delta (server-computed).
  final int amount;

  /// Server-provided styling band.
  final XpBand band;

  /// When the SDK first saw this event (via [awardXp]). Used
  /// internally to drop stale queued events after
  /// [PlayerConfig.pendingLevelUpMaxDelay]; consumers can also render
  /// it (e.g. "12 XP · 3s ago").
  final DateTime timestamp;

  /// Optional server-provided reason string ("first message of the
  /// day", "kit unlock", etc). Not shown by the reference UI; kept
  /// for analytics / debugging.
  final String? reason;

  @override
  String toString() =>
      'XpEvent(+$amount, band=${band.name}${reason == null ? '' : ', reason=$reason'})';
}

/// A level threshold crossing. Carries whatever metadata the app
/// wants to render in its level-up modal (the reference UI shows a
/// reward thumbnail + CTA + "n/total" session-progress line).
class LevelUpEvent {
  const LevelUpEvent({
    required this.newLevel,
    required this.timestamp,
    this.previousLevel,
    this.rewardTitle,
    this.rewardThumbnailUrl,
    this.sessionLevelUpIndex,
    this.sessionLevelUpTotal,
  });

  /// The level the user just reached.
  final int newLevel;

  /// The level they crossed from, if the app knows it.
  final int? previousLevel;

  /// When the SDK first saw this event.
  final DateTime timestamp;

  /// Optional title for the reward panel ("Bikini outfit unlocked",
  /// "New emote: heart-hands"). App renders as it wishes.
  final String? rewardTitle;

  /// Optional thumbnail URL for the reward preview.
  final String? rewardThumbnailUrl;

  /// If the app tracks per-session level-up progress, the index of
  /// this event (1-based). Powers the "1/20 level ups this session"
  /// line the reference modal shows.
  final int? sessionLevelUpIndex;

  /// Total expected level-ups this session (if known).
  final int? sessionLevelUpTotal;

  @override
  String toString() => 'LevelUpEvent(→L$newLevel'
      '${previousLevel == null ? '' : ' from L$previousLevel'}'
      '${rewardTitle == null ? '' : ', reward="$rewardTitle"'})';
}
