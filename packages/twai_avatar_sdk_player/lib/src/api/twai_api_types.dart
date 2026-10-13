import '../progression.dart' show XpBand;

/// Response shape from `GET /api/gamification/progress/avatar/{slug}`.
/// Mirrors the reference `PetProgress` Pydantic schema at
/// `c:\Dev\clg_penthouse_pets\frontend\src\lean\controller.ts:441`.
///
/// Loaded once at connect + cached until the next `AwardMessageResponse`
/// updates the values in place.
class PetProgress {
  const PetProgress({
    required this.currentLevel,
    required this.currentXpInLevel,
    required this.xpRequiredToNext,
    required this.lifetimeXp,
    required this.messagesSent,
    required this.atCap,
    this.streakCount,
    this.streakLongest,
  });

  final int currentLevel;
  final int currentXpInLevel;

  /// XP required to reach the next level. `null` when the pet is at
  /// `level_cap` and no further progress is possible.
  final int? xpRequiredToNext;

  final int lifetimeXp;
  final int messagesSent;
  final bool atCap;
  final int? streakCount;
  final int? streakLongest;

  factory PetProgress.fromJson(Map<String, dynamic> json) => PetProgress(
        currentLevel: json['current_level'] as int,
        currentXpInLevel: json['current_xp_in_level'] as int,
        xpRequiredToNext: json['xp_required_to_next'] as int?,
        lifetimeXp: json['lifetime_xp'] as int,
        messagesSent: json['messages_sent'] as int,
        atCap: json['at_cap'] as bool,
        streakCount: json['streak_count'] as int?,
        streakLongest: json['streak_longest'] as int?,
      );
}

/// One reward unlocked by a level-up. The reference server hands these
/// back as part of `AwardMessageResponse.rewards_unlocked` when the
/// user crosses a level threshold.
class RewardUnlock {
  const RewardUnlock({
    required this.id,
    required this.type,
    required this.name,
    required this.assetReference,
    required this.level,
    this.thumbnailUrl,
  });

  final String id;

  /// `'outfit'` / `'emote'` / `'frame'` / `'kit'`. Wire is
  /// server-controlled; keep it as a raw string so new types don't
  /// crash the client on parse.
  final String type;

  final String name;
  final String assetReference;
  final int level;
  final String? thumbnailUrl;

  factory RewardUnlock.fromJson(Map<String, dynamic> json) => RewardUnlock(
        id: json['id'] as String,
        type: json['type'] as String,
        name: json['name'] as String,
        assetReference: json['asset_reference'] as String,
        level: json['level'] as int,
        thumbnailUrl: json['thumbnail_url'] as String?,
      );
}

/// Response shape from `POST /api/gamification/award-message`. Carries
/// **both** the XP delta AND the level-up trigger in one payload —
/// `leveled_up == true` means the client should render a level-up
/// modal.
///
/// Mirrors reference `XpEvent` at `controller.ts:424-439`. Renamed here
/// to `AwardMessageResponse` to disambiguate from our SDK-side
/// [XpEvent], which carries the display-ready subset the app renders.
class AwardMessageResponse {
  const AwardMessageResponse({
    required this.xpAwarded,
    required this.band,
    required this.qualityScore,
    required this.currentLevel,
    required this.currentXpInLevel,
    required this.xpRequiredToNext,
    required this.leveledUp,
    required this.rewardsUnlocked,
    required this.atCap,
    this.levelBefore,
    this.levelAfter,
    this.streakCount,
    this.streakMultiplier,
  });

  final int xpAwarded;
  final XpBand band;

  /// Server-side scoring metric (0.0–1.0 typically). Not rendered by
  /// the reference UI; kept for analytics.
  final num qualityScore;

  final int currentLevel;
  final int currentXpInLevel;
  final int? xpRequiredToNext;

  /// `true` when this XP award crossed a level threshold. Triggers
  /// the deferred level-up modal in the SDK's [levelUpEvents] stream.
  final bool leveledUp;

  final int? levelBefore;
  final int? levelAfter;
  final List<RewardUnlock> rewardsUnlocked;

  final bool atCap;
  final int? streakCount;
  final num? streakMultiplier;

  factory AwardMessageResponse.fromJson(Map<String, dynamic> json) {
    return AwardMessageResponse(
      xpAwarded: json['xp_awarded'] as int,
      band: switch (json['band'] as String) {
        'low' => XpBand.low,
        'medium' => XpBand.medium,
        'high' => XpBand.high,
        _ => XpBand.low, // unknown band → low (safe default)
      },
      qualityScore: json['quality_score'] as num,
      currentLevel: json['current_level'] as int,
      currentXpInLevel: json['current_xp_in_level'] as int,
      xpRequiredToNext: json['xp_required_to_next'] as int?,
      leveledUp: json['leveled_up'] as bool,
      levelBefore: json['level_before'] as int?,
      levelAfter: json['level_after'] as int?,
      rewardsUnlocked: (json['rewards_unlocked'] as List<dynamic>? ?? const [])
          .map((e) => RewardUnlock.fromJson(e as Map<String, dynamic>))
          .toList(),
      atCap: json['at_cap'] as bool,
      streakCount: json['streak_count'] as int?,
      streakMultiplier: json['streak_multiplier'] as num?,
    );
  }
}
