# Integration Shapes

> The load-bearing organizing principle for the SDK. Three first-class integration shapes, all equally supported, all serving both 2wai's own products and external customers. Read this before designing anything new or before pitching a customer — it determines almost every architecture choice that follows.
>
> Companion to [`architecture.md`](architecture.md) (internal SDK structure), [`protocol.md`](protocol.md) (wire spec), [`candy_ai_fit.md`](candy_ai_fit.md) (shape #2 reference customer), [`edge_offline_shape.md`](edge_offline_shape.md) (shape #3 reference), [`voice_and_tts.md`](voice_and_tts.md) (the per-stage TTS engineering).

---

## The two foundational principles

### 1. Content creation is central; runtime is portable

The 2wai stack has two separable layers:

| Layer | What it does | Where it lives | Who provides it |
|---|---|---|---|
| **Content creation** | Capture → standardize → color → master frame → glue → morphs → renditions → upload → register. Produces avatar assets (Wav2Lip latents, source frames, voice clones, master frames). | 2wai central (krystal + labs-gpu-01 + content team). The 8-stage pipeline tracked by `apps/admin/`. | **Always 2wai.** This is the moat. |
| **Runtime serving** | STT → LLM → TTS → Render → Stream. Consumes assets, produces talking video for a chat turn. | Anywhere. 2wai cloud, customer cloud, **or fully on the user's device.** | **Customer choice, per integration shape.** |

Mason+Allie's content pipeline mints assets that can run anywhere the customer wants. The runtime is essentially commodity once the assets exist. **2wai's product is the assets and the pipeline that mints them, not the inference servers.**

### 2. Dual audience, single SDK

Two audiences use the same codebase:

| Audience | Examples | How they use it |
|---|---|---|
| **2wai's own product team** | Jesus, Penthouse, future internal apps | Build directly on the SDK. Dogfood it. |
| **Customer integrations** | Candy.ai (in progress), Jonathan's on-device build, future licensees | Consume the SDK from their own apps. Some self-serve, some 2wai-engineers-build-for-them. |

The repo already embodies this — `apps/jesus`, `apps/embed`, `apps/admin`, `apps/candy_demo` all import the same `packages/`.

**Design test that falls out:** *"does Jesus use this the same way Candy.ai would?"* If we're tempted to add an internal-only hook, it goes in `apps/jesus`, not the SDK. If a customer needs something we don't already use ourselves, we add it to the SDK *and* refactor a 2wai app to use it before shipping. Prevents drift between internal and external use.

---

## The 5 runtime stages

Borrowed from Mason's framing during the 2026-06-05 architecture sync. Every chat turn flows through these five stages in order:

| # | Stage | What it does | Default impl |
|---|---|---|---|
| 1 | **Text input** | User types into a chat box | Always client device (trivial) |
| 2 | **STT** (speech → text) | User holds mic; recognizer commits to text | Client: browser `SpeechRecognition` / `speech_to_text` plugin. Server-side path is roadmapped. |
| 3 | **LLM** (brain) | Persona-shaped reply text generation | 2wai central via `/ext-api/human` → Brain Container Apps |
| 4 | **TTS** (text → audio) | Reply text becomes spoken audio | 2wai central via Qwen3 voicelab (tts5) on labs-gpu-01 |
| 5 | **Render + stream** | Audio + avatar frames → Wav2Lip lip-sync → fragmented MP4 over WS | 2wai central via Wav2Lip on krystal-avatar |

Stages 1 and 5 have stable owners (client device for 1; render is the actual product 2wai delivers, modulo where it physically runs). **Stages 2, 3, 4 are the customer-choice axis** — they can be 2wai-owned or customer-owned, hosted in any of several locations.

The 5-stage breakdown is the single source of truth for the per-stage interface model below.

---

## The three first-class integration shapes

Every customer integration the SDK supports falls into one of three shapes. None is "the default" — they're three different propositions, each with a clean story.

### Shape 1 — Hosted full-stack

**2wai runs all 5 stages on our central cloud. Customer's client talks to our backend.**

- **Stages 1, 2:** client (browser SR for STT; user types or speaks; transcripts auto-fill the input)
- **Stages 3, 4, 5:** 2wai central cloud (LLM → TTS → Render → Stream)
- **What customer integrates:** the Web Component embed or the Flutter SDK pointing at our backend
- **Backend wire:** `POST /ext-api/human` + `WS /ext-api/mse_stream` per [`protocol.md`](protocol.md) §1-2
- **Business model:** managed-everything; customer pays per active session

**Used by 2wai for:** Jesus, Penthouse Pets.
**Used by customers for:** anyone who wants managed-everything and doesn't already own LLM/TTS infrastructure.

```
CLIENT                          2WAI CENTRAL
─────────────                  ─────────────────────
text or                        ┌─ LLM ─┐
voice ────────────────────────▶│       │
input                          │ Brain │ → text reply
                               └───┬───┘
                                   ↓
                               ┌─ TTS ─┐
                               │ Qwen3 │ → audio
                               └───┬───┘
                                   ↓
                               ┌─ Wav2Lip + muxer ─┐
                               │   render + stream │
                               └──────────┬────────┘
                                          ↓ (fMP4 over WS)
       ◀──────────────────────────────────┘
   <video> playback
```

### Shape 2 — Hosted render-only

**Customer runs stages 2, 3, 4 themselves. They ship us audio + an avatar id. We run stage 5 only.**

- **Stages 1, 2:** client (Candy.ai's existing chat UI + STT)
- **Stages 3, 4:** customer cloud (their LLM; their TTS, typically 11labs)
- **Stage 5:** 2wai central cloud — accepts audio, runs Wav2Lip against the registered avatar, streams video back
- **What customer integrates:** their existing pipeline produces audio; `<twai-avatar>` plays the rendered video
- **Backend wire:** **NEW endpoint, not built yet** — `render-from-audio` shape that accepts audio bytes + avatar_id, streams fMP4 back over WS
- **Business model:** per-render metering; customer keeps their LLM/TTS bills separate

**Used by 2wai for:** none today (will be the first 2wai customer in this shape).
**Used by customers for:** Candy.ai (canonical example), anyone with their own LLM/TTS stack who wants avatar rendering on top.

```
CUSTOMER PIPELINE                                    2WAI CENTRAL
──────────────────                                  ─────────────
user input ───▶ customer STT
                ↓
                customer LLM ─▶ text reply
                ↓
                customer TTS (e.g. 11labs)
                ↓
                audio bytes + avatar_id ────────────▶ ┌─ Wav2Lip + muxer ─┐
                                                      │  render + stream  │
                                                      └──────────┬────────┘
                                                                 ↓ (fMP4)
   ◀─────────────────────────────────────────────────────────────┘
   <twai-avatar> playback
```

### Shape 3 — Fully on-device (edge)

**All 5 runtime stages run on the user's device. Airplane mode works.**

- **Stages 1-5:** all on-device. STT via Apple Speech offline / whisper.cpp; LLM via llama.cpp / MLX; TTS via AVSpeechSynthesizer / Piper / etc.; render via a customer-supplied lightweight lip-sync engine.
- **What customer ships:** an app with the 2wai-minted avatar assets baked in, plus their own runtime providers for each stage
- **Backend wire:** none at runtime. Assets are sideloaded once (or downloaded from a CDN and cached) and the device runs everything offline thereafter.
- **2wai's role:** mint the avatar assets via the central content pipeline. After that, 2wai is not in the request path at all.
- **Business model:** licensing of the assets + content pipeline; customer hosts everything else.

**Used by 2wai for:** *(potentially — if airplane-mode Jesus is a market, 2wai could ship this as a product)*.
**Used by customers for:** Jonathan's on-device Jesus app (reference example); high-privacy / offline / regulated customers (prisons, planes, remote ops, kids' apps, etc.).

```
USER DEVICE (airplane mode OK)
─────────────────────────────────────────
text or voice input
       ↓
   on-device STT ─▶ text
       ↓
   on-device LLM ─▶ reply text
       ↓
   on-device TTS ─▶ audio
       ↓
   on-device renderer ─▶ lip-synced video
       ↓
   <video> playback

(2wai is not in the runtime path. Assets were
 minted upstream by the central content pipeline.)
```

**Open architecture question for shape 3:** see [`edge_offline_shape.md`](edge_offline_shape.md). The hardest stage is #5 (render) — Wav2Lip needs GPU, so on-device requires a lighter model, pre-rendered clip library, or a phoneme-driven approach. Jonathan's specific render path determines whether 2wai ships a packaged mobile renderer or each on-device customer brings their own.

---

## How the shapes share the same SDK

The SDK is shaped around **per-stage pluggable interfaces** with default implementations for each shape. The same `ChatSession` orchestrates all three shapes — only the underlying providers change.

| Stage | Interface | Shape 1 default | Shape 2 default | Shape 3 default |
|---|---|---|---|---|
| 2. STT | `Transcriber` ✓ *exists* | `BrowserSpeechTranscriber` / `SpeechToTextTranscriber` | Customer's STT (theirs already runs) | On-device STT impl |
| 3. LLM | **NEW: `BrainProvider`** | 2wai cloud via `/ext-api/human` | Customer's LLM (out of SDK's path) | On-device LLM impl |
| 4. TTS | **NEW: `TtsProvider`** | 2wai cloud via WS handshake `ttsSelection` | Customer's TTS (out of SDK's path) | On-device TTS impl |
| 5. Render | **NEW: `AvatarRenderer`** | `VideoPlayerMseStreamSink` (existing VideoSink — cloud Wav2Lip via WS) | Same cloud renderer, fed by `sendAvatarAudio()` | Customer-implemented on-device renderer |

For shape 1, the SDK ships all four cloud-backed defaults — customer just constructs a `TwaiClient` and goes.

For shape 2, the customer's pipeline does stages 3 + 4 outside the SDK entirely. They call a new `session.sendAvatarAudio(audioBytes, ...)` method that hits the new render endpoint.

For shape 3, every stage gets a customer-implemented provider. `ChatSession` becomes a state-machine orchestrator with zero network calls — just stage-to-stage data flow.

**The interfaces aren't speculative — `Transcriber` already works exactly this way.** Customers can implement their own `Transcriber` today (Qwen3-server-backed, Deepgram, 11labs Scribe, whatever) and the SDK consumes it identically to the built-in browser/native impls. We extend the same pattern to TTS, LLM, and Render.

### What's built today vs roadmap

| Stage | Interface | Cloud default | Status |
|---|---|---|---|
| STT | `Transcriber` | `BrowserSpeechTranscriber`, `SpeechToTextTranscriber`, `DefaultTranscriber()` | ✅ Shipped |
| LLM | `BrainProvider` | (default: bundled inside `ChatSession.sendMessage()`) | ⚙️ Interface roadmapped |
| TTS | `TtsProvider` | (default: bundled inside `ChatSession.sendMessage()`, controlled by `ttsSelection`) | ⚙️ Interface roadmapped |
| Render | `AvatarRenderer` | `VideoSink` (the existing one, wraps the Adapter 1 sinks) | ✅ Shipped as `VideoSink`; rename / formalize when shape 3 lands |

For shape 1 today the LLM and TTS interfaces are bundled inside the WS handshake + POST flow — `sendMessage(text)` just does everything. That's fine for shape 1; we don't need to factor them out until a shape 2 or shape 3 customer needs to substitute one of them.

---

## Backend endpoints

Each shape implies one or more main_service endpoints. Mason's "2-3 APIs" framing maps cleanly:

| Endpoint | Wire | Used by | Status |
|---|---|---|---|
| `POST /ext-api/human` + `WS /ext-api/mse_stream` | Text in, fMP4 out, full pipeline | Shape 1 | ✅ Live |
| `POST /ext-api/render` *(name TBD)* | Audio in, fMP4 out, render-only | Shape 2 | 🔧 **NEW — Mason scope** |
| `POST /ext-api/transcribe` *(or similar)* | Audio in (user voice), text out | Server-side STT (cross-cutting; benefits all shapes) | ⚠️ **Backend exists** (FunASR in `main_service/factories/asr/`); endpoint not formally exposed via `/ext-api/*`. Mason scope: wire the route, not the engine. |

Shape 3 uses **no backend endpoints at runtime** — by definition. It only uses the central content pipeline upstream for asset minting.

So: **two new backend endpoints, both Mason scope, both well-defined.** Total backend work is roughly the lift Mason estimated for `tts9` alone — except now the architecture has a place for the work to land rather than retrofitting after the fact.

---

## Decision matrix — pick a shape for a new customer

When a new customer shows up, run through this:

1. **Do they have their own LLM stack that they'll keep?** Yes → shape 2 (skip TTS too) or shape 3. No → shape 1.
2. **Do they have their own TTS that they'll keep (typically 11labs)?** Yes → shape 2 or shape 3. No → shape 1 (we host all of it).
3. **Do they need airplane-mode / offline / on-device for a real product reason?** Yes → shape 3. No → shape 1 or 2.
4. **Are they cost-sensitive on a per-character basis or a regulatory data-residency basis?** Yes → shape 2 or 3 (they keep the TTS bills + data on their side). No → shape 1 is fine.

Then talk to them about pricing accordingly — shape 1 is per-session managed-everything, shape 2 is per-render, shape 3 is licensing of assets + pipeline access.

---

## Cross-references

- **For 2wai's own products:** [`apps/jesus/`](../apps/jesus/) (shape 1), future shape-3 product = TBD.
- **For Candy.ai specifically:** [`candy_ai_fit.md`](candy_ai_fit.md) — the full shape-2 fit analysis + pitch deliverables.
- **For Jonathan-style on-device:** [`edge_offline_shape.md`](edge_offline_shape.md) — shape 3 reference, currently a stub with open render question.
- **TTS engineering specifics (shape 1 only):** [`voice_and_tts.md`](voice_and_tts.md) — the `tts9 = 11labs` server-side adapter conversation.
- **Wire protocol:** [`protocol.md`](protocol.md) — shapes 1 and 2 use it; shape 3 doesn't at runtime.
- **Internal SDK structure:** [`architecture.md`](architecture.md) — package layout, transport adapters, typed errors.
