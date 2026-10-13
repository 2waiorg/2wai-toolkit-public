import 'outfit.dart';

/// Bundled fallback catalog for [TwaiPlayerHandle.fromSlug] — avatars
/// whose pipeline `/api/avatars/{slug}` response is too thin to
/// construct a [PlayerAvatar] (missing `pipelineName` per outfit
/// and/or `idle_url`). Populated in-source so the SDK's happy-path
/// demo works out of the box; retire entries as the backend response
/// gets richer.
///
/// **This is a bridge, not the answer.** The right long-term fix is
/// the backend returning `pipelineName` + `idle_url` per outfit in
/// its `/api/avatars/{slug}` response — at which point [TwaiPlayerHandle.fromSlug]
/// resolves purely from the wire and this file empties out. Until
/// then, listing an avatar here is a decision that the SDK ships
/// with its playable metadata baked in.
///
/// Distinct from `AvatarCatalog.twaiDefault()` in
/// `packages/twai_avatar_sdk_core/lib/src/admin/avatar_catalog.dart`:
/// that's the *display* catalog (slug → pipelineNames + voice, no
/// outfits, no idle URLs) driven by the admin dashboard. This is the
/// *playable* catalog (full [PlayerAvatar] with outfits + idle URLs)
/// driven by the developer-facing facade. Two concerns, two catalogs,
/// same underlying reality; convergence pass tracked in memory.
///
/// # Two source rosters, coexisting
///
/// The bundled entries come from two authoritative sibling catalogs:
///
/// - **2wai.ai roster** (`Jesus`, `Kenan`, `Calum Worthy`, `Rob Riggle`) —
///   from `2waiorg/avatar-player:src/avatars.ts`. This is what
///   `2wai.ai/avatars/<slug>` serves. All are muse-baked as of
///   2026-07-20 (wav2lip retired; the `TalkN` names now resolve on
///   the muse stack).
/// - **Penthouse Pets roster** (`krystal-harper`) — from
///   `clg_penthouse_pets/frontend/src/lean/avatars.ts`. Penthouse has
///   more Pets (Sophi, Bella V, Bella R, Tahlia) that could land here
///   as we validate them.
///
/// Maradona is **intentionally excluded** — bake is broken as of
/// 2026-07-20 (Mason needs to redo it). Add back once he pings ready.
class KnownAvatars {
  const KnownAvatars._();

  // ══════════════════════════════════════════════════════════════════
  // 2wai.ai roster (from 2waiorg/avatar-player:src/avatars.ts)
  // ══════════════════════════════════════════════════════════════════

  /// Jesus. Single "Default" outfit; four talk substrates rotate per
  /// session; three idle takes.
  ///
  /// **Quality caveat:** the MuseTalk base UNet wasn't trained on
  /// enough bearded faces, so the mouth region can render as mush on
  /// close inspection — this is a training-side gap Mason is actively
  /// working (bearded-face base model / per-avatar LoRA path). Jesus
  /// ships anyway because the failure mode is cosmetic, not a crash,
  /// and the roster needs him. Remove this note when the bearded-face
  /// fix lands. See `memory/project_jesus_muse_bake_status.md`.
  static const jesus = PlayerAvatar(
    slug: 'jesus',
    name: 'Jesus',
    tagline: 'Walking the path, telling the story',
    voiceId: '9c32e898-e99c-4287-89a1-57f5243aa454',
    outfits: [
      PlayerOutfit(
        slug: 'default',
        name: 'Default',
        pipelineName: 'RedJesusTalk1',
        pipelineNames: [
          'RedJesusTalk1',
          'RedJesusTalk2',
          'RedJesusTalk3',
          'RedJesusTalk4',
        ],
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/RedJesus/Idles/RedJesus_Idle1.mp4',
        idleUrls: [
          'https://2waiassets.blob.core.windows.net/avatars/RedJesus/Idles/RedJesus_Idle1.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/RedJesus/Idles/RedJesus_Idle2.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/RedJesus/Idles/RedJesus_Idle3.mp4',
        ],
        posterUrl:
            'https://2waiassets.blob.core.windows.net/avatars/RedJesus/profile.png',
      ),
    ],
  );

  /// Kenan — Auto Trader persona. Three talk substrates; three idle
  /// takes. Explicit `delivery: 'mse'` on the source; muse is the
  /// only route today so implicit here.
  static const kenan = PlayerAvatar(
    slug: 'KenanAutoTrader',
    name: 'Kenan',
    tagline: 'Your friendly Auto Trader expert',
    voiceId: '6b40ea60-7bc2-438d-a19e-cb1cc7a8ba79',
    outfits: [
      PlayerOutfit(
        slug: 'default',
        name: 'Red Kenan',
        pipelineName: 'RedKenanTalk1',
        pipelineNames: [
          'RedKenanTalk1',
          'RedKenanTalk2',
          'RedKenanTalk3',
        ],
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/RedKenan/Idles/RedKenan_Idle1.mp4?v=2',
        idleUrls: [
          'https://2waiassets.blob.core.windows.net/avatars/RedKenan/Idles/RedKenan_Idle1.mp4?v=2',
          'https://2waiassets.blob.core.windows.net/avatars/RedKenan/Idles/RedKenan_Idle2.mp4?v=2',
          'https://2waiassets.blob.core.windows.net/avatars/RedKenan/Idles/RedKenan_Idle3.mp4?v=2',
        ],
        posterUrl:
            'https://2waiassets.blob.core.windows.net/avatars/RedKenan/profile.jpg?v=2',
      ),
    ],
  );

  /// Calum Worthy — 2wai co-founder. Single-variant outfit (one
  /// pipelineName, one idle). Rotation lists intentionally omitted;
  /// resolver falls back to the singletons.
  static const calumWorthy = PlayerAvatar(
    slug: 'calum-worthy',
    name: 'Calum Worthy',
    tagline: 'Actor, activist, 2wai co-founder',
    voiceId: '78aedadb-2652-45ba-acd4-f60bf75a2d5e',
    outfits: [
      PlayerOutfit(
        slug: 'default',
        name: 'Default',
        pipelineName: 'CalumTalk1',
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/Calum/Idles/Calum_Idle1.mp4?v=4',
        posterUrl:
            'https://2waiassets.blob.core.windows.net/avatars/Calum/profile.jpg?v=4',
      ),
    ],
  );

  /// Rob Riggle — casino game master. Three talk substrates; three
  /// idle takes.
  static const robRiggle = PlayerAvatar(
    slug: 'RobRiggle',
    name: 'Rob Riggle',
    tagline: 'Casino game master',
    voiceId: '8419eb6a-6144-440a-864a-0c67d24727e8',
    outfits: [
      PlayerOutfit(
        slug: 'default',
        name: 'Rob Riggle',
        pipelineName: 'RobRiggleTalk1',
        pipelineNames: [
          'RobRiggleTalk1',
          'RobRiggleTalk2',
          'RobRiggleTalk3',
        ],
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/RobRiggle/Idles/RobRiggle_Idle1.mp4',
        idleUrls: [
          'https://2waiassets.blob.core.windows.net/avatars/RobRiggle/Idles/RobRiggle_Idle1.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/RobRiggle/Idles/RobRiggle_Idle2.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/RobRiggle/Idles/RobRiggle_Idle3.mp4',
        ],
        posterUrl:
            'https://2waiassets.blob.core.windows.net/avatars/RobRiggle/profile.jpg',
      ),
    ],
  );

  // ══════════════════════════════════════════════════════════════════
  // Penthouse Pets roster (from clg_penthouse_pets/frontend/src/lean/avatars.ts)
  // ══════════════════════════════════════════════════════════════════

  /// Krystal Harper. Three outfits (Casual, Date, Swim); each with
  /// three muse-bake substrates (`base` + `_s2` + `_s3`) and three
  /// idle takes per Mason's
  /// [avatar-bake-pipeline](https://wiki.2wai.ai/architecture/avatar-bake-pipeline/)
  /// naming convention (`TalkN → base/_sN` plate dirs).
  ///
  /// Authoritative source:
  /// - pipelineName rotation:
  ///   `clg_penthouse_pets/frontend/src/pages/LeanChatPage.tsx:152-157`
  ///   (`MUSE_DEFAULT_PIPELINES`).
  /// - idle rotation + voice id:
  ///   `clg_penthouse_pets/frontend/src/lean/avatars.ts:80-134`.
  static const krystalHarper = PlayerAvatar(
    slug: 'krystal-harper',
    name: 'Krystal Harper',
    tagline: 'Sharp, intuitive, unapologetically herself',
    voiceId: '8c0fbca6-e833-452a-873e-85f7cc217d17',
    outfits: [
      PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        // Fallback single — kept in sync with pipelineNames[0] so the
        // resolver picks the same base name when the rotation list is
        // stripped (tests / older versions of resolveOutfit).
        pipelineName: 'KrystalHarperMuseTalk3',
        pipelineNames: [
          'KrystalHarperMuseTalk3',
          'KrystalHarperMuseTalk3_s2',
          'KrystalHarperMuseTalk3_s3',
        ],
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_IdleDefault.mp4',
        idleUrls: [
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_Idle1.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_Idle3.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_IdleDefault.mp4',
        ],
        defaultIdleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_IdleDefault.mp4',
      ),
      PlayerOutfit(
        slug: 'date',
        name: 'Date',
        pipelineName: 'KrystalHarperDateMuseTalk3',
        pipelineNames: [
          'KrystalHarperDateMuseTalk3',
          'KrystalHarperDateMuseTalk3_s2',
          'KrystalHarperDateMuseTalk3_s3',
        ],
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Date/Idle/Krystal_Date_IdleDefault.mp4',
        idleUrls: [
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Date/Idle/Krystal_Date_Idle1.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Date/Idle/Krystal_Date_Idle2.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Date/Idle/Krystal_Date_IdleDefault.mp4',
        ],
        defaultIdleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Date/Idle/Krystal_Date_IdleDefault.mp4',
      ),
      PlayerOutfit(
        slug: 'swim',
        name: 'Swim',
        pipelineName: 'KrystalHarperSwimMuseTalk3',
        pipelineNames: [
          'KrystalHarperSwimMuseTalk3',
          'KrystalHarperSwimMuseTalk3_s2',
          'KrystalHarperSwimMuseTalk3_s3',
        ],
        idleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Swim/Idle/Krystal_Swim_IdleDefault.mp4',
        idleUrls: [
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Swim/Idle/Krystal_Swim_Idle1.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Swim/Idle/Krystal_Swim_Idle2.mp4',
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Swim/Idle/Krystal_Swim_IdleDefault.mp4',
        ],
        defaultIdleUrl:
            'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Swim/Idle/Krystal_Swim_IdleDefault.mp4',
      ),
    ],
  );

  // ══════════════════════════════════════════════════════════════════
  // Lookup
  // ══════════════════════════════════════════════════════════════════

  /// Lookup by slug — returns null when the slug isn't in the bundled
  /// catalog. Resolver escalates to the wire response, then throws
  /// with a helpful message if both are empty.
  ///
  /// Slug conventions vary by source frontend — the 2wai.ai catalog
  /// uses mixed-case (`KenanAutoTrader`, `RobRiggle`) alongside
  /// kebab-case (`jesus`, `calum-worthy`). We match the source-of-truth
  /// slugs exactly so URLs from `2wai.ai/avatars/<slug>` and
  /// `penthousepets.com/pets/<slug>` copy-paste into the SDK.
  static PlayerAvatar? lookup(String slug) {
    switch (slug) {
      case 'jesus':
        return jesus;
      case 'KenanAutoTrader':
        return kenan;
      case 'calum-worthy':
        return calumWorthy;
      case 'RobRiggle':
        return robRiggle;
      case 'krystal-harper':
        return krystalHarper;
      default:
        return null;
    }
  }

  /// All slugs the bundled catalog covers. Useful for tests +
  /// diagnostic UIs enumerating the "works out of the box" set.
  static const List<String> allSlugs = [
    'jesus',
    'KenanAutoTrader',
    'calum-worthy',
    'RobRiggle',
    'krystal-harper',
  ];
}
