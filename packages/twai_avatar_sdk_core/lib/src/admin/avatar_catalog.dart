import 'avatar_admin_config.dart';

/// Which lipsync backend an avatar's session traffic must be routed
/// to. Each value maps to a distinct nginx `location` block on the
/// pipeline gateway, each fronting its own `main_service` + inference
/// worker pair. Wrong prefix for a given avatar → the target worker
/// doesn't know the avatar name → server closes the WS with
/// `code=1011, reason="worker unreachable"` (or similar).
///
/// Mirrors the frontend's per-avatar dispatch at
/// `clg_penthouse_pets/frontend/src/pages/LeanChatPage.tsx:179`.
enum AvatarStack {
  /// Historical wav2lip stack. `/ext-api/mse_stream` + `/ext-api/human`.
  ///
  /// **RETIRED 2026-07-17.** Mason took the wav2lip pipeline down
  /// (~$5k/mo saved) and standardised on MuseTalk — see PRD
  /// `docs/prd_2026_07_18.md` §7. Nothing routes to `/ext-api`
  /// today; sessions constructed against this stack close with
  /// `code=1011 reason="worker unreachable"` (verified via
  /// `tools/ws_probe.dart` on 2026-07-17). Kept in the enum for
  /// backwards binary compatibility of any code still referencing
  /// the value — remove in the next major.
  @Deprecated(
    'wav2lip retired 2026-07-17. Use AvatarStack.muse. See PRD §7.',
  )
  wav2lip('/ext-api'),

  /// Production muse stack (Krystal / Sophi / Bella Vaunt migrated
  /// 2026-07-12; all avatars 2026-07-17+). Real-time MuseTalk
  /// lipsync. `/ext-api-muse/*`. **The default stack for the SDK.**
  muse('/ext-api-muse'),

  /// ONNX-runtime dev variant. `/ext-api-onnx/*`. Admin-only today
  /// (used by the lipsync-test page); production traffic doesn't
  /// route here.
  onnx('/ext-api-onnx');

  const AvatarStack(this.pathPrefix);

  /// URL prefix to feed [MseStreamChatSession.pathPrefix]. Rooted
  /// (starts with `/`, no trailing slash).
  final String pathPrefix;
}

/// A curated display catalog that sits *on top* of the raw pipeline
/// registry (`AvatarAdminClient.allAvatars` / `readyAvatars`) and picks
/// out a subset for a specific product surface.
///
/// The pipeline registry (a shared MongoDB behind `main_service`) holds
/// every avatar that any customer has ever staged assets for — Penthouse
/// Pets, 2wai roster, one-off generations, test rows. That is the right
/// answer for the wire ("which avatar_names does the worker VM know how
/// to serve?") but it's the wrong answer for a customer-facing admin UI
/// ("which avatars should this product's operators see?").
///
/// A [AvatarCatalog] mirrors the pattern the production 2wai web player
/// uses at `avatar-player/src/avatars.ts`: an explicit list of entries,
/// each pointing to one or more pipeline names, with display metadata
/// carried alongside. At runtime you overlay the catalog on the raw
/// registry — the result is a curated, product-branded list with
/// registry-driven readiness badges.
///
/// Example — admin app filtering to just the 2wai roster:
///
/// ```dart
/// final catalog = AvatarCatalog.twaiDefault();
/// final admin = twai.admin(developerMode: true);
/// final all = await admin.allAvatars();
/// final ready = (await admin.readyAvatars()).toSet();
/// final display = catalog.overlay(all, ready);
/// // display.length == 5 — the 5 2wai avatars, regardless of how many
/// // Penthouse rows are in mongo alongside them.
/// ```
class AvatarCatalog {
  const AvatarCatalog({required this.name, required this.entries});

  /// Short identifier for the catalog — e.g. `'2wai'`, `'candy-ai'`.
  /// Used in log lines and to distinguish catalogs when multiple are
  /// loaded (e.g. an admin operator switching between product views).
  final String name;

  /// The curated entries, in the order they should be displayed.
  final List<AvatarCatalogEntry> entries;

  /// Overlay the catalog on a raw registry snapshot.
  ///
  /// For each catalog entry, finds every [AvatarMetadata] whose
  /// `avatarName` matches one of the entry's [AvatarCatalogEntry.pipelineNames].
  /// An entry with zero matches is included with an empty
  /// [CatalogAvatar.registrations] list — the UI can then surface it as
  /// "in catalog but not yet in the pipeline" (asset-prep pending).
  ///
  /// Order of [entries] is preserved. Raw registry rows that don't
  /// match any catalog entry are dropped — that's the whole point.
  List<CatalogAvatar> overlay(
    List<AvatarMetadata> registry,
    Set<String> readyNames,
  ) {
    final byName = <String, AvatarMetadata>{
      for (final a in registry) a.avatarName: a,
    };
    return [
      for (final e in entries)
        CatalogAvatar(
          entry: e,
          registrations: [
            for (final p in e.pipelineNames)
              if (byName[p] case final match?) match,
          ],
          readyPipelineNames: {
            for (final p in e.pipelineNames)
              if (readyNames.contains(p)) p,
          },
        ),
    ];
  }

  /// The 2wai display catalog — mirrors the roster shipped in the
  /// production web player (`avatar-player/src/avatars.ts` on
  /// `2waiorg/avatar-player@main`). Explicitly excludes the Penthouse
  /// Pets cast, which lives on a separate product surface.
  ///
  /// Kept as a factory (not a `const` field) so tests can compare
  /// instances by content, not identity, and so entries can be tweaked
  /// per-build without touching the ambient const graph.
  factory AvatarCatalog.twaiDefault() => AvatarCatalog(
        name: '2wai',
        entries: [
          const AvatarCatalogEntry(
            slug: 'KenanAutoTrader',
            displayName: 'Kenan',
            tagline: 'Your friendly Auto Trader expert',
            voiceId: '6b40ea60-7bc2-438d-a19e-cb1cc7a8ba79',
            ttsSelection: 'tts5',
            pipelineNames: {
              'RedKenanTalk1',
              'RedKenanTalk2',
              'RedKenanTalk3',
            },
            posterUrl:
                'https://2waiassets.blob.core.windows.net/avatars/RedKenan/profile.jpg?v=2',
          ),
          const AvatarCatalogEntry(
            slug: 'jesus',
            displayName: 'Jesus',
            tagline: 'Walking the path, telling the story',
            voiceId: '9c32e898-e99c-4287-89a1-57f5243aa454',
            ttsSelection: 'tts5',
            pipelineNames: {
              'RedJesusTalk1',
              'RedJesusTalk2',
              'RedJesusTalk3',
              'RedJesusTalk4',
            },
            posterUrl:
                'https://2waiassets.blob.core.windows.net/avatars/RedJesus/profile.png',
          ),
          const AvatarCatalogEntry(
            slug: 'calum-worthy',
            displayName: 'Calum Worthy',
            tagline: 'Actor, activist, 2wai co-founder',
            voiceId: '78aedadb-2652-45ba-acd4-f60bf75a2d5e',
            ttsSelection: 'tts5',
            pipelineNames: {'CalumTalk1'},
            posterUrl:
                'https://2waiassets.blob.core.windows.net/avatars/Calum/profile.jpg?v=4',
          ),
          const AvatarCatalogEntry(
            slug: 'RobRiggle',
            displayName: 'Rob Riggle',
            tagline: 'Casino game master',
            voiceId: '8419eb6a-6144-440a-864a-0c67d24727e8',
            ttsSelection: 'tts5',
            pipelineNames: {
              'RobRiggleTalk1',
              'RobRiggleTalk2',
              'RobRiggleTalk3',
            },
            posterUrl:
                'https://2waiassets.blob.core.windows.net/avatars/RobRiggle/profile.jpg',
          ),
          const AvatarCatalogEntry(
            slug: 'maradona',
            displayName: 'Maradona',
            tagline: 'The beautiful game, told by Diego',
            voiceId: '239d8db0-1812-4a09-9256-d90a12b24094',
            ttsSelection: 'tts5',
            pipelineNames: {
              'MaradonaTalk2',
              'MaradonaTalk3',
              'MaradonaTalk4',
            },
            posterUrl:
                'https://2waiassets.blob.core.windows.net/avatars/Maradona/profile.jpg',
          ),
        ],
      );
}

/// One entry in an [AvatarCatalog] — a product-facing avatar and the
/// pipeline row(s) that back it.
///
/// [pipelineNames] is a *set* because a single display avatar (e.g.
/// Jesus) is often backed by several variant clips in the pipeline
/// (`RedJesusTalk1..4`) that get rotated per-session for visual
/// variety. The overlay treats an entry as ready if *any* of its
/// backing pipelineNames is ready.
class AvatarCatalogEntry {
  const AvatarCatalogEntry({
    required this.slug,
    required this.displayName,
    required this.tagline,
    required this.voiceId,
    required this.ttsSelection,
    required this.pipelineNames,
    this.posterUrl,
    this.stack = AvatarStack.muse,
  });

  /// Stable URL-friendly identifier, e.g. `'jesus'`.
  final String slug;

  /// Human-visible name for the avatar (e.g. `'Jesus'`, `'Kenan'`).
  final String displayName;

  /// One-line description shown under the display name.
  final String tagline;

  /// Qwen3 TTS `ref_audio_id` — matches the `voice_id` field the
  /// admin API's `addAvatar` writes into the pipeline registry.
  final String voiceId;

  /// TTS engine slug (`'tts5'` for Qwen3 in current prod). Held here
  /// because per-avatar overrides do happen (see `TahliaParisTalk*`).
  final String ttsSelection;

  /// Pipeline-side avatar names this entry maps to. Multiple names
  /// mean the display avatar rotates through variant clips.
  final Set<String> pipelineNames;

  /// Optional poster/thumbnail URL. Reserved for future admin UI use;
  /// null-safe today (default listing shows an icon).
  final String? posterUrl;

  /// Which lipsync backend serves this avatar. Callers pass
  /// `stack.pathPrefix` to `TwaiClient.mseStreamSession(pathPrefix: ...)`
  /// or `MseStreamChatSession.pathPrefix` directly. Default
  /// [AvatarStack.muse] — the only live production stack post
  /// 2026-07-17 wav2lip retirement.
  final AvatarStack stack;
}

/// The result of overlaying a catalog on a raw registry snapshot —
/// one per catalog entry, with the matching registry rows (if any)
/// joined in.
class CatalogAvatar {
  const CatalogAvatar({
    required this.entry,
    required this.registrations,
    required this.readyPipelineNames,
  });

  /// The catalog entry that produced this row.
  final AvatarCatalogEntry entry;

  /// Registry rows whose `avatarName` matched one of
  /// [AvatarCatalogEntry.pipelineNames]. Empty if the entry is
  /// unregistered — treat as "asset-prep pending" in the UI.
  final List<AvatarMetadata> registrations;

  /// Subset of [AvatarCatalogEntry.pipelineNames] that are in the
  /// server's ready list. An entry is broadly "ready" if this is
  /// non-empty (see [isReady]); the granular set is exposed for UIs
  /// that want to show per-variant status.
  final Set<String> readyPipelineNames;

  /// True if at least one backing pipeline name is ready to serve.
  bool get isReady => readyPipelineNames.isNotEmpty;

  /// True if at least one registry row exists for this entry.
  bool get isRegistered => registrations.isNotEmpty;

  /// A representative prompt from the joined registrations, or empty
  /// string if unregistered. For entries with multiple registered
  /// variants (e.g. Jesus's four Talk clips) picks the first non-empty
  /// prompt — the prompts should match, since a display avatar is one
  /// persona regardless of clip variant.
  String get representativePrompt {
    for (final r in registrations) {
      if (r.prompt.isNotEmpty) return r.prompt;
    }
    return '';
  }
}
