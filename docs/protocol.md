# 2wai Avatar Pipeline — Wire Protocol

**Audience:** anyone implementing a client for the 2wai avatar pipeline in any language. The Dart SDK in this repo is one such client. A TypeScript implementation already exists in [`coreledgergroup/clg_penthouse_pets`](https://github.com/coreledgergroup/clg_penthouse_pets) and informs this document.

**Pipeline shape:**

```
Client ─ POST /ext-api/human ──────▶ main_service (gateway, port 7862)
       ◀────────── {res: "..."} ─── │
                                    ├──▶ /speak (internal HTTP)
                                    │   to inference_service (port 10031)
                                    ▼
Client ─ WS /ext-api/mse_stream ◀── inference_service
       ◀── fMP4 init + media ───────│   (Wav2Lip + TTS + PyAV muxer)
       ◀── JSON speaking events ────│
```

`main_service` proxies WS upgrades for `/mse_stream` transparently to the worker. The `/ext-api/*` prefix is added by nginx (see `nginx-prod.conf:115` and `:175-190` for the exact-match WS upgrade block with long timeouts).

---

> **Production lipsync model (authoritative, Jim 2026-05-29):** The Penthouse pipeline (Adapter 1 in `architecture.md`) uses **self-hosted Wav2Lip+GAN, team-fine-tuned** — Rudrabha/Wav2Lip with the `hq_wav2lip_train.py` track + visual quality discriminator. Production checkpoint at step 399,000, sync loss 0.0269. Served from `krystal-avatar.westus2.cloudapp.azure.com:8001` (raw Wav2Lip) behind `:443` (orchestration). **NOT MuseTalk**, despite the vm-mirror `thg_abstract_factory.py` showing MuseTalk uncommented and Wav2Lip commented out — that's a non-production code path. The deployed checkpoint is the ground truth. See `reference_penthouse_wav2lip_production.md` in agent memory for full details. The separate `2wai-avatar-pipeline` repo (Adapter 2) uses the standard Rudrabha Wav2Lip (no GAN variant) on `server.py`.

## 1. Streaming transport — `/ext-api/mse_stream` (WebSocket)

### Endpoint
- **URL:** `wss://<host>/ext-api/mse_stream` (or `ws://` on local dev)
- **Binary mode:** required (`binaryType = 'arraybuffer'` in browsers; `WebSocket.binaryType` in Dart)
- **Heartbeat:** server emits aiohttp WS heartbeat every 20s; client should tolerate or echo pings
- **Idle timeout:** 3600s on nginx side (1h)

### Handshake (client → server, first frame, text)

Send exactly one JSON text frame within 15 seconds of connection open. After that the server only accepts binary or control frames.

```json
{
  "session_id":   "mse-1716879600000-487213",
  "avatar_id":    "RedJesusTalk2",
  "ttsSelection": "tts5",
  "avatarVoice":  "9c32e898-e99c-4287-89a1-57f5243aa454",
  "stream_type":  "AV"
}
```

**Field rules** (from `inference_service/worker_server.py:2293-2315`):

| Field | Required | Default | Notes |
|---|---|---|---|
| `session_id` | **yes** | — | Closes WS code 1002 if missing. Format: `mse-<epoch_ms>-<rand6>`. Must also be sent in `/ext-api/human` POST so the gateway can correlate. |
| `avatar_id` | no | `"default"` | Pipeline avatar variant. For Jesus: `RedJesusTalk1..4` (randomized per session for visual variety). |
| `ttsSelection` | no | `"tts5"` | TTS provider slot. **Verified against `main_service/web/options.json:380-396`:** `tts1`=xtts, `tts2`=gtts, `tts3`=edgetts, `tts4`=index-TTS, `tts5`=qwen-tts. **No `tts6`/`tts7`/`tts8`/`tts9` exist server-side today** — earlier versions of this doc speculated those slots; they were never implemented. Adding an ElevenLabs slot would be a new backend deliverable. (Note: the separate `2wai-avatar-pipeline` simple-request/response server — Adapter 2 in `architecture.md` — uses ElevenLabs directly today, but it's not controlled by a `ttsSelection` slot; it's hardcoded.) |
| `avatarVoice` | no | `"default"` | Voice reference UUID (Qwen3 voice ID, ElevenLabs voice ID, etc.) |
| `stream_type` | no | `"AV"` | `"AV"` = audio+video muxed. Other values may exist but `AV` is the documented path. |

**Failure modes:**
- Missing `session_id` → close code 1002 (`"session_id required"`)
- Non-JSON / parse failure → close code 1002 (`"bad config: <err>"`)
- 15s timeout with no frame → close code 1002 (`"config timeout"`)

### Server frames (server → client)

After handshake, the server pushes two kinds of frames:

#### a) Binary — fragmented MP4 chunks

- **First binary frame:** init segment (`ftyp` + `moov`, ~600 bytes). Emitted once, when the PyAV h.264 encoder produces the first frame (`worker_server.py:2402-2411`).
- **Subsequent binary frames:** media segments (`moof` + `mdat`), 2–4 KB each, one per ~1 second of video at 25 fps with 1 keyframe per fragment.

**Codec parameters (do not change):**
- Video: H.264 Constrained Baseline 3.1, 720×1280 portrait, `yuv420p`, x264 with `preset=ultrafast tune=zerolatency`, keyframe interval = `fps × fragment_seconds`. avcC profile_compatibility byte = `0xC0` (not 0xE0 — `constraint_set0_flag=1, constraint_set1_flag=1`).
- Audio: AAC-LC, 16 kHz mono, 64 kbps.
- Container flags: `+frag_keyframe+empty_moov+default_base_moof+separate_moof`.

**Codec string for SourceBuffer / decoder:**
```
video/mp4; codecs="avc1.42C01F, mp4a.40.2"
```

The exact value above is verified against the worker's actual emitted bytes (`frontend/src/lib/mseClient.ts:38-46`). `isTypeSupported("avc1.42E01F")` returns true on most browsers but the bytes don't match and `appendBuffer` silently never decodes — leaving `<video>` stuck at `HAVE_METADATA` forever. Use `42C01F`, not `42E01F`.

#### b) Text — speaking-state JSON events

Emitted whenever the inference worker transitions between idle and active speech:

```json
{ "type": "speaking", "value": "start", "pts": 2.34 }
{ "type": "speaking", "value": "stop",  "pts": 7.81 }
```

**Critical:** `pts` is the **video presentation timestamp in seconds** at which the transition takes effect. The event arrives over the WS near-instantly, but the player's playback head lags the latest appended fragment by 0.5–1.5s. **The UI must gate transitions on `playbackTime >= pts`, not on event receipt.**

No other text frames are emitted by the current worker. The client docstring references future `{type:"speak", text}` and `{type:"flush"}` envelopes but the server does not consume or emit those today.

### Client control frames (client → server, optional, future)

Not currently consumed. Reserved for future expansion. Do not implement until the server supports them.

### Session teardown

- Client closes WS → server's `finally` block runs (`worker_server.py:2495-2520`):
  1. Cancels drain tasks
  2. Stops `player.video` and `player.audio` (joins Wav2LipReal daemon threads)
  3. Closes PyAV muxer (releases encoder)
  4. `state.remove_renderer(session_id)` — unbinds avatar from LRU cache, stops muse thread
  5. Pops session
- Server-initiated close (codec error, internal failure) emits a close frame with reason; client should not auto-reconnect on close codes 1002 or 1011 (those are configuration / server bugs).

---

## 2. Chat message — `POST /ext-api/human`

The message you send to Jesus. Returns the LLM's response text. The audio + lipsynced video for that response arrive over the **already-open WS** from §1 — they are not in this HTTP response.

### Request

```
POST /ext-api/human
Content-Type: application/json
```

```json
{
  "text":          "what's a verse for today",
  "sessionid":     "mse-1716879600000-487213",
  "avatarName":    "RedJesusTalk2",
  "avatarVoice":   "9c32e898-e99c-4287-89a1-57f5243aa454",
  "chunkSize":     "10",
  "displayVoice":  true,
  "interrupt":     true,
  "ttsSelection":  "tts5",
  "type":          "chat",
  "userId":        "usr-9af2..."
}
```

**Field rules** (from `frontend/src/lean/controller.ts:1955-1972` and `main_service/pipeline/handlers/chat.py:30-77`):

| Field | Required | Notes |
|---|---|---|
| `text` | yes | User message. UTF-8 string. |
| `sessionid` | yes | **Must match** the `session_id` of an open WS session. The gateway uses this to look up which inference worker / WS to push the synthesized response into. |
| `avatarName` | yes | Same value as the WS handshake's `avatar_id`. |
| `avatarVoice` | yes | Same value as the WS handshake. |
| `ttsSelection` | yes | Same value as the WS handshake. |
| `chunkSize` | no | Numeric string. LLM streaming chunk granularity. Typical: `"10"`. |
| `displayVoice` | no | Boolean. Whether to render audio. Typical: `true`. |
| `interrupt` | no | Boolean. If a previous message is still rendering, cancel it. Typical: `true`. |
| `type` | no | `"chat"` is the only documented value. |
| `userId` | yes (null OK) | Stable per-user ID for brain-side memory scoping (mem0 / Qdrant on the brain itself; local main_service mem0 path was removed 2026-06-11 — see Patch #60 in `ops/origin-routed-brain`). Pass `null` for anonymous; a UUID for authenticated. |
| `gamificationLevel` | no | **NEW 2026-06-15 (penthouse Patch #70, r14).** Numeric. Per-(user, avatar) level from the lean controller. main_service stores it in `custom_config` and `brain_llm.py` forwards it into the brain payload so the brain maps it to a Trust Stage. `None`/absent is safe — brain defaults to Stage 1. |
| `avatarStateBlock` | no | **NEW 2026-06-15.** Opaque block passed from client through to the brain alongside `gamificationLevel`. Used for richer context handoff (mood / pose / outfit state). Not interpreted by main_service. |

### Response

```json
{
  "code": 0,
  "data": "ok",
  "res":  "Peace be with you. \"This is the day which the LORD hath made; we will rejoice and be glad in it.\" Psalm 118:24"
}
```

| Field | Meaning |
|---|---|
| `code` | 0 = success; non-zero = error (see §4). |
| `res` | The LLM's reply text. UI displays this in the chat bubble. |
| `data` | Status string; usually `"ok"`. |

**Response headers worth knowing:**

| Header | Source | Meaning |
|---|---|---|
| `X-Mood` | **NEW 2026-06-15 (penthouse Patch #62, r14).** main_service echoes a brain-emitted mood label (read from the brain's SSE stream). | A short string describing the mood / emotional state the brain inferred for this turn. Client may use it to drive UI affordances (avatar pose, background, color). `None`/absent is normal. |

**No video URL in the response.** The video for this reply will arrive over the WS as the worker renders it, with `{"type":"speaking","value":"start","pts":...}` marking the moment in the playback timeline when speech begins.

**Pronunciation rules layer (server-side, transparent):** As of 2026-05-22 ([`docs/TTS_RULES.md`](https://github.com/coreledgergroup/clg_penthouse_pets/blob/mason/tts-global-pronunciation/docs/TTS_RULES.md) on penthouse), the reply text the brain emits is normalized via `apply_brain_normalize(...)` before it leaves main_service; the inference worker then applies `apply_tts_prepass(...)` before calling Qwen3 TTS. Rules are scoped by `app:<id>` / `avatar:<id>` and load from `backend/data/tts_rules.json` with ~1 min hot-reload. **Client-visible:** the LLM `res` text is unchanged; what's spoken aloud may differ. Full layer documented in `voice_and_tts.md`.

**Brain routing via Origin (server-side):** main_service reads the `Origin` (or `Referer`) header and routes staging traffic to dev brain vs prod traffic to prod brain. **Not protocol-visible** — clients just send their natural Origin and the routing happens transparently. Without this (pre-2026-06-XX, Patch #50 in `ops/origin-routed-brain`), staging chat was silently hitting prod brain.

---

## 3. Brain SSE (alternative for text-only or hybrid UX) — `POST /chat/stream`

When you need streaming text **without** the full audio+video pipeline, hit the brain directly. Returns Server-Sent Events.

### Endpoint
- Default: `http://prod.brain.2wai.ai/chat/stream`
- Per-avatar override (Jesus): `https://talk2jesus-web-test.wonderfulbush-5b7f9f48.westus2.azurecontainerapps.io/chat/stream`

Brain URL per `vm-mirror/.../main_service/factories/llm/brain_llm.py:189-191`. The Jesus persona uses a separate Container App with theological-honesty guardrails and Anthropic Claude as primary LLM.

### Request

```
POST /chat/stream
Content-Type: application/json
Accept: text/event-stream
```

```json
{
  "message":  "what does the Bible say about forgiveness",
  "user_id":  "usr-9af2...",
  "avatar":   "jesus",
  "provider": "openai",
  "model":    "gpt-4.1",
  "roleplay": true
}
```

`avatar` here is the **brain slug** (e.g. `jesus`), not the pipeline `avatar_id` (e.g. `RedJesusTalk2`). The brain layer translates internally.

### Response — SSE stream

```
event: delta
data: {"content": "Peace"}

event: delta
data: {"content": " be with you."}

event: tool_start
data: {"name": "search_listings", "args": {...}}

event: final
data: {"content": "Peace be with you. ...full text..."}

event: done
```

Events the client cares about:
- `delta` — append `.content` to the response buffer
- `done` — stream complete
- Others (`ready`, `tool_start`, `tool_result`, `final`, `metadata`) — log/ignore

Sentence-boundary chunking for TTS: flush to TTS when buffer ends in `. ! ? 。 ！ ？` AND buffer length ≥ 30 chars (matches `brain_llm.py:569-575`).

---

## 4. Admin endpoints — `main_service` (port 7862)

> ⚠️ **Security gap (server-side, unchanged):** all admin endpoints are currently **unenforced**. No bearer-token validation, no API keys, no IP allowlist (`main_service/pipeline/handlers/avatar.py`). Anyone with network reach to the gateway can mutate the avatar registry. Filed for follow-up.
>
> **What the SDK does today:** `AvatarAdminClient` already sends `Authorization: Bearer <secretKey>` on every admin call so the wire side is ready the moment the server flips validation on. Until then, requests with no Authorization header still succeed (anonymous mode). The pattern mirrors the chat-session auth in §2 — see `docs/sdk_overview.md` for the two-key publishable/secret scheme and the typed exception ladder (`AvatarAdminUnauthorizedException` / `Forbidden` / `RateLimited`).

### `GET /query_avatar_list`

Returns avatars whose `status="ready"` AND whose registered public IP matches the calling server. Suitable for "which avatars can I chat with right now" lists.

```json
// Response
{ "code": 0, "data": ["RedJesusTalk1", "RedJesusTalk2", "sophi", "..."] }
```

### `GET /query_avatar`

Returns metadata for **all** avatars in MongoDB regardless of readiness.

```json
{
  "code": 0,
  "data": [
    {
      "avatar_name": "RedJesusTalk2",
      "prompt":      "<system prompt text>",
      "create_at":   1716879600000,
      "update_at":   1716879600000
    },
    ...
  ]
}
```

### `POST /query_prompt` *(retired on staging — do not call)*

(POST despite the name.) **Staging returns HTTP 405 as of 2026-06-01** — the endpoint was removed without a deprecation notice. The `prompt` field is now returned inline by `GET /query_avatar`, so callers should source it from the list response instead of round-tripping a second request. The Admin app's avatar-detail screen was rewritten to pass metadata down from the list rather than call this endpoint; new clients should do the same.

Documented here for archaeology only:

Request: `{ "avatarName": "RedJesusTalk2" }`
Response: `{ "code": 0, "data": "success!", "chatPrompt": "<text>" }`

### `POST /add_avatar`

```json
{
  "avatar_id":   "NewAvatar1",
  "prompt":      "You are ...",
  "voice_id":    "<uuid>",
  "green_bg":    true,
  "need_middles": false,
  "handle":      "add",
  "sessionid":   "<optional, to release old avatar from a session>"
}
```

Response: `{ "code": 0, "data": "ok", "webrtcReleased": bool, "clearAvatarCache": bool, "cacheBust": int }`

Error codes: `2` (already exists), `3` (currently adding), `4` (currently deleting), `999999` (exception).

### `POST /delete_avatar`

```json
{
  "avatarName":      "NewAvatar1",
  "deletePermanent": false,
  "sessionid":       "<optional>"
}
```

Response: same envelope as `/add_avatar`. Error codes: `1` (not found), `2` (adding now), `3` (deleting now).

### `POST /change_prompt`

```json
{
  "avatarName": "NewAvatar1",
  "chatPrompt": "<new system prompt>",
  "sessionid":  "<optional>"
}
```

Response: `{ "code": 0, "msg": "success!" }`

### `POST /change_voice_list`

Bulk voice reassignment. Request is a flat object mapping avatar_id → voice_id:

```json
{
  "RedJesusTalk1": "voice-uuid-a",
  "RedJesusTalk2": "voice-uuid-b"
}
```

Response: `{ "code": 0, "msg": "options updated successfully" }`

### Avatar data model

Two MongoDB collections in database `2wai`:

**`avatars`** (one document per avatar):
- `avatar_name` (string, `_id`)
- `prompt` (string)
- `voice_id` (string)
- `create_at`, `update_at` (epoch ms)

**`avatars_status`** (per-server readiness):
- `avatar_name` (string, FK)
- `status` (enum: `"ready"`, `"adding"`, `"deleting"`, `"corrupted"`)
- `need_bg`, `need_middles` (bool)
- `ip` (string, server public IP)
- `create_at`, `update_at` (epoch ms)

### Persistence and side effects

- `add_avatar` downloads avatar assets (latents, coords, source videos) from Alibaba OSS to `/home/azureuser/data/avatars/{avatar_id}/` on the worker VM
- `delete_avatar` with `deletePermanent=true` does `rm -rf` on the local path
- In-memory caches synced inside `pipeline.opt`: `avatar_id_list`, `avatar_prompts`, `voice_id_2_name` — admin mutations update these atomically

---

## 5. End-to-end sequence (typical chat turn)

```
1.  Client opens WS to /ext-api/mse_stream
2.  Client sends handshake JSON (session_id, avatar_id, ttsSelection, avatarVoice, stream_type)
3.  Server sends ftyp+moov init segment (binary)
4.  Server sends moof+mdat fragments looping idle video (binary, continuous)

—— user types a message ——

5.  Client POSTs /ext-api/human with same session_id, text, avatar config
6.  Server (main_service) forwards to inference worker's /speak
7.  Server begins LLM generation; returns {res: "..."} to the POST (step 5) once LLM completes
8.  Worker runs TTS on LLM output, feeds audio to Wav2Lip, mixes with rendered video
9.  Worker emits {"type":"speaking","value":"start","pts":<t_start>} on the WS
10. Worker pushes media fragments (moof+mdat) containing the speaking output
11. Client's playback head reaches pts → UI transitions idle → speaking
12. Worker emits {"type":"speaking","value":"stop","pts":<t_end>}
13. Client's playback head reaches t_end → UI transitions speaking → idle
14. Worker resumes idle-loop fragment generation (step 4)
```

Steps 5–14 repeat per turn for the lifetime of the session.

---

## 6. Reference TypeScript implementation

The penthouse-pets web client implements all of this. Key files:

- [`frontend/src/lib/mseClient.ts`](https://github.com/coreledgergroup/clg_penthouse_pets/blob/staging/frontend/src/lib/mseClient.ts) — MSE-over-WS protocol client. Canonical reference.
- [`frontend/src/lean/controller.ts`](https://github.com/coreledgergroup/clg_penthouse_pets/blob/staging/frontend/src/lean/controller.ts) — Session lifecycle, transport selection, reconnect, user-id management. Penthouse-specific UI bits are clearly demarcated.

When implementing in a new language, port `mseClient.ts` first (~250 lines, no UI deps), then write a wrapper for `/ext-api/human` and the brain SSE.

---

## Related protocols (out of scope for this document)

This document specifies the **Penthouse MSE-over-WS protocol** — the SDK's primary transport (Adapter 1). Two other 2wai-adjacent protocols exist and are summarized here only so future maintainers don't conflate them:

- **Pipeline v1.3** — `POST /chat` → complete MP4 + `X-Response-Text` header. Spec at [`jdk2wai/2wai-avatar-pipeline/docs/PIPELINE_SPEC_V1.3.md`](https://github.com/jdk2wai/2wai-avatar-pipeline/blob/main/docs/PIPELINE_SPEC_V1.3.md); server impl at [`server/server.py:321`](https://github.com/jdk2wai/2wai-avatar-pipeline/blob/main/server/server.py#L321). Simpler request/response shape, 4–9s latency. Targeted by SDK Adapter 2 (see `architecture.md`).
- **WebRTC via blade-virtual** — SDP offer/answer dance against `/blade-virtual/ai/call/getAiOffer`, audio+video tracks streamed via RTP. Implemented in [`jdk2wai/2wai-virtual-companion/composables/useWebRTC.ts`](https://github.com/jdk2wai/2wai-virtual-companion/blob/main/composables/useWebRTC.ts). Currently runs `2wai.ai/jesus`. Reserved for SDK Adapter 3 (Phase 2).

---

## Open issues / known limitations

- **No auth on admin endpoints.** Until fixed server-side, the Dart SDK's `AvatarAdminClient` should be gated behind a "developer mode" flag and not exposed to end-user-facing builds.
- **Single physical GPU VM.** `krystal-avatar.westus2.cloudapp.azure.com` (= `20.230.153.80`) hosts both `main_service` (port 7862) and `inference_service` (port 10031). No failover. Outage of this VM takes down all avatar traffic across all environments (staging shares with prod).
- **Hardcoded inference node URL.** `main_service/pipeline/handlers/chat.py:63` hardcodes `http://127.0.0.1:10031` for MSE sessions. Multi-worker deployments will require a session→worker routing table.
- **Speak watchdog only after reply.** `frontend/src/lean/controller.ts:1983` only arms the speak-stuck watchdog *after* `/human` returns. A hanging `/human` POST will not trigger reconnect — silent hang.
