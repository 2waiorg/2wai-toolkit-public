/// Typed representation of the brain-emitted mood for an Adapter-1
/// chat turn.
///
/// Source of truth: `2waiorg/avatar-brain/src/core/mood/roster.py`
/// (the locked vocabulary, 2026-06-25 + 2026-06-26 per-avatar registry
/// landing) plus `clg_penthouse_pets/.../main_service/pipeline/handlers/`
/// `chat.py:262-291` which echoes the brain's SSE `event: mood` frame
/// as two response headers on `POST /ext-api/human`:
///
/// - `X-Mood: <slug>` — one of the values in [Mood]'s enum below.
/// - `X-Mood-Humanized: <text>` — per-avatar tooltip like
///   "Sophi is feeling good"; per-avatar mapping lives in the brain's
///   `<AVATAR>_TOOLTIP_NAMES` dict and is intentionally NOT closed-set.
///
/// The slug set is closed and shared across every avatar in the brain
/// roster (Sophi, Bella Reid, Bella Vaunt, Krystal Harper, Tahlia Paris,
/// + every future avatar — same 9 slugs). The humanized text is open
/// and per-avatar; we pass it through as a raw string.

/// The closed slug vocabulary the brain mood roster emits.
///
/// Includes [Mood.unknown] as a forward-compat slot — when Alex adds a
/// new mood to the brain (e.g. for a new persona class), older SDK
/// versions still parse cleanly: [MoodEvent.slug] preserves the exact
/// wire string so customer code can branch on it.
///
/// Slug references (from `avatar-brain/src/core/mood/roster.py` as of
/// 2026-06-27):
/// - **Daily-roll moods** (rolled deterministically once per UTC day):
///   `warm-curious`, `dry-teasing`, `hyped`, `frisky`, `soft-quiet`,
///   `off-her-game`, `homesick`.
/// - **Transient moods** (not in the daily roll):
///   - `afterglow` — post-roleplay window; emitted via state.py only.
///   - `mad` — user-triggered (sustained cruelty / coldness); sticky
///     across sessions via grudge marker in state.py.
enum Mood {
  warmCurious('warm-curious'),
  dryTeasing('dry-teasing'),
  hyped('hyped'),
  frisky('frisky'),
  softQuiet('soft-quiet'),
  offHerGame('off-her-game'),
  homesick('homesick'),
  afterglow('afterglow'),
  mad('mad'),

  /// Wire slug didn't match any known [Mood] — usually means the brain
  /// shipped a new mood the SDK version doesn't recognize yet.
  /// [MoodEvent.slug] preserves the actual wire string so callers can
  /// still branch / log the new value.
  unknown('');

  const Mood(this.slug);

  /// Wire-format slug, exactly as the brain emits it via `X-Mood`.
  /// `''` for [Mood.unknown].
  final String slug;

  /// Parse a wire slug into a [Mood]. Unknown slugs map to
  /// [Mood.unknown] (forward-compat — never throws).
  static Mood parse(String slug) {
    for (final m in Mood.values) {
      if (m.slug == slug) return m;
    }
    return Mood.unknown;
  }
}

/// One mood update from the brain — what arrived on the `X-Mood` +
/// `X-Mood-Humanized` response headers for the most recent
/// `sendMessage` turn.
///
/// Customer UI typically wires off one of two surfaces:
/// - [mood] — typed enum, drives switch statements for icons / colors /
///   poses / backgrounds.
/// - [humanized] — per-avatar tooltip ready to render as-is ("Sophi is
///   feeling good"). Will be `null` when the server didn't echo one
///   (mood off, no humanized mapping for this avatar, etc.).
///
/// [slug] preserves the raw wire value — useful when [mood] is
/// [Mood.unknown] (so customer code can still log / branch / forward).
class MoodEvent {
  /// Typed mood. [Mood.unknown] when the wire slug wasn't recognized
  /// by this SDK version — check [slug] for the raw value in that case.
  final Mood mood;

  /// Raw wire slug from the `X-Mood` response header. Preserved verbatim
  /// so callers can handle moods the SDK doesn't yet have an enum entry
  /// for. Always populated (an empty wire value never reaches MoodEvent
  /// — the gateway filters those to null).
  final String slug;

  /// Per-avatar tooltip text from the `X-Mood-Humanized` response header
  /// (e.g. `"Sophi is feeling good"`). `null` when the server didn't
  /// echo one — render fallback / hide the tooltip.
  final String? humanized;

  const MoodEvent({
    required this.mood,
    required this.slug,
    this.humanized,
  });

  /// Build a [MoodEvent] from the two captured headers. Returns `null`
  /// when [slug] is null/empty (no mood for this turn).
  static MoodEvent? fromHeaders({
    required String? slug,
    required String? humanized,
  }) {
    if (slug == null || slug.isEmpty) return null;
    final normalizedHumanized =
        (humanized != null && humanized.isNotEmpty) ? humanized : null;
    return MoodEvent(
      mood: Mood.parse(slug),
      slug: slug,
      humanized: normalizedHumanized,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MoodEvent &&
      other.mood == mood &&
      other.slug == slug &&
      other.humanized == humanized;

  @override
  int get hashCode => Object.hash(mood, slug, humanized);

  @override
  String toString() =>
      'MoodEvent(mood=$mood, slug=$slug, humanized=$humanized)';
}
