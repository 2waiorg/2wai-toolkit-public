# Voice + TTS — Configuration and Roadmap

> **Scope clarifier (read first):** Everything in this doc is for **[shape #1 (hosted full-stack)](integration_shapes.md#shape-1--hosted-full-stack)** integrations — i.e. customers where 2wai's central pipeline runs the TTS server-side. The `tts9 = 11labs` work is the shape #1 path for adding ElevenLabs as a server-side engine.
>
> **For [shape #2 (hosted render-only)](integration_shapes.md#shape-2--hosted-render-only) customers like Candy.ai, none of this applies** — they run 11labs themselves and ship us audio. The shape-#2 path is the new `POST /ext-api/render` endpoint scoped in [`candy_ai_fit.md`](candy_ai_fit.md), not `tts9`.
>
> **For [shape #3 (on-device)](edge_offline_shape.md) customers** like Jonathan, TTS runs entirely on the user's device via a customer-implemented `TtsProvider` (interface roadmapped) — also not `tts9`.
>
> ---
>
> How TTS engine selection and per-avatar voice clones are wired today, the recommended near-term configuration story (.env knob in the host app), the longer-term `VoiceProfile` abstraction, the admin-tool voice-generation flow that needs a backend proxy, and a concrete two-phase plan for testing another TTS engine on the shape-#1 path (the ElevenLabs `tts9` adapter case is worked through end-to-end).
>
> Companion to [`integration_shapes.md`](integration_shapes.md) (the three-shape framework that contextualizes this doc), [`protocol.md`](protocol.md) §1 (the wire-level TTS handshake), [`admin.md`](admin.md) (registry + pipeline tracker), and [`sdk_overview.md`](sdk_overview.md) (backend platform overview). This doc exists because the slot/voice coupling is subtle and burned us once already — capturing it before it bites again.

---

## Current state

There are two independent knobs that look similar but live in completely different places:

| What | Where it's hardcoded today | Per | Lives in |
|---|---|---|---|
| **TTS engine slot** (e.g. `tts5` = Qwen3) | [`apps/jesus/lib/main.dart:112`](../apps/jesus/lib/main.dart#L112) — `_resolveTtsSelection()` defaulting to `'tts5'` | Per-session (the client picks at handshake time) | WS handshake JSON per `protocol.md` §1 — `"ttsSelection": "tts5"` |
| **Voice clone UUID** (e.g. `9c32e898-…` for Jesus) | [`apps/jesus/lib/main.dart:109`](../apps/jesus/lib/main.dart#L109) — `voiceId: '9c32e898-…'` | Per-avatar (lives in `main_service`'s `avatars` MongoDB collection, set at `addAvatar` time) | Same WS handshake — `"avatarVoice": "<uuid>"` |

Both are passed to `_twai.mseStreamSession(ttsSelection: _ttsSelection)` + `_session.connect(_avatar)` and end up in the Adapter 1 handshake JSON. The SDK treats both as opaque strings; `main_service` is what actually does the engine selection and voice lookup.

### Known TTS slots — verified against `main_service/web/options.json:380-396`

| Slot | Engine | Notes |
|---|---|---|
| `tts1` | xtts | |
| `tts2` | gtts | Google TTS |
| `tts3` | edgetts | Microsoft Edge TTS |
| `tts4` | index-TTS | |
| `tts5` | **qwen-tts** | **Production default for Adapter 1.** Voice UUIDs are `ref_audio_id`s in the Qwen service on `labs-gpu-01`. |

**`tts6`/`tts7`/`tts8`/`tts9` do not exist server-side.** Earlier versions of this doc speculated those slots; they were never implemented in `main_service`. Adding an ElevenLabs slot to Adapter 1 would be a net-new backend deliverable.

**Note on Adapter 2 (the simpler `2wai-avatar-pipeline` request/response server):** that pipeline **already uses ElevenLabs** in production ([server.py:189-211](../../2wai-avatar-pipeline/server/server.py)), via the `eleven_flash_v2_5` model. It's hardcoded, not slot-selectable — you don't pass a `ttsSelection` to that server; you just `POST /chat` and 11labs is what TTS's the LLM reply. So "ElevenLabs on 2wai infrastructure" is **partly already shipped** — just not on the streaming Adapter 1 path.

---

## The slot/voice coupling — important

A voice UUID is **only valid on the engine that minted it**:

- A Qwen3 ref_audio_id like `9c32e898-…` only works when the session is on `tts5`.
- An ElevenLabs voice id would only work on a future `tts9`.

This means **you can't naively flip `ttsSelection` without also matching the avatar's voice id to the new engine**. The two values are coupled at the avatar level: when you register an avatar via `addAvatar(voiceId: …)`, you're implicitly committing that avatar to whichever TTS slot the UUID was minted on.

Practical consequence: switching an existing avatar to a different TTS engine is a **content-migration operation**, not a config flip. You re-clone the voice on the new engine, get a new UUID, and either re-register the avatar (deleting the old one) or register a parallel avatar id (`Jesus11labs`) for A/B comparison. The SDK side is zero work; the operations / content side is non-trivial.

---

## Recommended near-term: .env knob in the host app

For the Jesus reference app — and the same shape for any customer app — TTS slot belongs in `.env` alongside the existing env + key plumbing. It varies per app / per environment (DEV might want `tts8=eSpeak` for cheap iteration; PROD uses `tts5`), not per conversation.

**Recommended `.env` for `apps/jesus/.env`:**

```ini
# Existing
TWAI_ENV=2wai-staging
TWAI_PUBLISHABLE_KEY=pk_live_...

# New
TWAI_TTS_SELECTION=tts5            # tts4=IndexTTS, tts5=Qwen3, tts6=XTTSv2,
                                    # tts7=StyleTTS2, tts8=eSpeak.
                                    # Future: tts9=ElevenLabs (backend ask).
```

**Resolution order** (matches the existing `_resolveEnv()` / `_resolvePublishableKey()` pattern in `main.dart`): `--dart-define TWAI_TTS_SELECTION=…` → `.env` → fallback default `'tts5'`. New `_resolveTtsSelection()` helper sits alongside the existing two.

### What NOT to build yet

A UI dropdown for TTS switching, OR a top-level `TwaiClient(ttsSelection: …)` constructor argument. The slot/voice coupling is the real complexity — letting a user pick "11labs" at runtime would silently break against any avatar whose voice UUID was minted on Qwen. Set it once via env config until we have the `VoiceProfile` abstraction below.

### Pipeline-tracker tightening (admin side)

`PipelineRecord` in `apps/admin/lib/src/pipeline/pipeline_record.dart` should grow a `ttsSelection` field so each voice UUID is tagged with the engine it was minted on. The admin can then **warn** before registering an avatar whose voice doesn't match the configured production TTS slot. Prepares the data model for `VoiceProfile` without forcing the abstraction yet.

---

## Longer-term: the `VoiceProfile` abstraction

When the SDK starts supporting more than one TTS engine in production, the slot and the voice should be bundled at the type level so they can't drift:

```dart
class VoiceProfile {
  final String ttsSelection;   // 'tts5', 'tts9', etc.
  final String voiceId;        // ref_audio_id valid on THAT engine
  const VoiceProfile({required this.ttsSelection, required this.voiceId});
}

class Avatar {
  final String id;
  final VoiceProfile? voiceProfile;   // replaces the loose voiceId field
  const Avatar({required this.id, this.voiceProfile});
}

// Session factory accepts an optional override too:
twai.mseStreamSession(defaultVoiceProfile: VoiceProfile(...));
```

The pairing is enforced at the type level — you can't accidentally send a Qwen UUID through an 11labs session. The `Avatar` knows which engine its voice lives on; the session can validate at connect time.

**When to promote:** when there's a second TTS engine in production *and* a real customer asking for it. The cost of the abstraction today is bigger than the foot-gun it prevents — there's only one engine. Today's loose strings are fine.

---

## TTS pronunciation rules — the data-driven layer (Mason, 2026-05-22 to 2026-06-15)

**Major architectural addition** on `mason/tts-global-pronunciation` branch (penthouse repo). Not yet visible to the SDK — captured here because (a) any SDK-side customer test against the streaming pipeline now goes through this layer, and (b) the `app:<id>` and `avatar:<id>` scoping is the foundation for per-customer pronunciation rules when we go multi-tenant. Source: [`docs/TTS_RULES.md`](https://github.com/coreledgergroup/clg_penthouse_pets/blob/mason/tts-global-pronunciation/docs/TTS_RULES.md) on penthouse.

### What it is

Before this landed, fixing a pronunciation meant editing Python on the wav2lip-training VM (`brain_llm.py` / `ttsreal.py`), pushing via `push_vm_file.py`, and restarting `inf_worker_0` — which cut every active session. Now pronunciation patches are **data**, not code:

- **Source of truth:** `backend/data/tts_rules.json` in the penthouse repo. Edit → PR → merge.
- **Hot-reload:** the wav2lip-training VM polls `GET /api/tts/rules` once a minute, atomically writes `/home/azureuser/old_2Ddigital/tts_rules.json`, and the in-process loader picks it up on mtime change. **Zero service restart, zero session interruption.**
- **Fail-open:** broken JSON / missing file / bad regex → loader logs and falls back. TTS keeps working; pronunciation just regresses to the last good cache or to no patches at all.

### The two stages (where rules run in the chat flow)

| Stage | Process | When | Owns |
|---|---|---|---|
| `brain_normalize` | `main_service` → `brain_llm.py::_normalize_for_tts` | Right after the brain emits a TTS-bound clause, before it leaves main_service | Acronyms (`SUV` → `ess you vee`), brand/name substring overrides (`kenan` → `keenan`), broad contraction expansion (`won't` → `will not`) |
| `tts_prepass` | `inf_worker_0` → `ttsreal.py::txt_to_audio` | Right before `POST /v1/tts` to the Qwen3 server on `labs-gpu-01` | Markdown / `[CARD:…]` strip, curly apostrophe normalize, `'s` lookup table with phonetic respellings (`what's` → `wuts`), `I'm`/`I'd` expand, hyphen split, possessive `'s` rewrites (`Po's` → `Poes`) |

### v2 schema: scoped layers

```json
{
  "schema_version": 2,
  "precedence": ["global", "app", "avatar"],
  "layers": {
    "global":                      { "brain_normalize": {...}, "tts_prepass": {...} },
    "app:penthouse-pets":          { "brain_normalize": {...} },
    "avatar:krystal-harper":       { "tts_prepass":     {...} }
  }
}
```

Layer keys are one of:
- `"global"` — always runs
- `"app:<id>"` — runs only when `apply_*(text, app=<id>, ...)` is called
- `"avatar:<id>"` — runs only when `avatar=<id>` is passed

**Merge order = precedence** (`global → app → avatar` by default); passes from each layer are concatenated in that order, and later passes win on conflicts.

### Per-pass and per-rule language gating

Any pass or rule can carry `"lang": ["en"]` / `"lang": ["zh"]` / `"*"`. The runtime detects CJK vs Latin via `_CJK_RE` when the caller passes `lang="Auto"` (the production default). **Known gap:** the CJK regex covers Han + Kana but not Hangul (Korean); Korean text would resolve to `"en"` and run English passes. Tracked as a follow-up.

### Six pass kinds

| `kind` | Behavior |
|---|---|
| `lowercase` | `text.lower()` |
| `regex_subs` | `re.sub(pattern, replace)` per rule, in order |
| `substring_subs` | `text.replace(find, replace)` per rule, in order |
| `has_participles` | For each listed word, rewrites `X's <word>` → `X has <word>` |
| `lookup_apos_s` | For `'s`-suffixed tokens, replaces from table if bare word matches |
| `acronym_spell` | Detects ALL-CAPS-ish tokens, spells letter-by-letter via phonetic map; preserves plural `s`. Has `keep_as_word` exception list (e.g. `NASA` stays `nass-uh`). |

### Entry-point API

```python
# main_service side
from tts_rules_loader import apply_brain_normalize, apply_tts_prepass

normalized = apply_brain_normalize(text, app=None, avatar=None, lang=None)
prepass    = apply_tts_prepass(text, app=None, avatar=None, lang=None)
```

The byte-identical loader file lives in both `main_service/factories/llm/tts_rules_loader.py` and `inference_service/tts_rules_loader.py` — they read the same JSON file, with different stages active per process.

### What this means for the SDK

**Today (zero SDK changes needed):** every `session.sendMessage(text)` call on Adapter 1 already routes through the new pronunciation layer server-side. The text we send is what arrives at the brain; what comes back to TTS gets normalized; what hits Qwen3 has the prepass applied. **Customers don't see this, don't configure it, and don't need to know.**

**Near-term implication (Phase 1, Candy.ai):** the `app:<id>` scoping is exactly the per-customer extension point the SDK will need when multi-tenant. When Candy.ai onboards (shape #2 customer per `integration_shapes.md`), they could ship `app:candy-ai` pronunciation rules to handle their specific persona names without polluting the global ruleset. **No SDK API change** — the customer's session implicitly carries a tenant id; main_service passes it as `app=<id>` to the rules engine.

**Mid-term (Phase 2):** the planned admin-tool roadmap item "voice-id picker" should grow alongside a "**pronunciation rules editor**" — table-driven UI for the rules JSON. Phase 3 of the penthouse TTS_RULES roadmap describes exactly this: list + add/edit/delete with mandatory note field, test-phrase audio preview, audit log, one-click rollback. Our SDK's admin app is the natural home for that UI when we go multi-tenant.

### The `tts_harness` QA tool

Standalone Python package at `tools/tts_harness/` in the penthouse repo. Not part of the SDK; documented here for completeness because it's how Mason validates new pronunciation rules before they ship. Loop:

1. **Discover** — run a corpus (avatar names, brand words, adversarial probes) through current rules, synth via Qwen3, transcribe with two STT "ears", score phoneme-first divergence (`55% weighted phoneme edit distance + 30% normalized Levenshtein + 15% Metaphone gate`). Flag anything ≥ 0.35.
2. **Correct** — for each flagged finding, generate candidate respellings from known Qwen quirk families (`hyphen splitting, ey→uy, ey→y, vowel lengthening, y→ie, ph→f, first-vowel doubling, etc.`), re-synth across 3 deterministic seeds (7/11/23), pick argmin if it beats baseline by ≥ 0.15.
3. **Regression battery** — insert the proposed rule into a temp copy of `tts_rules.json`, run the legacy 32+ assertion test suite. Only candidates that pass everything are forwarded.
4. **Mandatory human review** — `review.build_review_page` renders a self-contained HTML page with before/after audio, transcriptions, confidence score, approve/reject buttons. No rule lands in `tts_rules.json` without a human approving it in this page.

CLI commands: `pilot` (rules-OFF vs rules-ON corpus), `discover` (listening loop), `correct` (candidate generation), `probe-one` (one term). Lock-file guard prevents two harness runs from hammering shared prod boxes.

**When the SDK ships a customer-facing pronunciation editor (Phase 2 admin):** this harness is the reference for what the "test phrase" preview should call. The harness exposes the synth+score+candidate-gen primitives cleanly enough that the admin tool can reuse them.

---

## SDK surface — what customers actually call

**Shipped in `twai_avatar_sdk_core` as of 2026-06-27** (commits land same day as this section). The SDK now exposes the pronunciation rules layer as a typed API on `AvatarAdminClient` so customers / admin UIs can manage rules without touching `tts_rules.json` directly. **Important:** the backend REST endpoints below are **not yet live** — Mason's `main_service` only exposes `GET /api/tts/rules` today (for the VM cron poll), not the CRUD path the SDK calls. The SDK shape is in place so customer code + admin UI (SDK-29) can be built against a stable contract; calls will 404 until Mason wires the routes.

### Types ([`packages/twai_avatar_sdk_core/lib/src/admin/tts_rules.dart`](../packages/twai_avatar_sdk_core/lib/src/admin/tts_rules.dart))

```dart
// Scope — sealed-ish value type mirroring Mason's three layers.
TtsRuleScope.global                              // 'global'
TtsRuleScope.app('candy-ai')                     // 'app:candy-ai'
TtsRuleScope.avatar('krystal-harper')            // 'avatar:krystal-harper'
TtsRuleScope.parse('app:foo')                    // round-trips from wire

// Stage — which of Mason's two stages this rule runs in.
enum TtsRuleStage { brainNormalize, ttsPrepass }

// Kind — which of the six pass kinds. Body shape varies per kind;
// see TtsRuleKind doc comments for the per-kind schema.
enum TtsRuleKind {
  lowercase,        // body: {}
  regexSubs,        // body: { "rules": [{"pattern","replace","note"}] }
  substringSubs,    // body: { "rules": [{"find","replace","note"}] }
  hasParticiples,   // body: { "words": [...] }
  lookupAposS,      // body: { "table": {...}, "match_pattern": "..." }
  acronymSpell,     // body: { "pattern","keep_as_word","letter_phonetic" }
}

class TtsRule {
  final String? id;              // server-assigned; null pre-insert
  final TtsRuleScope scope;
  final TtsRuleStage stage;
  final TtsRuleKind kind;
  final Map<String, dynamic> body;
  final String note;             // mandatory; surfaces in admin UI
  final List<String>? lang;      // ['en'], ['zh'], ['*'] or null = all
  // copyWith, toJson, fromJson
}

class TtsAuditionResult {
  final Uint8List audioBytes;    // drop into <audio>
  final String    audioMimeType; // 'audio/mpeg' typically
  final String    transcript;    // STT-back read of the synth
  final double?   divergence;    // harness scorer; null if not run
}
```

### Five methods on `AvatarAdminClient` ([`avatar_admin_client.dart`](../packages/twai_avatar_sdk_core/lib/src/admin/avatar_admin_client.dart))

```dart
final admin = twai.admin(developerMode: true);

// List, optionally filtered by scope and/or stage.
final rules = await admin.listRules(
  scope: TtsRuleScope.app('candy-ai'),
  stage: TtsRuleStage.brainNormalize,
);

// Create (server assigns id and echoes back).
final created = await admin.addRule(TtsRule(
  scope: TtsRuleScope.app('candy-ai'),
  stage: TtsRuleStage.brainNormalize,
  kind: TtsRuleKind.substringSubs,
  body: {'rules': [{'find': 'amazon', 'replace': 'ammazon'}]},
  note: 'User reported "amazon" pronounced wrong, 2026-06-27',
));

// Replace by id (PUT semantics — full overwrite, no patching).
await admin.updateRule(created.id!, created.copyWith(note: 'tweaked note'));

// Delete by id.
await admin.deleteRule(created.id!);

// Audition: synth + STT-back + (optional) candidate-rule overlay.
final result = await admin.auditionPhrase(
  phrase: 'amazon delivers everything',
  voiceId: '<voice-uuid>',
  ttsSelection: 'tts5',
  candidateRules: [created],   // overlay this rule on top of current ruleset
);
// result.audioBytes → <audio src="data:audio/mpeg;base64,...">
// result.transcript → 'ammazon delivers everything'
// result.divergence → 0.04
```

### Wire contract (proposed; confirm with Mason when wiring backend)

| Method | HTTP | Path | Status |
|---|---|---|---|
| `listRules` | `GET` | `/ext-api/tts/rules?scope=…&stage=…` | 🔧 Backend not yet exposed |
| `addRule` | `POST` | `/ext-api/tts/rules` | 🔧 Backend not yet exposed |
| `updateRule` | `PUT` | `/ext-api/tts/rules/<id>` | 🔧 Backend not yet exposed |
| `deleteRule` | `DELETE` | `/ext-api/tts/rules/<id>` | 🔧 Backend not yet exposed |
| `auditionPhrase` | `POST` | `/ext-api/tts/audition` | 🔧 Backend not yet exposed; wraps `tts_harness` synth+STT+score primitives |

All wrap the standard `{code, data, …}` envelope used by every other admin endpoint; non-zero `code` throws `AvatarAdminProtocolException`. HTTP failures get the same typed-exception ladder as the rest of `AvatarAdminClient` (`AvatarAdminUnauthorizedException`, `…Forbidden`, `…RateLimited`, `…Http`, `…Transport`).

### Why expose this in the SDK before the backend exists

Three reasons:

1. **The schema is locked** — Mason's v2 schema + 6 pass kinds have shipped on penthouse (production). SDK-side types unlikely to drift even if backend URLs end up slightly different. Cheap to land now; cheap to wire later.
2. **Admin UI work (SDK-29) is unblocked** — the Flutter admin app can build the pronunciation editor screen against a real Dart contract instead of waiting for the backend. When Mason ships endpoints, no SDK code change needed; admin UI just starts working.
3. **Customer integration conversations are unblocked** — when pitching Candy.ai (or any future customer) on tenant-scoped pronunciation rules, we can hand them Dart code that compiles and a clear "this is the contract" doc, rather than a backend-side JSON schema they'd need to wrap themselves.

### Customer code never touches `tts_rules.json`

Per the dual-audience principle in [`architecture.md`](architecture.md): the SDK is the contract. Customers see Dart types (`TtsRule`, `TtsRuleScope`, etc.) and method calls. They never see the JSON file on the wav2lip-training VM, never see `/api/tts/rules`, never need to know that Mason's hot-reload poll runs once a minute. **What 2wai's own team does to manage Penthouse rules (PR-to-penthouse-repo) and what an SDK customer does (REST CRUD against the SDK methods above) are two different workflows that converge on the same underlying engine.**

---

## Brain mood layer — typed SDK surface (Path A, shipped 2026-06-28)

Adjacent to TTS but **separate engine**: Alex Finden's brain mood/r14 system in `2waiorg/avatar-brain/src/core/mood/` emits a mood per turn that drives persona behavior (mood directive injected into the system prompt) and surface display (icon, tooltip). The brain ships the mood via an SSE `event: mood` frame; `main_service` Patches #62 echo it as two response headers on `POST /ext-api/human`:

| Header | Carries | Example |
|---|---|---|
| `X-Mood` | The closed 9-slug vocabulary from the brain roster | `homesick`, `frisky`, `mad`, `afterglow` |
| `X-Mood-Humanized` | Per-avatar tooltip — different mapping per persona (`<AVATAR>_TOOLTIP_NAMES` in `roster.py`) | `Sophi is feeling sad`, `Bella is feeling tender` |

The SDK captures both into a typed `MoodEvent`:

```dart
final mse = twai.mseStreamSession(...);
mse.moodEvents.listen((MoodEvent ev) {
  // ev.mood       — typed Mood enum (or Mood.unknown for forward-compat)
  // ev.slug       — raw wire slug, preserved verbatim
  // ev.humanized  — per-avatar tooltip text, or null if absent
  switch (ev.mood) {
    case Mood.frisky:      // tint the background pink
    case Mood.homesick:    // dim the lighting
    case Mood.mad:         // angry icon
    case Mood.unknown:
      log.info('new mood slug from brain: ${ev.slug}');
  }
});
```

**The vocabulary is locked to 9 slugs across every brain avatar** (Sophi, Bella Reid, Bella Vaunt, Krystal Harper, Tahlia Paris — same set, only tooltip strings differ). A drift-guard test in the core suite pins this set; if Alex adds a new mood, that test fails and reminds us to extend the `Mood` enum. Until that catch happens, `Mood.unknown` keeps customer code working — `MoodEvent.slug` still preserves the raw wire value so callers can still log / branch on it.

**No backend changes needed** — Mason's main_service already echoes both headers; this commit just types the SDK side. The brain mood directives (the ~115–285-token blocks injected into the system prompt) stay server-side and are never surfaced to clients — only the slug + humanized tooltip cross the API boundary.

---

## Admin tool: voice generation + UUID

Today, voice UUIDs are pasted into the admin's add-avatar form by hand. Allie sources them from Mason after he clones the voice on Qwen via SSH or a script. The roadmap entry to clean this up requires a backend endpoint we don't have yet.

### Why the admin can't call Qwen directly

- Qwen service is on `http://13.66.166.59:7865` — internal Azure IP, plain HTTP.
- Browsers block mixed-content (HTTPS admin → HTTP API).
- The service likely doesn't send `Access-Control-Allow-Origin` headers (CORS).
- Even if both were fine, exposing the internal Qwen IP to admin users is a bad shape.

### Recommended: proxy through `main_service`

**Backend ask (~half a day on Mason's side):**

```
POST /ext-api/clone_voice
Authorization: Bearer sk_live_...
Content-Type: multipart/form-data
  ref_audio: <wav file>
  ref_text: <transcript string>
  ref_label: <human-readable name, e.g. "jesus voice clone 1">   # optional

Response:
{ "code": 0, "data": "ok", "voice_id": "<new uuid>" }
```

`main_service` receives the multipart, validates the secret key, forwards to Qwen's `POST /v1/reference/audio`, returns the new UUID. Hides the internal IP, adds auth, and gives us a stable surface — when 11labs lands as `tts9`, the same endpoint can accept a `tts_engine` parameter and route to either Qwen or 11labs voice-cloning APIs.

**SDK addition (~1 hour) once the endpoint exists:**

```dart
class AvatarAdminClient {
  Future<String> cloneVoice({
    required List<int> refAudioBytes,
    required String refText,
    String? ttsEngine,         // defaults to server's default engine
    String? label,             // optional human-readable identifier
  });
}
```

**Admin UI addition (~half a day) once the SDK method exists:**

A "Generate voice" panel on the pipeline detail screen, next to the existing `voice_id` field:

- File picker for the reference audio (Flutter web's `file_picker` or raw `<input type=file>` via `package:web`).
- Text field for the `ref_text` transcript.
- "Generate" button → spinner → returned UUID auto-populates the record's `voice_id` field.
- Optional "Replay" button that POSTs to a sibling `POST /ext-api/tts_preview` endpoint so Allie can audition the cloned voice before registering the avatar.

This shape also gives us the "voice-id picker" roadmap item for free — same proxy, GET endpoint instead of POST, list existing clones rather than mint new ones.

---

## Testing another TTS engine — ElevenLabs case

Worked example: what it takes to prove out `tts9=ElevenLabs` end-to-end. Two phases — a cheap sanity check that needs almost no infrastructure, then a real end-to-end test that needs backend work. Don't skip phase 1.

### Phase 1 — Voice-only sanity check (~1 hour, $0 infra)

**Goal:** confirm 11labs *sounds good* with the chosen reference audio, before anyone commits to the backend integration.

**What you need:**
1. **An 11labs account.** Free tier is enough for the sanity check (10k characters/month). Paid plan only matters once you're projecting real production volume.
2. **API key.** Account → Profile → API key. Treat it like a secret key.
3. **The reference audio** you'd clone — for Jesus that's `jesus_voice_1_full_9.9s.wav` (Mason 2026-04-30).
4. **A handful of test phrases** representing real avatar output. Mix short (3 words), medium (a sentence), long (a paragraph), and emotionally-loaded (the kind of thing Jesus actually says).

**What you do:**
1. Upload the reference audio to 11labs as an instant voice clone (Voices → Add → Instant Voice Cloning → upload `.wav` + name it). 11labs returns a `voice_id` (their UUID, namespace separate from Qwen).
2. For each test phrase, `curl` the 11labs streaming endpoint and pipe the audio to a player:
   ```bash
   curl -X POST "https://api.elevenlabs.io/v1/text-to-speech/<voice_id>/stream" \
     -H "xi-api-key: <api_key>" \
     -H "Content-Type: application/json" \
     -d '{"text":"Peace be with you, my child.","model_id":"eleven_turbo_v2_5","voice_settings":{"stability":0.5,"similarity_boost":0.75}}' \
     --output reply.mp3
   ```
3. A/B against the same phrases generated by Qwen3 (via the lipsync test UI at `krystal:7860`, or by hitting the Qwen service's `/v1/tts` endpoint).

**What you're listening for:**
- Voice similarity to the reference vs Qwen's output of the same reference.
- Prosody / inflection on the emotional phrases.
- Latency for first audio byte (you want to feel whether 11labs streaming is competitive with Qwen's local-on-VM latency).
- Robustness on long phrases (Qwen sometimes degrades on >200-char inputs; does 11labs hold up?).

**Decision gate:** if 11labs sounds materially better than Qwen for the kind of content you ship, commit to phase 2. If it sounds the same or worse, save the engineering effort.

### Phase 2 — End-to-end lip-synced pipeline test (~2 days backend + ~half a day verification)

**Goal:** prove the full pipeline (user message → LLM → 11labs TTS → Wav2Lip → fragmented MP4 to client) works on `tts9` against a registered avatar.

**What you need:**

| Item | Owner | Notes |
|---|---|---|
| 11labs API key as a `main_service` env var | Mason | Server-side secret; never goes to the SDK. |
| 11labs adapter in `main_service` | Mason | Module that maps `ttsSelection='tts9'` → 11labs streaming TTS API. Should ideally stream WAV / PCM chunks into `inference_service`'s audio pipeline rather than buffering the whole clip — Wav2Lip works frame-by-frame. |
| Confirmation that `inference_service` can consume 11labs audio | Mason | Audio format compatibility: 11labs streams MP3 by default; need PCM-16-mono-16kHz for the muxer. Either request `output_format=pcm_16000` from 11labs or transcode in `main_service`. |
| Test voice cloned on 11labs | Allie | Same reference audio as Qwen — apples-to-apples. Get the 11labs voice_id back. |
| Test avatar registered with the 11labs voice id | Jim (admin tool) | Pick a parallel avatar id like `RedJesusTalk1_11labs` so you don't have to delete the existing one. Use the existing admin add-avatar form. Voice id field = the 11labs UUID. |
| Client-side: switch `TWAI_TTS_SELECTION` to `tts9` and `_avatar.id` to the test avatar | Jim | One-line change in `apps/jesus/.env` (once the `.env` knob from this doc is shipped) + one-line change in `main.dart`. |
| Latency measurement | Jim | Use the stats panel's existing `bytesReceived` / `framesReceived` / `lastSpeaking.pts` to compare time-to-first-frame between the two avatars. |
| Cost projection | Jim | 11labs price-per-character × average reply length × expected sessions/month. Compare against Qwen (essentially fixed cost since it runs on `labs-gpu-01`). |

**What you measure:**
- **Latency budget:** does the streaming first-frame stay under 2s perceived? Qwen runs on the same network as `inference_service`; 11labs adds an internet round-trip. Mason's adapter should request 11labs streaming (`/stream` endpoint, not `/text-to-speech/<id>` non-streaming) to give Wav2Lip something to chew on as soon as possible.
- **Quality at full pipeline:** the lip-sync may amplify or hide subtle audio issues differently than the voice-only sanity check did.
- **Cost extrapolation:** 11labs charges per character; an average Jesus reply runs ~300 characters. At Turbo v2.5 pricing (~$0.18/1k chars) and 10 turns/session × 1000 sessions/day, that's $540/day. Qwen on `labs-gpu-01` is the VM cost, period — much cheaper at volume.
- **Failure modes:** what happens when 11labs is rate-limited? Errors out? Times out? Need `main_service` to surface these cleanly through the existing `MseStreamCloseReason` taxonomy.

**Verification checklist:**
1. Register the test avatar via the admin tool's Feature 1. Confirm `readyAvatars()` lists it.
2. Change Jesus's `.env` → `TWAI_TTS_SELECTION=tts9` and point `_avatar.id` at the test avatar.
3. Run Jesus on a validated platform (Web in Chrome is the lowest-friction). Send a few test phrases.
4. Watch the stats panel for `bytesReceived` increasing, `lastSpeaking` events firing, video rendering. Compare time-to-first-frame against a Qwen baseline run.
5. Listen for audible quality differences at the full pipeline.
6. Run for ~50 turns to surface any rate-limit / error-handling issues.

### What you specifically need to gather to make phase 2 happen

This is the **Jim-side checklist** for kicking off the 11labs proof-out — what you need to have ready before talking to Mason:

- [ ] **Decision:** is this a one-off voice swap test (just Jesus), or are you evaluating 11labs as the engine for a broader rollout? Affects how much backend infra Mason builds.
- [ ] **11labs account access** — either 2wai's existing one (if any) or a new one created with the team's billing card. The cloning step requires a paid tier in practice.
- [ ] **Reference audio file** — the same `.wav` you'd want Qwen to clone, so the comparison is fair.
- [ ] **Test phrases** — 10–20 phrases covering short / medium / long / emotional. Worth writing them down before the test so you're comparing the same set across engines.
- [ ] **Baseline measurements from Qwen** — run the same test phrases on the current Qwen-backed Jesus first, record time-to-first-frame + perceived quality notes. Without a baseline, the 11labs numbers are floating.
- [ ] **Cost ceiling** — what's the most you'd be willing to spend per Jesus session for the voice quality upgrade? Tells Mason whether 11labs is even worth integrating before he writes the adapter.
- [ ] **A parallel test avatar id reserved** — e.g. `RedJesusTalk1_11labs`. Pick the name before registration so it doesn't collide with anything else in the registry.
- [ ] **Mason's confirmation** of the backend scope — proxy through `main_service` or a separate microservice; streaming PCM or buffered MP3; how 11labs errors surface to the SDK's typed exception ladder.

Everything else (admin tool registration, .env switch, client-side test) is already in your hands.

---

## Where this lands on the SDK roadmap

- **Ship-now (no dependencies):** `.env` knob for `TWAI_TTS_SELECTION` in Jesus + `ttsSelection` field on `PipelineRecord`. ~half a day total, no backend ask, no risk.
- **Backend-blocked:** `POST /ext-api/clone_voice` proxy endpoint, then `AvatarAdminClient.cloneVoice(…)` SDK method, then admin "Generate voice" panel. ~1 day SDK + UI once the endpoint exists. Mason's team owns the backend half.
- **Customer-blocked:** `VoiceProfile` abstraction. Promote when a second TTS engine ships in production and a customer is exercising both.
- **Pure-validation:** the 11labs phase 1 sanity check. Anyone with an 11labs account and the reference audio can do this in an afternoon.

Cross-references in the other docs:
- `sdk_overview.md` already lists "Brain SSE direct mode" and the "voice-id picker" as roadmap items adjacent to this.
- `admin.md` lists the voice-id picker as a near-term polish; this doc deepens that into the full clone-voice flow.
- `candy_ai_fit.md` flags ElevenLabs as Candy.ai's current TTS — the `tts9` work is a meaningful step toward unblocking that integration.
