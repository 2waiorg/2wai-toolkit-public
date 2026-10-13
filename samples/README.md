# samples/ — reference clients for the 2wai API

Three tiny reference clients for the `api.2wai.ai/v1/*` REST + WebSocket surface. All three implement the same split-plane pattern (server holds the sk key, client only holds a scoped token) and speak whatever text you type — no brain in the loop, so the plumbing is obvious.

| Sample | Stack | When to start here |
|---|---|---|
| [`vanilla_js/`](vanilla_js/) | Plain JS + Node (zero deps) | You want to see the wire in ~200 LOC total. Copy-paste starting point. |
| [`react/`](react/) | Vite + React 18 | You want the ergonomic React version — reuses vanilla_js's Node server as the mint proxy. |
| [`nextjs/`](nextjs/) | Next.js 15 App Router | You want one full-stack deploy (server-side mint + client-side player in a single Next.js app). Closest to what a Candy-style customer runs on. |

All three depend only on Node 20+ built-ins on the server side (`fetch` + `http`). No SDK required — the toolkit's Flutter SDK ([`packages/twai_avatar_sdk_*`](../packages/)) is a separate track for when you want a first-class multi-platform mobile client instead of hand-rolling the wire.

## The split-plane pattern

| | Where | Sees the sk key? |
|---|---|---|
| Server (or serverless route) | your infra | **YES** — env var only |
| Browser (or React / Next client) | user's device | NO — only a scoped `client_token` |

The `client_token` can open exactly one WebSocket for one session. It can't mint new sessions, drive speech, or do anything the sk key can do. See [`apps/mint_proxy_examples/`](../apps/mint_proxy_examples/) for three standalone mint-proxy servers if you already have a client and just need the server piece.

## What all three samples share

- Same four routes: `POST /api/session`, `POST /api/say`, `POST /api/interrupt`, `POST /api/end`.
- Same avatar/voice defaults (Mila) — override via env vars.
- Same MSE-over-WebSocket plumbing on the client (~150 LOC): `MediaSource`, `SourceBuffer`, pending-chunk queue, eviction, speaking-event handling, reconnect-on-drop, `sendBeacon` on `pagehide`.

## What none of them do

- **No brain / LLM.** The avatar speaks your input verbatim. Real integrations put a brain between `/api/say` and the gateway's `/v1/sessions/{sid}/speak` — see [`apimila-demo`](https://github.com/2waiorg/apimila-demo) (Python/FastAPI, ~200 LOC) for the full pattern with SSE clause chunking.
- **No auth on your own routes.** Anyone hitting your deploy mints a session and spends your quota. Production wraps these in your own session/auth middleware.
- **No token-refresh loop.** On WebSocket drop we mint a whole new session. Fine for a demo; production wants proper token refresh.
