import 'dart:convert';
import 'dart:typed_data';

/// Types modeling the penthouse TTS pronunciation rules engine.
///
/// Mirrors the v2 schema documented in `clg_penthouse_pets/docs/TTS_RULES.md`
/// on the `mason/tts-global-pronunciation` branch. The engine runs two
/// stages — `brain_normalize` (in main_service before the LLM output
/// leaves) and `tts_prepass` (in inference_service before POST to Qwen3).
/// Each stage executes an ordered list of "passes," scoped by
/// `global` / `app:<id>` / `avatar:<id>` and optionally filtered by
/// language. The SDK surface here lets a customer manage their tenant's
/// rules without ever editing `tts_rules.json` directly.
///
/// > **Backend status (2026-06-27):** the schema below is stable on
/// > penthouse (used in production); the REST endpoints
/// > (`POST /ext-api/tts/rules` etc.) the SDK calls below are NOT yet
/// > exposed by `main_service`. Mason's backend has only
/// > `GET /api/tts/rules` (for the VM cron poll). Until the admin
/// > endpoints land, [AvatarAdminClient.listRules] /
/// > [AvatarAdminClient.addRule] / etc. will return 404. The SDK shape
/// > is in place so customer code + admin UI (SDK-29) can be written
/// > against the contract.

// ── Scope ────────────────────────────────────────────────────────────────────

/// One of the three scope buckets the rules engine recognizes:
///
/// - `global` — applies to every request.
/// - `app:<id>` — applies only when `app=<id>` is passed at the call site
///   (typically a tenant id; e.g. `app:penthouse-pets`).
/// - `avatar:<id>` — applies only when `avatar=<id>` is passed (e.g.
///   `avatar:krystal-harper`).
///
/// Precedence at runtime: passes from each scope are concatenated in
/// `global → app → avatar` order, and later passes win on conflicts.
class TtsRuleScope {
  const TtsRuleScope._(this.value);

  /// The wire-format value, e.g. `'global'`, `'app:foo'`, `'avatar:bar'`.
  final String value;

  /// Global rules — apply to every request regardless of tenant or avatar.
  static const TtsRuleScope global = TtsRuleScope._('global');

  /// Rules scoped to one application/tenant. The id is opaque to the SDK
  /// — penthouse uses `penthouse-pets`; SDK customers would use their
  /// own tenant id.
  factory TtsRuleScope.app(String id) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'app scope id must not be empty');
    }
    if (id.contains(':')) {
      throw ArgumentError.value(id, 'id', 'app scope id must not contain ":"');
    }
    return TtsRuleScope._('app:$id');
  }

  /// Rules scoped to one avatar id.
  factory TtsRuleScope.avatar(String id) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'avatar scope id must not be empty');
    }
    if (id.contains(':')) {
      throw ArgumentError.value(
          id, 'id', 'avatar scope id must not contain ":"');
    }
    return TtsRuleScope._('avatar:$id');
  }

  /// Parse from the wire-format string (`'global'`, `'app:foo'`, …).
  /// Throws [FormatException] on unrecognized shapes.
  factory TtsRuleScope.parse(String wire) {
    if (wire == 'global') return TtsRuleScope.global;
    if (wire.startsWith('app:')) {
      return TtsRuleScope.app(wire.substring('app:'.length));
    }
    if (wire.startsWith('avatar:')) {
      return TtsRuleScope.avatar(wire.substring('avatar:'.length));
    }
    throw FormatException('Unrecognized TtsRuleScope: "$wire"');
  }

  @override
  bool operator ==(Object other) =>
      other is TtsRuleScope && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TtsRuleScope($value)';
}

// ── Stage + Kind enums ───────────────────────────────────────────────────────

/// Which stage of the chat flow this rule applies in.
///
/// Mason's docs:
/// - [TtsRuleStage.brainNormalize] runs in `main_service` →
///   `brain_llm.py::_normalize_for_tts`, after the LLM emits a
///   TTS-bound clause and before it leaves the brain process.
///   Owns acronyms, brand/name substring overrides, broad contraction
///   expansion.
/// - [TtsRuleStage.ttsPrepass] runs in `inf_worker_0` →
///   `ttsreal.py::txt_to_audio`, right before `POST /v1/tts` to the
///   Qwen3 server. Owns markdown / `[CARD:…]` strip, curly apostrophe
///   normalize, `'s` lookup tables, possessive `'s` rewrites.
enum TtsRuleStage {
  brainNormalize('brain_normalize'),
  ttsPrepass('tts_prepass');

  const TtsRuleStage(this.wire);

  /// Wire-format value used in `tts_rules.json` keys.
  final String wire;

  /// Parse from the wire-format string. Throws [FormatException] on
  /// unrecognized values.
  static TtsRuleStage parse(String wire) {
    for (final s in TtsRuleStage.values) {
      if (s.wire == wire) return s;
    }
    throw FormatException('Unrecognized TtsRuleStage: "$wire"');
  }
}

/// The six pass kinds defined by the v2 schema. The shape of [TtsRule.body]
/// depends on the kind — see `clg_penthouse_pets/docs/TTS_RULES.md` for the
/// per-kind body schema. The SDK does not validate body contents; the
/// server is the schema authority.
enum TtsRuleKind {
  /// Lowercase everything. Body: `{}`.
  lowercase('lowercase'),

  /// Ordered list of `(pattern, replace)` regex substitutions.
  /// Body: `{ "rules": [{"pattern": "...", "replace": "...", "note": "..."}] }`.
  regexSubs('regex_subs'),

  /// Ordered list of plain-text `(find, replace)` substitutions.
  /// Body: `{ "rules": [{"find": "...", "replace": "...", "note": "..."}] }`.
  substringSubs('substring_subs'),

  /// For each listed word, rewrites `X's <word>` → `X has <word>`.
  /// Body: `{ "words": ["had", "got", ...] }`.
  hasParticiples('has_participles'),

  /// For `'s`-suffixed tokens, replaces from a lookup table if the bare
  /// word matches.
  /// Body: `{ "table": {"what": "wuts", ...}, "match_pattern": "..." }`.
  lookupAposS('lookup_apos_s'),

  /// Detects ALL-CAPS-ish tokens, spells letter-by-letter via a phonetic
  /// map; preserves plural `s`. `keep_as_word` exempts entries (e.g.
  /// `NASA` stays `nass-uh`).
  /// Body: `{ "pattern": "...", "keep_as_word": [...], "letter_phonetic": {...} }`.
  acronymSpell('acronym_spell');

  const TtsRuleKind(this.wire);

  final String wire;

  static TtsRuleKind parse(String wire) {
    for (final k in TtsRuleKind.values) {
      if (k.wire == wire) return k;
    }
    throw FormatException('Unrecognized TtsRuleKind: "$wire"');
  }
}

// ── TtsRule ──────────────────────────────────────────────────────────────────

/// One pronunciation rule, in the v2 schema shape.
///
/// Identity:
/// - [id] — server-assigned when the rule is created; null on a rule
///   being submitted for the first time via [AvatarAdminClient.addRule].
/// - [scope] — see [TtsRuleScope].
/// - [stage] — which stage runs this rule (see [TtsRuleStage]).
/// - [kind] — what kind of transformation (see [TtsRuleKind]).
///
/// Content:
/// - [body] — kind-specific shape. See [TtsRuleKind] docs for the
///   per-kind body schema. The SDK does not validate body contents.
/// - [note] — mandatory free-text rationale. Surfaced in the admin UI
///   so the next engineer reading the rule knows *why* it was added.
/// - [lang] — optional language filter, e.g. `['en']`, `['zh']`, `['*']`.
///   When `null` or empty, the rule applies to every language.
class TtsRule {
  const TtsRule({
    this.id,
    required this.scope,
    required this.stage,
    required this.kind,
    required this.body,
    required this.note,
    this.lang,
  });

  final String? id;
  final TtsRuleScope scope;
  final TtsRuleStage stage;
  final TtsRuleKind kind;
  final Map<String, dynamic> body;
  final String note;
  final List<String>? lang;

  TtsRule copyWith({
    String? id,
    TtsRuleScope? scope,
    TtsRuleStage? stage,
    TtsRuleKind? kind,
    Map<String, dynamic>? body,
    String? note,
    List<String>? lang,
  }) =>
      TtsRule(
        id: id ?? this.id,
        scope: scope ?? this.scope,
        stage: stage ?? this.stage,
        kind: kind ?? this.kind,
        body: body ?? this.body,
        note: note ?? this.note,
        lang: lang ?? this.lang,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'scope': scope.value,
        'stage': stage.wire,
        'kind': kind.wire,
        'body': body,
        'note': note,
        if (lang != null) 'lang': lang,
      };

  factory TtsRule.fromJson(Map<String, dynamic> json) {
    final bodyRaw = json['body'];
    final body = bodyRaw is Map<String, dynamic>
        ? bodyRaw
        : bodyRaw is Map
            ? Map<String, dynamic>.from(bodyRaw)
            : <String, dynamic>{};
    final langRaw = json['lang'];
    final lang = langRaw is List ? langRaw.cast<String>() : null;
    return TtsRule(
      id: json['id'] as String?,
      scope: TtsRuleScope.parse(json['scope'] as String),
      stage: TtsRuleStage.parse(json['stage'] as String),
      kind: TtsRuleKind.parse(json['kind'] as String),
      body: body,
      note: json['note'] as String? ?? '',
      lang: lang,
    );
  }

  @override
  String toString() =>
      'TtsRule(id=$id, scope=${scope.value}, stage=${stage.wire}, kind=${kind.wire})';
}

// ── Audition result ──────────────────────────────────────────────────────────

/// Result of [AvatarAdminClient.auditionPhrase] — synthesize a phrase with
/// the current (or a candidate) ruleset and get back the audio plus a
/// divergence score from the harness's STT-based scorer. Used by the
/// admin "test phrase" preview before saving a rule.
class TtsAuditionResult {
  const TtsAuditionResult({
    required this.audioBytes,
    required this.audioMimeType,
    required this.transcript,
    this.divergence,
  });

  /// Raw synthesized audio bytes, ready to drop into an HTML `<audio>` tag
  /// or platform audio player.
  final Uint8List audioBytes;

  /// MIME type for the audio bytes (`audio/mpeg`, `audio/wav`, etc.).
  final String audioMimeType;

  /// STT-back transcription of the synthesized audio. The "rendered ear"
  /// — what the recognizer thinks the synth said. Compare to the input
  /// phrase to see whether the pronunciation came through cleanly.
  final String transcript;

  /// Phoneme-first divergence score from the harness scorer (0.0 = perfect,
  /// higher = worse). `null` when the backend didn't run the scorer.
  /// Mason's threshold for "flag this term" is 0.35.
  final double? divergence;

  /// Wire shape: `{ audioBytes: <base64>, audioMimeType: '...', transcript: '...', divergence: 0.12 }`.
  factory TtsAuditionResult.fromJson(Map<String, dynamic> json) {
    final audioB64 = json['audioBytes'] as String? ?? '';
    final divergenceRaw = json['divergence'];
    return TtsAuditionResult(
      audioBytes: Uint8List.fromList(base64Decode(audioB64)),
      audioMimeType: json['audioMimeType'] as String? ?? 'audio/mpeg',
      transcript: json['transcript'] as String? ?? '',
      divergence: divergenceRaw is num ? divergenceRaw.toDouble() : null,
    );
  }
}
