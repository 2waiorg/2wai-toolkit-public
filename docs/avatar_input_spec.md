# 2wai Avatar Input Specification

**Date:** 2026-07-18
**Purpose:** The artifact contract between the avatar-generation / admin tool and the 2wai Avatar Player. What inputs must a completed avatar produce for the player to work end-to-end?
**Basis:** Reverse-engineered from `c:\Dev\clg_penthouse_pets\frontend\src\lean\avatars.ts`, `c:\Dev\2wai-avatar-pipeline\docs\PIPELINE_SPEC_V1.3.md`, and the inference/muse worker code paths on the krystal VM. Cross-checked with the port spec at `docs/port_spec_avatar_player.md`.

> **Living document.** Mason has committed to publishing an authoritative version of this on the wiki once he finalises the MuseTalk API contract (see PRD §9 Q1). Until then, this doc is our best-effort inference from live production code, marked with citations. Where we're uncertain, we flag it. This doc gets folded into Mason's canonical version once his lands.

---

## 1. The mental model

An avatar in the 2wai system is a bundle of **five artifact families** the player composes at runtime:

| Family | What it is | Where it goes |
|---|---|---|
| **Identity + persona** | avatar_name (pipeline slug), voice UUID, persona prompt, catalog metadata | Backend registry + brain config |
| **Baked talk sources** | Talking-clip MP4s → baked into MuseTalk latents on the krystal VM | Referenced by `pipelineName` at handshake; never fetched by client |
| **Idle & seam clips** | Idle MP4s (rotation set + canonical `Default`) fetched by the player | CDN (Azure blob `2waiassets.blob.core.windows.net/avatars/`) |
| **Expression clips** | Emote clips + frame clips + outfit-transition clips | CDN |
| **Thumbnails & posters** | Poster JPG + animated WebP preview per outfit | CDN, referenced by the panel UI |

The player is stateless with respect to avatars — everything it needs is in these five families. Adding a new avatar means producing them; nothing else about the player changes.

---

## 2. Identity + persona

### 2.1 Avatar record shape

Mirrors [avatars.ts:53-59](../../clg_penthouse_pets/frontend/src/lean/avatars.ts#L53-L59):

```typescript
type Avatar = {
  slug: string        // 'krystal-harper' — URL-safe, human-readable
  name: string        // 'Krystal Harper' — display
  tagline: string     // One-line hook shown in catalog
  voice: {
    ttsSelection: string    // 'tts5' = Qwen3 (production default)
    avatarVoice: string     // UUID = ref_audio_id in Qwen3 store
  }
  outfits: Outfit[]
}
```

### 2.2 Voice
- **`ttsSelection`**: TTS engine slot. Current production = `'tts5'` (Qwen3 voicelab). See `docs/voice_and_tts.md` for the full slot table.
- **`avatarVoice`**: UUID pointing at a `ref_audio_id` in Qwen3's ref_audio store. Voice-clone service hosted at labs-gpu-01. Must exist in the store before an avatar can speak.

### 2.3 Persona / prompt
Lives in the brain config (Alex Finden's avatar-brain repo). Not part of the visual asset pipeline — passed as text to the brain endpoint at chat time. Format: freeform system prompt, plus optional mood configuration.

### 2.4 Catalog entry (in the SDK / product surface)
- `slug`, `name`, `tagline` — customer-facing display
- Outfit list — required, min 1 outfit (typically 3-4)
- `unlockLevel?: number` — for products that use tier gating (Casual=1, Date=10, Swim=20, Nude/Lingerie=30 per Penthouse PRD; other products define their own or skip)

---

## 3. Outfits — the core unit of avatar content

An outfit is one wardrobe/scenario variant of an avatar. Multiple outfits per avatar (e.g., Casual, Date, Swim). Mirrors [avatars.ts:12-51](../../clg_penthouse_pets/frontend/src/lean/avatars.ts#L12-L51):

```typescript
type Outfit = {
  slug: string             // 'casual'
  name: string             // 'Casual'
  pipelineName: string     // 'KrystalHarperCasualTalk1' — baked talk source
  pipelineNames?: string[] // Rotation set (see §3.1)
  idleUrl: string          // Fallback single-idle URL (see §3.2)
  idleUrls?: string[]      // Rotation set (see §3.2)
  defaultIdleUrl?: string  // Canonical seam frame-0 idle (see §3.3)
  posterUrl: string        // Thumbnail JPG
  previewUrl: string       // Animated WebP preview
  unlockLevel?: number     // Optional tier gate
}
```

### 3.1 Baked talk sources (`pipelineName` / `pipelineNames`)

**What:** Backend-baked variants of a talking-clip video. Reference by name only — client never fetches them directly.

**Naming convention:** `{AvatarName}{Outfit}Talk{N}` — e.g., `KrystalHarperCasualTalk1`, `KrystalHarperCasualTalk2`, `KrystalHarperCasualTalk3`.

**Rotation:** If `pipelineNames` is present (typically 3 substrates), the player picks one at random per session (see port spec §9). Fresh visits feel different.

**Backend prerequisites (per [PIPELINE_SPEC_V1.3.md:250-259](../../2wai-avatar-pipeline/docs/PIPELINE_SPEC_V1.3.md#L250-L259)):**
| Property | Value |
|---|---|
| Source clip length | 10–30s each |
| Minimum per outfit | 3 clips |
| Face | Frontal, consistent lighting |
| Native resolution | 512×512 or 256×256 (Wav2Lip); MuseTalk has larger crop tolerance |
| Frame rate | 25 fps (matches output) |
| Audio | Present for reference alignment (discarded after preprocessing) |

**Bake output:** metadata + latents baked into the muse worker's model store on the krystal VM. Mason's per-clip bake pipeline (see 2026-07-17 transcript §12) handles: derot processing (left/right head tilt tracking), lip-region mask, latent extraction.

**Not yet ported to a public bake API.** Mason plans to expose this as `POST /api/muse/bake` (see PRD §4.3). Until then, adding a new avatar is a Mason-driven manual process.

### 3.2 Idle clips

**What:** MP4s the player loops as the visible "resting" state between conversation turns.

**Naming convention** (observed): `{AvatarName}/{Outfit}/Idle/{Avatar}_{Outfit}_Idle{N}.mp4` and `..._IdleDefault.mp4`.

**Fields:**
- `idleUrl` — fallback single-clip URL. Required.
- `idleUrls` — optional rotation set. If present, player picks one at random per session (see port spec §8).
- `defaultIdleUrl` — canonical **seam** idle (§3.3 below). Different role from rotation. Required if you use emotes / frames / outfit transitions.

**Format (inferred, needs Mason confirmation):**
| Property | Value |
|---|---|
| Container | MP4 (H.264 video, AAC audio if any) |
| Frame rate | 25 fps (matches talk source) |
| Resolution | Match talking clip; typically 720p portrait 9:16 |
| Codec profile | H.264 Constrained Baseline 3.1 (matches MSE `avc1.42C01F`) — **inferred** from live-stream codec, needs bake-pipeline confirmation |
| Duration | 3–15s typical, perfect loop (last frame == first frame for seamless replay) |
| Audio | Typically silent or ambient; muted at playback |
| File size | Optimize for CDN — 500KB – 2MB typical |

### 3.3 The seam / `defaultIdleUrl` — critical

Every emote, frame, or outfit-transition clip is **authored** so its final frame matches the `defaultIdleUrl`'s first frame. This creates a seamless visual seam when the overlay ends and the player calls `playIdleFromStart()`.

**Requirements for `defaultIdleUrl`:**
- Same encoding as other idles
- Its frame-0 must be the canonical "rest pose" that all overlays end on
- Never randomised; used deterministically at every seam
- Recommended: pick one of the rotation clips as `defaultIdleUrl` (Krystal's catalog uses `..._IdleDefault.mp4` for both roles)

### 3.4 Posters / previews

- **`posterUrl`**: JPG thumbnail (same aspect ratio as video). Used in outfit-selection tiles. Path convention: same as `idleUrl` with `.jpg` suffix.
- **`previewUrl`**: animated WebP (~150 KB, 480p, 12fps, 3s loop, per [avatars.ts:38-44](../../clg_penthouse_pets/frontend/src/lean/avatars.ts#L38-L44)). Renders via `<img>` so it bypasses iOS hardware video decoder slots — critical for showing many simultaneous outfit previews without saturating the media pipeline.
- Both generated by `scripts/extract_idle_previews.py` in the Penthouse repo; equivalent script needed for other product apps.

---

## 4. Expression clips (emotes, frames, transitions)

### 4.1 Emotes

**What:** Short expressive video clips (wave, kiss, heart-hands, celebrate, thumbs-down, clap, etc.). Played as a muted overlay on user tap.

**Server side:**
```typescript
type Gesture = {
  id: string
  slug: string              // 'wave', 'kiss', 'heart-hands', ...
  display_name: string      // 'Wave' — panel label
  video_url: string
  thumbnail_url: string | null
  is_unlocked: boolean
  unlock_level?: number
  outfit_slug?: string      // optional per-outfit restriction
}
```

**Fetched via** `GET /ext-api/gestures/{avatar_slug}` (side-loaded on idle canplay).

**Format:**
| Property | Value |
|---|---|
| Container | MP4 (H.264) |
| Duration | 1–3s typical |
| Frame rate | 25 fps |
| Resolution | Match idle |
| Seam constraint | **Last frame == `defaultIdleUrl` first frame** |
| Audio | Present but muted at playback (`emoteVid.muted = true`) |
| Naming | Free — referenced by URL from server response |

**Path convention** (observed): `{AvatarName}/{Outfit}/Expressions/{Avatar}_{Outfit}_{ExpressionName}.mp4`

### 4.2 Frames

**What:** Longer per-outfit clips (5–10s). Same overlay mechanism as emotes but louder role — with sound.

```typescript
type Frame = {
  id: string
  slug: string
  frame_number: number
  outfit_slug: string       // Required — frames are outfit-scoped
  unlock_level: number
  main_clip_url: string
  thumbnail_url: string | null
  is_unlocked: boolean
}
```

**Fetched via** `GET /ext-api/frames/{avatar_slug}`.

**Format:**
| Property | Value |
|---|---|
| Container | MP4 (H.264 + AAC) |
| Duration | 5–10s typical |
| Frame rate | 25 fps |
| Resolution | Match idle |
| Seam constraint | **Last frame == `defaultIdleUrl` first frame** |
| Audio | Present and unmuted at playback (`emoteVid.muted = false`) |

### 4.3 Outfit-transition clips

**What:** MP4 that plays as the visual bridge when a user swaps outfits (Bikini → Yellow, Yellow → Black, etc.).

**Discovery:** `findTransition(oldSlug, newSlug)` — implementation in the reference lookups a per-avatar transition map. See [mailgun/frontend/src/api/avatars.ts:90-94](../../mailgun/frontend/src/api/avatars.ts#L90-L94) for the shape:
```typescript
{ from_slug: 'bikini', to_slug: 'yellow', video_url: '...' }
```

**Format:**
| Property | Value |
|---|---|
| Container | MP4 (H.264) |
| Duration | 1.5–4s typical (long enough for outfit change to be believable) |
| Frame rate | 25 fps |
| Resolution | Match idle |
| Seam constraint | **First frame ~= previous outfit's `defaultIdleUrl` first frame; last frame == new outfit's `defaultIdleUrl` first frame** |
| Audio | Typically silent |

Optional per outfit-pair. If missing, the player does an immediate `swapIdleToNext()` with no transition overlay (see port spec §2.5).

---

## 5. Streaming assets (never fetched by client)

These aren't in the "customer-uploads-these" bucket — they're server-side and streamed live during conversation. Listed for completeness so the avatar generation team knows what the pipeline produces:

- **Baked MuseTalk latents** — from talking-clip source (§3.1), per outfit variant
- **Real-time TTS audio** — Qwen3 vLLM on labs-gpu-01, streamed to the muse worker per turn
- **fMP4 stream** — muxed AV output from the muse worker, sent over WS at `/ext-api-muse/mse_stream` (codec `avc1.42C01F, mp4a.40.2` — see port spec §5.4)

---

## 6. Minimum viable avatar

To ship one avatar with one outfit and no expression system:

| Artifact | Count | Required |
|---|---|---|
| Baked talk source (`pipelineName`) | 1 | ✅ |
| Idle clip (`idleUrl`) | 1 | ✅ |
| Poster (`posterUrl`) | 1 | ✅ |
| Voice UUID (`avatarVoice`) | 1 | ✅ |
| Persona prompt | 1 | ✅ (brain-side, not visual pipeline) |
| Preview WebP (`previewUrl`) | 1 | ⚠️ Recommended (better UX in outfit picker) |
| `defaultIdleUrl` | 1 | ⚠️ Only if you use emotes / frames / transitions |
| Idle rotation set (`idleUrls`) | 2–3 | ⚠️ Optional but visible in production |
| Talk rotation set (`pipelineNames`) | 2–3 | ⚠️ Optional but strongly recommended (avoids repetition feel) |

To ship a full production-quality avatar (matches current Penthouse Pets standard):

- 3+ outfits × (3+ talk variants + 3+ idle variants + defaultIdle + poster + preview)
- 5–10 emote clips per outfit (or shared across outfits with `outfit_slug: null`)
- 2–5 frame clips per outfit
- Optional transition clips for outfit pairs users are likely to swap between

---

## 7. Reference paths

Where these artifacts live in current production:

- **Azure blob CDN base:** `https://2waiassets.blob.core.windows.net/avatars/`
- **Directory convention:** `{AvatarName}/{Outfit}/{Idle|Expressions|Frames|Transitions}/{filename}`
- **Bake directory (server-side):** `/home/azureuser/data/avatars/{avatar_name}/` on the krystal VM
- **Voice ref store:** Qwen3 vLLM at labs-gpu-01:7865, keyed by UUID

---

## 8. Open questions for Mason

Flagged in PRD §9 and consolidated here for the input contract specifically:

1. **Idle/emote/frame MP4 codec parameters.** The MSE live stream is verified as H.264 Constrained Baseline 3.1 (`avc1.42C01F`). Do the static CDN MP4s (idles, emotes, frames, transitions) use the same profile, or are they high/main profile? Answer affects whether we can use the same decoder path in Flutter or need two.
2. **Audio sample rate for voice reference clips** uploaded to Qwen3's ref store. 16 kHz? 24 kHz? Format constraints for good clone quality?
3. **Bake API contract** — see PRD §4.3. What does the `POST /api/muse/bake` request/response look like? What options (derot, mask hints, etc.) does it expose?
4. **Master-frame authoring guidance.** How does the content team ensure emote/frame/transition clips end on `defaultIdleUrl`'s first frame? Is there tooling, or is it a manual constraint in the studio?
5. **Preview-WebP generation.** Is `scripts/extract_idle_previews.py` (Penthouse repo) portable to other product apps, or does each product need to build its own?
6. **Audio in idle clips.** Are idles always silent, or can they include ambient audio that plays alongside the avatar (breathing, background)? Player mutes idles today — is that intentional or an artifact of an old constraint?

---

## 9. Cross-references

- **Port spec:** `docs/port_spec_avatar_player.md` (how the player consumes these inputs)
- **PRD:** `docs/prd_2026_07_18.md` §4 (API contracts) + §9 (open questions)
- **Content pipeline PRD** (upstream): reference memory `reference_content_pipeline_prd.md` — master spec for the 8-stage capture-to-bake pipeline
- **Pipeline v1.3 spec:** `c:\Dev\2wai-avatar-pipeline\docs\PIPELINE_SPEC_V1.3.md`
- **Reference catalog:** `c:\Dev\clg_penthouse_pets\frontend\src\lean\avatars.ts`
