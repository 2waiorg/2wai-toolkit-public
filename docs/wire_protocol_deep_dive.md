# Wire protocol deep dive

**Who this is for:** anyone building custom tools directly on the 2wai API — a custom player, a headless recorder, a pipeline probe, a mobile client that can't use `@twai/player`, or debugging why a specific integration doesn't behave. **Not for typical app developers** — those should use `@twai/player` (see [`call_flow.md`](call_flow.md)) and never touch the wire.

## TL;DR of the wire

- **Control plane = REST** on `api.2wai.ai/v1/*`. Server holds `sk_...`. Every mint / speak / interrupt / end is an HTTP call.
- **Media plane = WebSocket** on `wss://api.2wai.ai/v1/stream?token=<client_token>`. Server-mints-token → browser opens WS → gateway relays a bidirectional stream to the muse worker.
- **Media format:** fMP4 (fragmented MP4) with H.264 Constrained Baseline 3.1 + AAC-LC 16 kHz, muxed in one container. Codec string: `video/mp4; codecs="avc1.42C01F, mp4a.40.2"`.
- **Control frames on WS:** `{type:"session.ready"}`, `{type:"speaking", value:"start"|"stop", pts:<seconds>}`, `{type:"warning", ...}`, `{type:"session.closing", reason:"..."}`.
- **Client-to-server on WS:** nothing. The public client never sends WS frames. Session is provisioned server-side by the mint.

Below is the full narrative for each step.

## 1. Server mints a session (REST)

```
POST https://api.2wai.ai/v1/sessions
Authorization: Bearer sk_...
Content-Type: application/json

{
  "avatar_id": "avt_...",
  "mode": "video",
  "voice_id": "vc_..."         (optional; falls back to the avatar's default)
}
```

Response (201):

```json
{
  "session_id": "ses_...",
  "client_token": "eyJ...",                            (short-lived JWT)
  "transport": "mse-ws",
  "websocket_url": "wss://api.2wai.ai/v1/stream?token=eyJ...",
  "expires_at": null
}
```

The `client_token` is a JWT with `{sid, ten, cfg, iat, exp}` — session id, tenant id, config hash, timestamps. Only its **hash** is validated server-side (gateway uses HS256). The token is scoped to that ONE session and expires (default 60 min TTL, refreshable via `POST /v1/sessions/{sid}/token`).

**Concurrency:** the gateway enforces `max_concurrent_sessions` per API key (default 5). Session lifecycle events (session_start / session_stop) count toward it. Delete stale sessions promptly — WS close alone doesn't necessarily free the slot immediately.

## 2. Browser opens the WebSocket

```
new WebSocket("wss://api.2wai.ai/v1/stream?token=" + client_token)
```

No client-side handshake message. The token IS the identity. Gateway decodes it, looks up the session in Postgres, dials an internal WS to the muse worker, and injects the config frame ON BEHALF of the client:

```json
{
  "session_id": "<internal_session_id>",
  "avatar_id": "<pipeline_name>",           (NOT the public avt_..., the muse worker's name)
  "ttsSelection": "tts5",                    (from the voice row)
  "avatarVoice": "<ref_audio_id>",           (Qwen3 voice ref UUID)
  "stream_type": "AV"
}
```

This is the message Mason's Adapter-1 client would send itself. On Adapter 4, the gateway sends it. Difference matters: **don't send this handshake from an Adapter 4 client** — you'd double up and cause worker confusion.

## 3. What flows down the WebSocket

**First:** a text frame

```json
{"type": "session.ready"}
```

Then, continuously as the muse worker produces:

**Binary frames** — fMP4 media segments:
- **First binary frame** = init segment (ftyp + moov boxes, ~600 bytes). Registers video/audio tracks with the MediaSource.
- **Subsequent binary frames** = media segments (moof + mdat boxes, hundreds of KB each). Each is a self-contained playable chunk.

**Text frames** — control events:

```json
{"type": "speaking", "value": "start", "pts": 3.20}
{"type": "speaking", "value": "stop",  "pts": 7.85}
{"type": "warning",  "code": "backlog_full", "message": "..."}
{"type": "session.closing", "reason": "..."}   (right before gateway closes the WS)
```

**`pts` is critical.** It's the video presentation timestamp (seconds since stream start) at which the speaking transition happens IN THE MEDIA. The playhead lags the appended fragments by ~1 second (SourceBuffer lookahead), so you MUST gate the UI transition on `video.currentTime >= pts`, not on when the event ARRIVES. Otherwise the mouth is still closed when you flip idle→live.

**Legacy compat:** older workers omit `pts`. If missing, fire on the next tick (`pts = -Infinity` in the gate).

## 4. Client MSE plumbing (browser)

The load-bearing sequence. Every custom player must do these in order:

```
0. Codec support check:
   MediaSource.isTypeSupported('video/mp4; codecs="avc1.42C01F, mp4a.40.2"')
   → false = codec not supported, bail.

1. Create MediaSource, register 'sourceopen' listener BEFORE binding to <video>:
   const ms = new MediaSource()
   const sourceOpenP = new Promise(r => ms.addEventListener('sourceopen', r, {once:true}))

2. Bind MediaSource to <video>:
   - iOS 17.1+: use ManagedMediaSource via video.srcObject (bare MediaSource hangs at HAVE_METADATA)
   - Desktop/Android: URL.createObjectURL(ms) → video.src

3. Set video.muted = true (Chrome autoplay policy — muted autoplay is always allowed).
   Register window pointerdown/keydown/touchstart with {once:true} — first user gesture unmutes:
     video.muted = false; video.play().catch(() => {})

4. Open WebSocket. await Promise.all([sourceOpenP, wsOpenP]) with a 5-10s race timeout.

5. Add SourceBuffer with the MIME string, mode = 'sequence':
   sb = ms.addSourceBuffer(MSE_CODECS); sb.mode = 'sequence'

6. Attach message + close + error listeners to the WS.
   Register updateend on the SourceBuffer to drain + evict.

7. Call video.play() (may reject; catch and retry muted).

8. On binary WS frame: queue → drain(next → appendBuffer) → evict trailing buffer > 5s behind playhead.
9. On text WS frame with type='speaking': enqueue into pts-gated speaking queue → drain on video 'timeupdate' (~4Hz).

10. On timeupdate: also live-edge-clamp — if buffered.end - currentTime > 1.2s, seek to end - 0.6s.
    Prevents unbounded latency creep on long sessions.

11. On WS close: if code not in {1002, 1011} AND we haven't reconnected yet, wait 1.5s and re-open one time.
```

**Buffer eviction (bounded memory):**

```
if (buffered.length > 0 && currentTime - buffered.start(0) > 5) {
  sb.remove(buffered.start(0), currentTime - 5)
}
```

Runs on `updateend`. Keeps memory bounded; playback continues seamlessly because the eviction happens BEHIND the playhead.

**Live-edge clamp (bounded latency):**

Playhead can drift behind the live edge if the browser tab was throttled (background, low battery). Without a clamp, a 2-hour session can accumulate minutes of lag. On every timeupdate:

```
end = buffered.end(buffered.length - 1)
if (end - currentTime > 1.2) video.currentTime = end - 0.6
```

## 5. Control-plane REST calls

From the customer's server (with sk_... key):

```
POST /v1/sessions/{sid}/speak         { text }                    (queues one turn of TTS+lipsync)
POST /v1/sessions/{sid}/speak         { text, voice_id }          (per-turn voice override)
POST /v1/sessions/{sid}/audio         (multipart or raw audio, ?more=true|false)
                                                                  (BYO-audio: skip TTS, feed audio bytes directly)
POST /v1/sessions/{sid}/interrupt                                 (best-effort: stops in-flight speech)
POST /v1/sessions/{sid}/waiting_state { state_id }                (switch to a baked idle variant mid-session)
POST /v1/sessions/{sid}/token                                     (rotate the client_token before it expires)
GET  /v1/sessions/{sid}                                            (status: active|ended, timestamps)
GET  /v1/sessions?status=active                                    (list — cap check, cleanup)
DELETE /v1/sessions/{sid}                                          (end + free the concurrency slot)
```

**Interrupt is idempotent.** "Stop when nothing is playing" is not a failure — return 200. Don't propagate the worker's `stream_not_connected` as an error to the customer app.

## 6. Error envelopes

All 4xx/5xx responses are JSON:

```json
{
  "error": {
    "type":       "authentication|invalid_request|not_found|conflict|rate_limit|server",
    "code":       "specific_code",
    "message":    "human-readable, safe to show a customer",
    "request_id": "req_..."
  }
}
```

Notable codes:

| Type | Code | Meaning |
|---|---|---|
| `authentication` | `missing_key` / `invalid_key` | Bearer sk missing or unknown/revoked |
| `not_found` | `no_such_avatar` | avatar_id not in tenant, or `status != ready` |
| `not_found` | `no_such_voice` | voice_id not in tenant |
| `rate_limit` | `concurrency_cap` | key's `max_concurrent_sessions` reached |
| `conflict` | `session_ended` | control-plane call to a non-active session |
| `conflict` | `stream_not_connected` | speak fired before the client opened the WS |
| `server` | `muse_error` | upstream video service failed (backlog, TTS failure) |
| `server` | `muse_busy` | worker's backlog is full — retry shortly |

## 7. The wire in miniature — full sequence for one turn

```
CUSTOMER SERVER            GATEWAY                    MUSE WORKER               BROWSER
────────────────           ─────────                  ─────────────             ─────────
POST /v1/sessions ──────►  create session row
                           mint JWT client_token
                    ◄──── {session_id, client_token, websocket_url}
                                                                                open WS with ?token=
                                                                                ────────────►
                           verify token → load session
                           dial internal WS to muse ──►
                                                       receive config, bind session
                           accept client WS
                           send text {session.ready} ──────────────────────────►
                                                       start emitting idle frames (fMP4)
                                                       ◄──────────
                           relay bytes ──────────────────────────────────────►  appendBuffer → video plays idle

POST /v1/sessions/{sid}/speak {text} ──►
                           forward to muse /play_text ──►
                           ◄─── {ok}
                    ◄──── {status:"speaking"}
                                                       TTS + lipsync → fMP4
                                                       emit {type:"speaking",value:"start",pts:3.2}
                                                       emit fMP4 fragments (moof+mdat)
                                                       emit {type:"speaking",value:"stop",pts:7.8}
                           relay all of above ──────────────────────────────────►
                                                                                gate on currentTime >= pts
                                                                                → onSpeakingStart, appendBuffer
                                                                                → video shows Mila talking + audio
                                                                                → onSpeakingStop after playhead reaches 7.8

POST /v1/sessions/{sid}/interrupt ──►
                           forward to muse /flush_talk ──►
                                                       drop TTS queue
                                                       emit {type:"speaking",value:"stop",pts:...}
                           relay ─────────────────────────────────────────────►

DELETE /v1/sessions/{sid} ──►
                           status=ended, ended_at=now
                           kick(sid) → close both WS
                    ◄──── {status:"ended"}
```

## 8. When to skip the SDK

Use `@twai/player` unless you're doing one of:

- Building for a platform Mason's package doesn't target (native iOS/Android, headless Node scraper)
- Recording / archiving the raw fMP4 for later replay (no rendering)
- Injecting into a non-`<video>` context (canvas, WebGL, external renderer)
- Instrumenting the wire for pipeline debugging (byte-counter, latency probe, fragment dumper)
- You explicitly need a different rendering choreography (custom crossfade, multi-avatar composition, etc.)

For anything else, `@twai/player` handles the whole client side and you write the ~30 LOC of app-specific glue. See [`call_flow.md`](call_flow.md) and [`../samples/vanilla_js/`](../samples/vanilla_js/) for the working end-to-end reference.

## 9. Source of truth pointers

- **Live OpenAPI:** [`https://api.2wai.ai/v1/openapi.yaml`](https://api.2wai.ai/v1/openapi.yaml) (Mason's gateway serves it; deep-copies FastAPI schema, strips `/admin/*`)
- **Snapshot in this repo:** [`openapi/openapi.yaml`](../openapi/openapi.yaml) (refresh recipe in [`openapi/README.md`](../openapi/README.md))
- **Gateway source:** `2waiorg/twai-api` at `c:\Dev\twai-api\gateway\app\` — `services/relay.py` is the WS relay, `routers/sessions.py` is the REST surface
- **Reference client (canonical):** [`c:\Dev\avatar-player\src\main.ts`](file:///c:/Dev/avatar-player/src/main.ts) — Mason's ~3000 LOC Vite app; the definitive working reference for MSE + speaking-gate logic
- **SDK extraction:** [`c:\Dev\twai-web-sdk\packages\player\src\mseSession.ts`](file:///c:/Dev/twai-web-sdk/packages/player/src/mseSession.ts) — the reusable class version of the above
- **Toolkit's Adapter-4 wrapper:** [`c:\Dev\twai-web-sdk\packages\player\src\apiSession.ts`](file:///c:/Dev/twai-web-sdk/packages/player/src/apiSession.ts) (uncommitted; PR at [`proposals/mason-pr-twai-player-adapter4.md`](proposals/mason-pr-twai-player-adapter4.md))

If any of the details above go stale, the code is truth — this doc is a snapshot for humans.
