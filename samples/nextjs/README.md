# samples/nextjs — full-stack Next.js reference

The "one deploy for the whole thing" sample. Server-side mint proxy + client-side player + all in one Next.js app. This is closest to what a Candy-style customer probably runs on.

- `app/api/*/route.ts` — the four server routes (session / say / interrupt / end). sk key lives in server env only.
- `app/page.tsx` — client component with the same `useTwaiSession()` hook + video/composer UI as `samples/react/`.
- `lib/gateway.ts` — one-line helper for calling `api.2wai.ai/v1/*` with the sk key.

## Run it

```powershell
cd samples/nextjs
npm install

$env:TWAI_SK = "sk_..."           # required
$env:TWAI_AVATAR_ID = "avt_..."   # optional; default is Mila
$env:TWAI_VOICE_ID = "vc_..."     # optional; default is Mila's voice
# $env:TWAI_GATEWAY = "https://staging.api.2wai.ai"  # optional; default is prod

npm run dev
# open http://localhost:3000
```

For a production build:

```powershell
npm run build && npm start
```

Deploy to Vercel / anywhere Node runs. Set `TWAI_SK` as a project secret; the browser bundle never sees it.

## What this sample does NOT do

- **No brain / LLM** — same as the other samples, the avatar speaks user input verbatim. Real integrations add the brain call inside `app/api/say/route.ts`.
- **No auth on your own API** — anyone hitting `/api/session` on your deploy mints a session, spending your quota. Real production wraps these routes in your own session/auth middleware.
- **No streaming reply** — `POST /api/say` returns the full reply text in one JSON response. For token-by-token UIs, port the SSE clause-chunking pattern from `apimila-demo/app/main.py` (~50 LOC).

## Related

- `samples/vanilla_js/` — same wire, no framework, separate server/client processes.
- `samples/react/` — Vite + React 18, uses a separate mint-proxy server.
- `apps/mint_proxy_examples/` — three standalone mint-proxy servers if you'd rather keep the mint deploy separate from the client bundle.
