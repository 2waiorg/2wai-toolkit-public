# samples/vanilla_js — plain JS + Node reference

The smallest possible split-plane client for the 2wai API. No framework, no build step, no dependencies.

- Client (`public/app.js`, `public/index.html`) — ~200 LOC. Opens a MediaSource, streams fMP4 from the gateway WebSocket, handles speaking indicators + teardown.
- Server (`server.mjs`) — ~80 LOC, Node 20+ built-ins only. Holds the sk key. Proxies four routes to the gateway.

Ported from `apimila-demo/app/static/` (Mason's reference); customer-server piece rewritten in Node.

## Run it

```powershell
cd samples/vanilla_js
$env:TWAI_SK = "sk_..."          # your 2wai secret key
$env:TWAI_AVATAR_ID = "avt_..."  # optional; default is Mila
$env:TWAI_VOICE_ID = "vc_..."    # optional; default is Mila's voice
npm start
# open http://localhost:5173
```

Type in the input and hit Send — the avatar says exactly what you typed. Click Stop to interrupt. Close the tab to end the session (via `navigator.sendBeacon`).

## What this sample does NOT do

- **No brain / LLM.** The avatar speaks user input verbatim so you can see the plumbing without an LLM in the loop. Real integrations put a brain between `/api/say` and the gateway's `/v1/sessions/{sid}/speak` — see `apimila-demo` (Python/FastAPI, ~200 LOC) for the full pattern with SSE clause chunking.
- **No reconnect-with-token-refresh.** On WebSocket drop it mints a whole new session. Fine for a demo; production wants a proper refresh loop.
- **No error UI.** Errors log to the server console and the browser sees a scrubbed `{error}` body.

## The split-plane pattern

| | Where | Sees the sk key? |
|---|---|---|
| `server.mjs` | your infra | **YES** — env var only |
| `public/*` | user's browser | NO — only a scoped client_token |

The client_token can open one WebSocket for one session. It can't mint new sessions, drive speech, or do anything the sk key can do.

## Related

- `apps/mint_proxy_examples/` — three token-mint-only reference servers (Node / Python / CF Worker) for when you already have a client and just need the server piece.
- `apps/twai_api_starter/` — Flutter SDK version of this same pattern.
