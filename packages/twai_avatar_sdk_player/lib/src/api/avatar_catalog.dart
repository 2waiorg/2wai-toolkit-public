import '../outfit.dart';

/// Canonical wire response for the SDK's avatar-catalog fetch — the
/// shape returned by the pipeline's `GET /api/avatars/{slug}` and by
/// gen-2wai's `GET /api/gen/catalog/{owner}/{avatarname}`. One type;
/// the resolver picks the endpoint by slug shape.
///
/// Named `AvatarCatalogResponse` because `AvatarCatalog` is already
/// taken by the *admin display catalog* in
/// `packages/twai_avatar_sdk_core/lib/src/admin/avatar_catalog.dart`
/// (a curated-list-with-overlay concept, different concern). The two
/// types will likely converge in a future pass; today they coexist.
///
/// Includes the fields both server endpoints share plus the two the
/// SDK needs beyond the reference frontend's `Avatar` type:
///
/// - **`delivery`** — the per-outfit transport hint (`'mse'`,
///   `'wav2lip'`, `'v13'`, or null when the server doesn't know).
///   Determines the pipeline path prefix. Gen-2wai's catalog
///   populates this today; the muse pipeline `/api/avatars/{slug}`
///   response does not yet.
/// - **`pipelineName`** — the worker-internal talk-slug (e.g.
///   `'KrystalHarperMuseTalk3'`). Gen-2wai populates this from its
///   `pipeline_variant` field ([gen-2wai/app/api/catalog.py:46]);
///   the muse pipeline `/api/avatars/{slug}` response does NOT
///   populate it today. That's the backend gap that forces the
///   `KnownAvatars` bridge for muse-baked avatars.
///
/// When both fields are populated the SDK can construct + connect
/// without any client-side catalog. When they're missing the resolver
/// falls back to bundled `KnownAvatars` or throws.
class AvatarCatalogResponse {
  const AvatarCatalogResponse({
    required this.slug,
    required this.name,
    required this.tagline,
    required this.voiceId,
    required this.ttsSelection,
    required this.outfits,
  });

  /// Stable URL-friendly identifier (e.g. `'krystal-harper'`,
  /// `'alice/nova'` for gen-2wai).
  final String slug;
  final String name;
  final String tagline;

  /// Voice reference UUID (Qwen `ref_audio_id`). Empty string when
  /// the server doesn't return one.
  final String voiceId;
  final String ttsSelection;

  /// One entry per outfit variant. Must contain at least one entry
  /// for the resolver to construct a [PlayerAvatar].
  final List<AvatarCatalogOutfitResponse> outfits;

  /// Parse the shape returned by the pipeline's `/api/avatars/{slug}`
  /// or gen-2wai's `/api/gen/catalog/{owner}/{avatarname}`. Tolerant
  /// of missing fields — the resolver decides whether the result is
  /// useable for connect.
  factory AvatarCatalogResponse.fromJson(Map<String, dynamic> j) {
    // Gen-2wai wraps voice in `{"voice": {"ttsSelection", "avatarVoice"}}`.
    // Pipeline may return flat fields (voice_id / tts_selection) or
    // omit them entirely.
    String? voiceId;
    String? ttsSelection;
    final voice = j['voice'];
    if (voice is Map) {
      voiceId = voice['avatarVoice'] as String?;
      ttsSelection = voice['ttsSelection'] as String?;
    }
    voiceId ??= (j['voice_id'] ?? j['avatarVoice']) as String?;
    ttsSelection ??=
        (j['tts_selection'] ?? j['ttsSelection']) as String?;

    final outfitsRaw = j['outfits'];
    final outfits = <AvatarCatalogOutfitResponse>[];
    if (outfitsRaw is List) {
      for (final o in outfitsRaw) {
        if (o is Map<String, dynamic>) {
          outfits.add(AvatarCatalogOutfitResponse.fromJson(o));
        }
      }
    }

    return AvatarCatalogResponse(
      slug: (j['slug'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      tagline: (j['tagline'] as String?) ?? '',
      voiceId: voiceId ?? '',
      ttsSelection: ttsSelection ?? 'tts5',
      outfits: outfits,
    );
  }

  /// Convert to the SDK's [PlayerAvatar] type consumed by
  /// `TwaiPlayerHandle`. Returns null when the response is too thin
  /// to use — no outfits, or the first outfit has no `pipelineName`.
  ///
  /// The `pipelineName` gap is where the muse-pipeline backend is
  /// currently insufficient — its `/api/avatars/{slug}` doesn't
  /// return the worker-internal talk-slug, so the resolver has to
  /// fall back to `KnownAvatars` for those.
  PlayerAvatar? toPlayerAvatar() {
    if (outfits.isEmpty) return null;
    if (outfits.first.pipelineName.isEmpty) return null;
    return PlayerAvatar(
      slug: slug,
      name: name,
      tagline: tagline,
      voiceId: voiceId,
      ttsSelection: ttsSelection,
      outfits: outfits.map((o) => o.toPlayerOutfit()).toList(),
    );
  }
}

/// One outfit variant in an [AvatarCatalogResponse].
class AvatarCatalogOutfitResponse {
  const AvatarCatalogOutfitResponse({
    required this.slug,
    required this.name,
    required this.pipelineName,
    required this.idleUrl,
    this.posterUrl,
    this.delivery,
  });

  final String slug;
  final String name;
  final String pipelineName;
  final String idleUrl;
  final String? posterUrl;

  /// Transport hint — `'mse'`, `'wav2lip'`, `'v13'`, or null when the
  /// server doesn't specify. The facade uses this to pick the
  /// pipeline path prefix (`/ext-api-muse` vs `/ext-api`) instead of
  /// hardcoding.
  final String? delivery;

  factory AvatarCatalogOutfitResponse.fromJson(Map<String, dynamic> j) {
    return AvatarCatalogOutfitResponse(
      slug: (j['slug'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      pipelineName:
          (j['pipelineName'] ?? j['pipeline_name'] ?? '') as String,
      idleUrl: (j['idleUrl'] ?? j['idle_url'] ?? '') as String,
      posterUrl: (j['posterUrl'] ?? j['poster_url']) as String?,
      delivery: j['delivery'] as String?,
    );
  }

  PlayerOutfit toPlayerOutfit() => PlayerOutfit(
        slug: slug,
        name: name,
        pipelineName: pipelineName,
        idleUrl: idleUrl,
        posterUrl: posterUrl,
      );
}

/// Which stack the avatar lives on — determines the pipeline path
/// prefix (`pathPrefix` on the session factory).
///
/// Not to be confused with `AvatarStack` in
/// `packages/twai_avatar_sdk_core/lib/src/admin/avatar_catalog.dart`,
/// which is the admin/registry enum with the same conceptual role.
/// This one is the wire-response form (parseable from a string field);
/// the two will converge in a future pass.
enum AvatarDelivery {
  /// MuseTalk stack — `/ext-api-muse/`. Production standard today.
  mse('/ext-api-muse'),

  /// Wav2Lip stack — `/ext-api/`. Retired on staging 2026-07-17 for
  /// cost; still relevant for gen-2wai's fine-tuned bakes.
  wav2lip('/ext-api');

  const AvatarDelivery(this.pathPrefix);
  final String pathPrefix;

  /// Parse the string form the server returns; null on unknown.
  static AvatarDelivery? fromString(String? s) {
    switch (s) {
      case 'mse':
        return AvatarDelivery.mse;
      case 'wav2lip':
        return AvatarDelivery.wav2lip;
      default:
        return null;
    }
  }
}
