// The 5 seeded avatars — enough to exercise both transports and show
// the exerciser is honest about the roster we've documented in the wiki
// and in Mason's avatars.ts.
//
// Facts sourced from:
//   Sophi Summers  → c:/Dev/clg_penthouse_pets/frontend/src/lean/avatars.ts:152+
//   Bella Vaunt    → c:/Dev/clg_penthouse_pets/frontend/src/lean/avatars.ts:319+
//   Drew Scott     → gated preview at 2wai.ai/Drew (LoRA-5000, not in avatars.ts)
//   Mila           → memory reference_twai_gateway_test_credentials.md
//   Dr. Alman      → docs/2wai_toolkit_integration.md (Lumara demo constants)
//
// Everything-on-by-default principle: all 5 are visible in the picker
// on boot. Boot subject defaults to Sophi (verified everywhere).

import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

/// Transport hint per avatar. Until AvatarDelivery integration lands
/// (Phase A item 4), the app uses this map to build the right handle.
enum LabTransport {
  penthouseMseWs,       // Adapter 1 — Krystal /ext-api-muse
  twaiApiRestWss,       // Adapter 4 — api.2wai.ai/v1/*
  liveKit,              // Adapter 5 — api.2wai.ai/v1/sessions {transport: "livekit"}
}

class SeededAvatar {
  final PlayerAvatar avatar;
  final LabTransport transport;
  final String tagline;
  final String? note;   // shown in the picker; explains any live-status caveat
  /// When true and the mint proxy is configured, the exerciser wires an
  /// SSE brain callback (POST `<proxy>/brain/stream`) instead of the
  /// echo-mode default. Mirrors enlighten/lib/main.dart's wire for
  /// Dr. Alman. Direct-API mode always uses echo — there's no
  /// `/brain/stream` on api.2wai.ai itself.
  final bool usesBrain;
  const SeededAvatar({
    required this.avatar,
    required this.transport,
    required this.tagline,
    this.note,
    this.usesBrain = false,
  });
}

// ---- Sophi Summers — Penthouse MSE-over-WS (default boot subject) ---------

const _sophi = PlayerAvatar(
  slug: 'sophi-summers',
  name: 'Sophi Summers',
  tagline: 'Your sun-kissed California dreamer',
  voiceId: 'sophi-ft',
  deliveryOverride: AvatarDelivery.mse,
  outfits: [
    // Multi-idle rotation lists come from
    // c:/Dev/clg_penthouse_pets/frontend/src/lean/avatars.ts:171-179.
    // pipelineNames + idleUrls arrays drive resolveOutfit() per-session
    // random pick (port spec §12.1.3). See IDLE panel for how this
    // surfaces in the exerciser.
    PlayerOutfit(
      slug: 'date',
      name: 'Date',
      pipelineName: 'SophieSummersDateTalk1',
      pipelineNames: [
        'SophieSummersDateTalk1',
        'SophieSummersDateTalk2',
        'SophieSummersDateTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Date/Idle/Sophi_Date_IdleDefault.mp4',
      idleUrls: [
        'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Date/Idle/Sophi_Date_Idle1.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Date/Idle/Sophi_Date_Idle2.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Date/Idle/Sophi_Date_IdleDefault.mp4',
      ],
    ),
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'SophieSummersCasualTalk1',
      pipelineNames: [
        'SophieSummersCasualTalk1',
        'SophieSummersCasualTalk2',
        'SophieSummersCasualTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Casual/Idle/Sophi_Casual_IdleDefault.mp4',
      idleUrls: [
        'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Casual/Idle/Sophi_Casual_Idle1.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Casual/Idle/Sophi_Casual_Idle2.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Casual/Idle/Sophi_Casual_IdleDefault.mp4',
      ],
    ),
    PlayerOutfit(
      slug: 'swim',
      name: 'Swim',
      pipelineName: 'SophieSummersSwimTalk1',
      pipelineNames: [
        'SophieSummersSwimTalk1',
        'SophieSummersSwimTalk2',
        'SophieSummersSwimTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Swim/Idle/Sophi_Swim_IdleDefault.mp4',
    ),
  ],
);

// ---- Bella Vaunt — Penthouse MSE-over-WS ----------------------------------

const _bellaVaunt = PlayerAvatar(
  slug: 'bella-vaunt',
  name: 'Bella Vaunt',
  tagline: 'Signature avatar — Talk1/2/3 rotation, bellav-ft voice',
  voiceId: 'bellav-ft',
  outfits: [
    // Pipeline names verified live on staging.coreledgergroup.com
    // via /ext-api-muse/query_avatar 2026-08-15. Earlier V2MuseTalk3
    // labels were a stale registration.
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'BellaVauntCasualTalk1',
      pipelineNames: [
        'BellaVauntCasualTalk1',
        'BellaVauntCasualTalk2',
        'BellaVauntCasualTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Casual/Idle/BellaV_Casual_IdleDefault.mp4',
      idleUrls: [
        'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Casual/Idle/BellaV_Casual_Idle1.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Casual/Idle/BellaV_Casual_IdleDefault.mp4',
      ],
    ),
    PlayerOutfit(
      slug: 'date',
      name: 'Date',
      pipelineName: 'BellaVauntDateTalk1',
      pipelineNames: [
        'BellaVauntDateTalk1',
        'BellaVauntDateTalk2',
        'BellaVauntDateTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Date/Idle/BellaV_Date_IdleDefault.mp4',
      idleUrls: [
        'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Date/Idle/BellaV_Date_Idle1.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Date/Idle/BellaV_Date_IdleDefault.mp4',
      ],
    ),
    PlayerOutfit(
      slug: 'swim',
      name: 'Swim',
      pipelineName: 'BellaVauntSwimTalk1',
      pipelineNames: [
        'BellaVauntSwimTalk1',
        'BellaVauntSwimTalk2',
        'BellaVauntSwimTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Swim/Idle/BellaV_Swim_IdleDefault.mp4',
      idleUrls: [
        'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Swim/Idle/BellaV_Swim_Idle2.mp4',
        'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Swim/Idle/BellaV_Swim_IdleDefault.mp4',
      ],
    ),
    PlayerOutfit(
      slug: 'lingerie',
      name: 'Lingerie',
      pipelineName: 'BellaVauntLingerieTalk1',
      pipelineNames: [
        'BellaVauntLingerieTalk1',
        'BellaVauntLingerieTalk2',
        'BellaVauntLingerieTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Lingerie/Idle/BellaV_Lingerie_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'chain',
      name: 'Chain',
      pipelineName: 'BellaVauntChainTalk1',
      pipelineNames: [
        'BellaVauntChainTalk1',
        'BellaVauntChainTalk2',
        'BellaVauntChainTalk3',
      ],
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Chain/Idle/BellaV_Chain_IdleDefault.mp4',
    ),
  ],
);

// ---- Drew Scott — Penthouse, gated preview --------------------------------
// TODO(P1): confirm pipelineName + idleUrl + voiceId against 2wai.ai/Drew
// wire. LoRA-5000 gated-preview pattern; not registered in penthouse
// avatars.ts. Placeholder values below will 4xx until verified with Mason.

// Drew Scott removed 2026-08-25 — never verified, TODOs still open, Jim
// explicitly asked to drop him. Bring back only when there's a real
// pipeline + idle URL to point at.

// ---- Mila — twai-api REST + WSS (Adapter 4 reference) ---------------------
// Credentials from reference_twai_gateway_test_credentials.md (dedicated
// toolkit-demo tenant `ten_0e2277049d82a22bbb02ed30`, cap=20). IDs updated
// 2026-08-16 to the current live pair; the earlier `avt_40c...` / `vc_8d5...`
// pointed at the retired `MilaMuseTalk3` pipeline + a cross-tenant Qwen ref.

const _mila = PlayerAvatar(
  slug: 'mila',
  name: 'Mila',
  tagline: 'Adapter-4 reference -- twai-api gateway',
  voiceId: 'vc_e72e888d566aca3a4e63fbe8',
  outfits: [
    PlayerOutfit(
      slug: 'default',
      name: 'Default',
      pipelineName: 'avt_441ad4d95906438490a85b79',
      // Fallback poster while the pipeline handshake runs. Once
      // connected, the pipeline's own idle stream takes over. Without
      // this, a slow / failed connect leaves the stage completely
      // black — makes debugging harder because "nothing happened"
      // looks the same as "stage widget didn't mount."
      // Verified URL from apps/twai_api_starter (same working reference
      // we established after hours of Mila idle debugging).
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4',
    ),
  ],
);

// ---- Dr. Alman — twai-api REST + WSS --------------------------------------
// Facts from docs/2wai_toolkit_integration.md (the Lumara pre-solved doc).

const _drAlman = PlayerAvatar(
  slug: 'dr-alman',
  name: 'Dr. Alman',
  tagline: 'Mental-health companion',
  voiceId: 'vc_177ec070b504c0a701948fa6',
  outfits: [
    PlayerOutfit(
      slug: 'default',
      name: 'Consulting',
      pipelineName: 'avt_4586c4366d51bfa70c0df7cd',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BrianAlman/Default/Idles/BrianAlman_Idle1.mp4',
    ),
  ],
);

// ─── Transport 0 avatar variants ──────────────────────────────
// PlayerAvatar's outfit.pipelineName is what the mint sends as
// `avatar_id` to the twai-api gateway. For T0 that MUST be a
// tenant-scoped `avt_...` id registered on our jim-toolkit-demo tenant
// (`ten_0e2277049d82a22bbb02ed30`) with `livekit_profile` set. Adapter
// 1 uses raw PP pipeline names directly (`SophieSummersCasualTalk1`)
// against krystal MSE, so the two paths need separate PlayerAvatars.
// Registered 2026-08-24 via POST /admin/avatars.

const _sophiT0 = PlayerAvatar(
  slug: 'sophi-summers',
  name: 'Sophi Summers',
  tagline: 'Sun-kissed California dreamer',
  voiceId: 'sophi-ft',
  outfits: [
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'avt_dc56eb39fdf07c8b27d348d7',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Casual/Idle/Sophi_Casual_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'date',
      name: 'Date',
      pipelineName: 'avt_9344b191edd9c1810c209290',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Date/Idle/Sophi_Date_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'swim',
      name: 'Swim',
      pipelineName: 'avt_cde1f8e781909821e23a9610',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/SophiSummers/Swim/Idle/Sophi_Swim_IdleDefault.mp4',
    ),
  ],
);

const _bellaVauntT0 = PlayerAvatar(
  slug: 'bella-vaunt',
  name: 'Bella Vaunt',
  tagline: 'Signature avatar',
  voiceId: 'bellav-ft',
  outfits: [
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'avt_6e68bac1f46ebc8047707d49',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Casual/Idle/BellaV_Casual_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'date',
      name: 'Date',
      pipelineName: 'avt_f387d74086d581f0b9112351',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Date/Idle/BellaV_Date_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'swim',
      name: 'Swim',
      pipelineName: 'avt_81c7e1df8ab4fb85fc3ad7d7',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaVaunt/Swim/Idle/BellaV_Swim_IdleDefault.mp4',
    ),
  ],
);

// Krystal Harper + Bella Reid T0 — registered on tenant 2026-08-26.
// New rows only. Same shape as _sophiT0 / _bellaVauntT0 above so the
// widget/state code paths that switched cleanly on those keep
// working here.
const _krystalHarperT0 = PlayerAvatar(
  slug: 'krystal-harper',
  name: 'Krystal Harper',
  tagline: 'Sharp, intuitive',
  voiceId: 'krystal-ft',
  outfits: [
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'avt_096ef7f928a9bcee503eb1f9',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Casual/Idle/Krystal_Casual_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'date',
      name: 'Date',
      pipelineName: 'avt_8bc38f565a9f9fbaddf2b2b1',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Date/Idle/Krystal_Date_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'swim',
      name: 'Swim',
      pipelineName: 'avt_68952378c005883ef2ccb07b',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/KrystalHarper/Swim/Idle/Krystal_Swim_IdleDefault.mp4',
    ),
  ],
);

const _bellaReidT0 = PlayerAvatar(
  slug: 'bella-reid',
  name: 'Bella Reid',
  tagline: 'Signature avatar',
  voiceId: 'bellar-ft',
  outfits: [
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'avt_874985f1563aedce8999ed41',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaReid/Casual/Idle/BellaR_Casual_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'date',
      name: 'Date',
      pipelineName: 'avt_b1819d7d8f8c4eb922bcf0c3',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaReid/Date/Idle/BellaR_Date_IdleDefault.mp4',
    ),
    PlayerOutfit(
      slug: 'swim',
      name: 'Swim',
      pipelineName: 'avt_657a1b2cdd9661d7a799b956',
      idleUrl:
          'https://2waiassets.blob.core.windows.net/avatars/BellaReid/Swim/Idle/BellaR_Swim_IdleDefault.mp4',
    ),
  ],
);

// Add Sophi's Date + Swim outfits to her existing T0 PlayerAvatar in a
// separate const so the original _sophiT0 (which Codex's version knew)
// stays byte-identical for its Casual outfit. The SeededAvatar row for
// Sophi below still points at _sophiT0. If we want Date/Swim in the
// picker, either extend _sophiT0.outfits or add a second SeededAvatar
// (deferred — Casual-only for now to preserve Codex's exact shape).

const List<SeededAvatar> kSeededAvatars = [
  // ─── Transport 0 (LiveKit) — the current wire. Boot subject is
  // Dr. Alman (verified-working). The girls' Casual outfits are
  // registered on our jim-toolkit-demo tenant with matching
  // livekit_profile values; other outfits will 404 until registered.
  SeededAvatar(
    avatar: _drAlman,
    transport: LabTransport.liveKit,
    tagline: 'Transport 0 · Mental-health companion · verified boot subject',
    note: 'WebRTC + Soniox · avatar.livekit_profile=livealman',
    usesBrain: true,
  ),
  SeededAvatar(
    avatar: _sophiT0,
    transport: LabTransport.liveKit,
    tagline: 'Transport 0 · Sophi on LiveKit',
    note: 'Casual/Date/Swim · livekit_profile=sophi-summers',
  ),
  SeededAvatar(
    avatar: _bellaVauntT0,
    transport: LabTransport.liveKit,
    tagline: 'Transport 0 · Bella Vaunt on LiveKit',
    note: 'Casual/Date/Swim · livekit_profile=bella-vaunt',
  ),
  SeededAvatar(
    avatar: _krystalHarperT0,
    transport: LabTransport.liveKit,
    tagline: 'Transport 0 · Krystal Harper on LiveKit',
    note: 'Casual/Date/Swim · livekit_profile=krystal-harper · registered 2026-08-26',
  ),
  SeededAvatar(
    avatar: _bellaReidT0,
    transport: LabTransport.liveKit,
    tagline: 'Transport 0 · Bella Reid on LiveKit',
    note: 'Casual/Date/Swim · livekit_profile=bella-reid · registered 2026-08-26',
  ),
  // Mila NOT on Transport 0: PP staging LIVEKIT_AVATAR_SLUGS is
  // exactly `sophi-summers,bella-vaunt,krystal-harper,bella-reid`
  // (queried 2026-08-25) — Mila stays on Adapter 4 via twai-api
  // REST + WSS. Registered as-is on our tenant with livekit_profile
  // NULL again after a brief mis-enablement.
  // ─── Historical adapters — kept for regression testing while
  // consumer apps migrate. All the ChatSession-shaped paths.
  SeededAvatar(
    avatar: _sophi,
    transport: LabTransport.penthouseMseWs,
    tagline: 'Sun-kissed California dreamer',
    note: '5 outfits · sophi-ft voice · Adapter 1 (MSE)',
  ),
  SeededAvatar(
    avatar: _bellaVaunt,
    transport: LabTransport.penthouseMseWs,
    tagline: 'Signature avatar — v2 MuseTalk3 bake',
    note: '16-clip roster · voice v1 final ckpt · Adapter 1 (MSE)',
  ),
  SeededAvatar(
    avatar: _mila,
    transport: LabTransport.twaiApiRestWss,
    tagline: 'Adapter-4 reference — twai-api gateway',
    note: 'Requires mint proxy or CORS-direct',
  ),
  SeededAvatar(
    avatar: _drAlman,
    transport: LabTransport.twaiApiRestWss,
    tagline: 'Mental-health companion (Adapter 4)',
    note: 'Lumara reference · SSE brain via <proxy>/brain/stream',
    usesBrain: true,
  ),
];

/// The boot subject — Dr. Alman on Transport 0 (LiveKit).
SeededAvatar get kBootAvatar => kSeededAvatars.first;

/// Known voice IDs pulled from penthouse avatars.ts on 2026-08-15.
/// Populates the KNOWN VOICES chip row in METHODS VOICE section — tapping
/// a chip prefills the switch-voice field.
class KnownVoice {
  final String id;
  final String label;
  final String origin;
  const KnownVoice({required this.id, required this.label, required this.origin});
}

const List<KnownVoice> kKnownVoices = [
  KnownVoice(
      id: 'sophi-ft',
      label: 'Sophi (ft)',
      origin: 'Sophi Summers fine-tune'),
  KnownVoice(
      id: 'bellav-ft',
      label: 'Bella V (ft)',
      origin: 'Bella Vaunt fine-tune'),
  KnownVoice(
      id: 'krystal-ft',
      label: 'Krystal (ft)',
      origin: 'Krystal Harper fine-tune'),
  KnownVoice(
      id: 'mila-ft',
      label: 'Mila (ft)',
      origin: 'Mila fine-tune (LoRA 0.25, epoch-9)'),
  KnownVoice(
      id: '17222566-37b6-4c26-a8b9-4a086d441ce4',
      label: 'Bella Reid',
      origin: 'Base clone UUID (no fine-tune)'),
  KnownVoice(
      id: 'dbfef345-5efe-46ad-85d2-31b27004851e',
      label: 'Tahlia Paris',
      origin: 'Base clone UUID (no fine-tune)'),
];
