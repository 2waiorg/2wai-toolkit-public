# samples/react — Vite + React 18 reference

The React counterpart to `samples/vanilla_js/`. Same split-plane pattern, same wire — Adapter 4 (REST + WebSocket to `api.2wai.ai/v1/*`) — but wrapped in a small `useTwaiSession()` hook + a `<video>`-rendering component.

- `src/App.tsx` — everything: hook + UI (~180 LOC).
- `vite.config.ts` — proxies `/api/*` to your mint server. Default: `http://localhost:5173` (which is `samples/vanilla_js`'s server).

## Run it

You need two shells: one for the mint-proxy server (holds the sk key), one for the Vite dev server.

**Shell 1 — mint proxy** (reuse `samples/vanilla_js`):

```powershell
cd samples/vanilla_js
$env:TWAI_SK = "sk_..."
npm start
# server listens on :5173
```

**Shell 2 — Vite React app**:

```powershell
cd samples/react
npm install
npm run dev
# open http://localhost:5174
```

Type in the input and hit Send — the avatar says exactly what you typed. Click Stop to interrupt. Close the tab to end the session.

To point at a different mint proxy (e.g. one of the `apps/mint_proxy_examples/` variants on a different port):

```powershell
$env:VITE_API_PROXY = "http://localhost:8787"
npm run dev
```

## What this sample does NOT do

- **No brain / LLM** — same as `samples/vanilla_js`, the avatar speaks user input verbatim.
- **No `@twai/react`** — Mason's [`@twai/react`](https://github.com/2waiorg/twai-web-sdk/tree/main/packages/react) package is an Adapter 1 (penthouse `/ext-api-muse/*`) client. Once it publishes to npm + adds Adapter 4 support, most of `App.tsx` collapses to `<TwaiAvatar avatar={...} credentials={...} />`. For now, we plumb Adapter 4 directly.
- **No SSR** — client-side only. If you need SSR / RSC / server actions, see `samples/nextjs/`.

## Related

- `samples/vanilla_js/` — same wire, no framework.
- `samples/nextjs/` — Next.js full-stack (server-side mint + client-side player in one deploy).
- `apps/mint_proxy_examples/` — three mint-proxy servers (Node / Python / Cloudflare Worker).
