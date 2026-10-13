import 'dart:math';

import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

import 'api/avatar_catalog.dart' show AvatarDelivery;
import 'player_controller.dart';

/// The player-package avatar model — the content-full counterpart to
/// [Avatar] (transport-level id + voiceId) in `twai_avatar_sdk_core`.
///
/// A [PlayerAvatar] carries display metadata + a set of [PlayerOutfit]s.
/// The SDK player uses it to drive outfit switching, idle rotation,
/// talk-clip rotation, and (in later slices) emote/frame catalogs.
///
/// **Mirrors the reference `Avatar` type at**
/// `c:\Dev\clg_penthouse_pets\frontend\src\lean\avatars.ts:53-59`
/// (see `docs/avatar_input_spec.md` §2 for the artifact contract).
class PlayerAvatar {
  const PlayerAvatar({
    required this.slug,
    required this.name,
    required this.tagline,
    required this.voiceId,
    required this.outfits,
    this.ttsSelection = 'tts5',
    this.lipsyncEngine,
    this.deliveryOverride,
  });

  /// Stable URL-friendly identifier (e.g. `'krystal-harper'`).
  final String slug;

  /// Display name (e.g. `'Krystal Harper'`).
  final String name;

  /// One-line hook shown in catalog UIs.
  final String tagline;

  /// Voice reference UUID — Qwen3 `ref_audio_id`. See
  /// `docs/avatar_input_spec.md` §2.2.
  final String voiceId;

  /// TTS engine slot (default `'tts5'` = Qwen3, production standard).
  final String ttsSelection;

  /// The outfits available for this avatar. Must contain at least
  /// one entry; the first is the default.
  final List<PlayerOutfit> outfits;

  /// Which lipsync engine baked this avatar: `'wav2lip'` | `'musetalk'`.
  /// Present on gen-2wai catalog responses (default `'wav2lip'` for
  /// legacy NULLs there). Null on avatars whose backend doesn't ship
  /// this hint (older penthouse catalog responses). MuseTalk is the
  /// live production stack as of 2026-07-20; kept as a hint for
  /// per-engine routing / debug affordances rather than transport
  /// choice — the SDK's `MseStreamChatSession.pathPrefix` is what
  /// actually routes.
  final String? lipsyncEngine;

  /// Optional per-avatar Adapter-1 pipeline-stack override. When
  /// non-null, the SDK's `_sessionFactory` uses this delivery's
  /// [AvatarDelivery.pathPrefix] instead of the handle's
  /// `pathPrefix` constructor argument. Null (default) leaves
  /// behavior unchanged — the handle's `pathPrefix` wins (which
  /// itself defaults to `/ext-api-muse`).
  ///
  /// Use case: consumer app has a mixed catalog with some MuseTalk
  /// bakes and some Wav2Lip bakes. Setting this on each avatar lets
  /// the SDK auto-route without the consumer computing pathPrefix
  /// per session. Ignored when using [TwaiPlayerHandle.forApiSession]
  /// (Adapter 4) — twai-api gateway handles routing internally.
  final AvatarDelivery? deliveryOverride;

  /// Parse a `GET /api/gen/catalog/{owner}/{avatarname}` response into
  /// a fully-hydrated [PlayerAvatar]. The gen-2wai catalog is the
  /// canonical player-facing shape — see
  /// `c:\Dev\gen-2wai\app\api\catalog.py:55`.
  ///
  /// The catalog returns exactly one outfit in `outfits[]` (the
  /// default persona's outfit) — per-outfit media manifests are
  /// deliberately out of scope in gen-2wai v1.1. The optional
  /// top-level `media` block (`idle_urls`, `talking_variants`,
  /// `emotes`, `frames`) applies to that single outfit and is folded
  /// into it here as [PlayerOutfit.idleUrls] / [PlayerOutfit.pipelineNames]
  /// / [PlayerOutfit.emotes] / [PlayerOutfit.frameUrls].
  ///
  /// Missing / null fields degrade gracefully; the only requirement is
  /// that `outfits` is a non-empty list.
  factory PlayerAvatar.fromGenCatalog(Map<String, dynamic> json) {
    final voice = json['voice'] as Map<String, dynamic>? ?? const {};
    final outfitsRaw = json['outfits'] as List? ?? const [];
    if (outfitsRaw.isEmpty) {
      throw const FormatException(
        'gen-2wai catalog response has empty outfits[]',
      );
    }
    final media = json['media'] as Map<String, dynamic>?;
    final outfits = <PlayerOutfit>[];
    for (var i = 0; i < outfitsRaw.length; i++) {
      final o = outfitsRaw[i] as Map<String, dynamic>;
      // The `media` block in v1.1 refers to the default outfit
      // (outfits[0]) only. Fold it into that outfit; leave subsequent
      // outfits alone until gen-2wai grows per-outfit manifests.
      outfits.add(PlayerOutfit._fromGenCatalog(o, media: i == 0 ? media : null));
    }
    return PlayerAvatar(
      slug: json['slug'] as String,
      name: json['name'] as String? ?? '',
      tagline: json['tagline'] as String? ?? '',
      voiceId: voice['avatarVoice'] as String? ?? '',
      ttsSelection: voice['ttsSelection'] as String? ?? 'tts5',
      lipsyncEngine: json['lipsync_engine'] as String?,
      outfits: outfits,
    );
  }
}

/// One outfit / wardrobe / scenario variant of a [PlayerAvatar].
///
/// **Mirrors the reference `Outfit` type at**
/// `c:\Dev\clg_penthouse_pets\frontend\src\lean\avatars.ts:12-51`
/// (see `docs/avatar_input_spec.md` §3 for the artifact contract).
///
/// [pipelineNames] and [idleUrls] enable per-session rotation — see
/// [resolveOutfit] and port spec §8 / §9. Fallback: [pipelineName]
/// and [idleUrl] singletons.
class PlayerOutfit {
  const PlayerOutfit({
    required this.slug,
    required this.name,
    required this.pipelineName,
    required this.idleUrl,
    this.pipelineNames,
    this.idleUrls,
    this.defaultIdleUrl,
    this.posterUrl,
    this.previewUrl,
    this.unlockLevel,
    this.emotes,
    this.frameUrls,
  });

  /// Internal factory used by [PlayerAvatar.fromGenCatalog] — folds the
  /// optional per-avatar `media` block into the default outfit.
  factory PlayerOutfit._fromGenCatalog(
    Map<String, dynamic> outfitJson, {
    Map<String, dynamic>? media,
  }) {
    final talkingVariants = (media?['talking_variants'] as List?)?.cast<String>();
    final idleUrls = (media?['idle_urls'] as List?)?.cast<String>();
    final emotesRaw = media?['emotes'] as List?;
    final frames = (media?['frames'] as List?)?.cast<String>();
    return PlayerOutfit(
      slug: outfitJson['slug'] as String? ?? 'default',
      name: outfitJson['name'] as String? ?? 'Default',
      pipelineName: outfitJson['pipelineName'] as String? ?? '',
      idleUrl: outfitJson['idleUrl'] as String? ?? '',
      posterUrl: outfitJson['posterUrl'] as String?,
      previewUrl: outfitJson['previewUrl'] as String?,
      pipelineNames:
          talkingVariants != null && talkingVariants.isNotEmpty
              ? talkingVariants
              : null,
      idleUrls: idleUrls != null && idleUrls.isNotEmpty ? idleUrls : null,
      emotes: emotesRaw != null && emotesRaw.isNotEmpty
          ? emotesRaw
              .map((e) => PlayerEmote.fromJson(e as Map<String, dynamic>))
              .toList(growable: false)
          : null,
      frameUrls: frames != null && frames.isNotEmpty ? frames : null,
    );
  }

  /// Stable per-avatar outfit slug (e.g. `'casual'`, `'date'`).
  final String slug;

  /// Display name (e.g. `'Casual'`).
  final String name;

  /// Fallback baked talk source (`{AvatarName}{Outfit}Talk{N}`). Used
  /// when [pipelineNames] is null/empty.
  final String pipelineName;

  /// Optional per-session rotation set. Each entry must be a
  /// registered pipeline avatar name. See port spec §9 + audit
  /// `_s2`/`_s3` variant convention.
  final List<String>? pipelineNames;

  /// Fallback single idle URL. Used when [idleUrls] is null/empty.
  final String idleUrl;

  /// Optional per-session rotation set for idles.
  final List<String>? idleUrls;

  /// The canonical seam idle — its frame 0 is what every emote / frame
  /// / transition clip is authored to END on. Never randomised; used
  /// deterministically at every overlay-to-idle transition. See port
  /// spec §3.3.
  final String? defaultIdleUrl;

  /// Thumbnail JPG for outfit-picker tiles.
  final String? posterUrl;

  /// Animated WebP preview (~150 KB, 480p, 12fps, 3s loop) for
  /// outfit-picker tiles.
  final String? previewUrl;

  /// Optional tier gate for products that use unlock levels.
  final int? unlockLevel;

  /// Optional per-outfit emote clips. Present on outfits hydrated from
  /// a gen-2wai catalog `media.emotes` block; null on penthouse-style
  /// avatars where emotes aren't part of the catalog payload.
  final List<PlayerEmote>? emotes;

  /// Optional per-outfit static frame URLs (gen-2wai `media.frames`).
  /// Bare URLs — no metadata. Distinct from the SDK's richer
  /// [PlayerFrame] type in `gesture.dart` (which is a themed narrative
  /// clip with unlock levels + thumbnails). If gen-2wai grows richer
  /// frame metadata this can be promoted to `List<PlayerFrame>`.
  final List<String>? frameUrls;
}

/// A single emote clip belonging to an outfit — a short expressive
/// video (laugh / wave / eye-roll / etc.) the app can overlay on top
/// of the idle. Mirrors the gen-2wai catalog `media.emotes[]` shape
/// (`{id, url}`); expand as gen-2wai adds metadata (title, category,
/// duration).
class PlayerEmote {
  const PlayerEmote({required this.id, required this.url});

  /// Server-assigned integer id from `gen_clip.id` (Adapter 4 side).
  /// String on the Dart side so it can carry non-integer ids from a
  /// future backend without a breaking change.
  final String id;

  /// Playable URL for the emote clip (typically a fresh Azure Blob
  /// SAS URL).
  final String url;

  factory PlayerEmote.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    return PlayerEmote(
      id: rawId?.toString() ?? '',
      url: json['url'] as String? ?? '',
    );
  }
}

/// The result of resolving a [PlayerOutfit] for one session — i.e.
/// picking the specific pipeline variant and idle clip from the
/// rotation sets. Rotation happens per session; a fresh reconnect
/// picks anew (port spec §12.1.3 rotation reset).
class ResolvedOutfit {
  const ResolvedOutfit({
    required this.spec,
    required this.pipelineName,
    required this.idleUrl,
  });

  /// The source [PlayerOutfit] that produced this resolution.
  final PlayerOutfit spec;

  /// The specific pipeline avatar name picked for this session — this
  /// is what goes into the `MseStreamChatSession` handshake.
  final String pipelineName;

  /// The specific idle URL picked for this session — the app should
  /// render this as the background idle video.
  final String idleUrl;

  /// Compose the transport-level [Avatar] the controller passes to
  /// [ChatSession.connect].
  Avatar toAvatar({required String voiceId}) =>
      Avatar(id: pipelineName, voiceId: voiceId);
}

/// Pick a specific pipelineName + idleUrl for one session from an
/// outfit's rotation sets. Random per call — reconnects re-resolve
/// per port spec §12.1.3.
///
/// [rng] override is for tests; production callers should omit it.
ResolvedOutfit resolveOutfit(PlayerOutfit outfit, {Random? rng}) {
  final r = rng ?? Random();
  final names = outfit.pipelineNames;
  final pipelineName = (names != null && names.isNotEmpty)
      ? names[r.nextInt(names.length)]
      : outfit.pipelineName;
  final idles = outfit.idleUrls;
  final idleUrl = (idles != null && idles.isNotEmpty)
      ? idles[r.nextInt(idles.length)]
      : outfit.idleUrl;
  return ResolvedOutfit(
    spec: outfit,
    pipelineName: pipelineName,
    idleUrl: idleUrl,
  );
}

/// Opt-in composition helpers on [TwaiAvatarPlayerController] for
/// apps that use the [PlayerAvatar]/[PlayerOutfit] content-layer
/// types. Apps that never use them never see these methods (Dart
/// extensions are compile-time only — no runtime cost).
///
/// The controller stays outfit-agnostic; these helpers are a thin
/// bridge that resolves the outfit's rotation, hands the controller
/// a transport-level [Avatar], and returns the [ResolvedOutfit] so
/// the app can drive whatever UI is downstream (idle-URL swap,
/// transition overlay play, panel rehydration, etc.).
extension OutfitAwareController on TwaiAvatarPlayerController {
  /// Resolve [outfit], connect the controller to the resulting
  /// pipeline avatar (voice sourced from [avatar]), and return the
  /// resolution so the caller can render the idle URL.
  ///
  /// Convenience for the initial connect + first outfit pick. The
  /// app owns [PlayerAvatar]/[PlayerOutfit] state — this method
  /// doesn't stash it; a subsequent [switchOutfit] call needs the
  /// caller to pass in the new outfit.
  Future<ResolvedOutfit> enterChatWithOutfit(
    PlayerAvatar avatar,
    PlayerOutfit outfit, {
    Random? rng,
  }) async {
    final resolved = resolveOutfit(outfit, rng: rng);
    await connect(resolved.toAvatar(voiceId: avatar.voiceId));
    return resolved;
  }

  /// Resolve [newOutfit], swap the controller to the new pipeline
  /// avatar (via [changeAvatar]), and return the resolution.
  ///
  /// This is the primary in-session outfit-switch primitive — one
  /// call for the transport side. Transition-overlay playback + idle
  /// URL swap in the UI are the app's job; consume the returned
  /// [ResolvedOutfit] for those.
  Future<ResolvedOutfit> switchOutfit(
    PlayerAvatar avatar,
    PlayerOutfit newOutfit, {
    Random? rng,
  }) async {
    final resolved = resolveOutfit(newOutfit, rng: rng);
    await changeAvatar(resolved.toAvatar(voiceId: avatar.voiceId));
    return resolved;
  }
}
