# mint_proxy_examples — run commands

Server-side reference implementations of the customer mint proxy for Adapter-4 Flutter apps. Pick one language; all three listen on `http://localhost:8787`.

## Node (recommended for local dev)

```powershell
# One-time
cd apps\mint_proxy_examples\node
npm install

# Run
$env:SK_KEY = "sk_test_..."
node server.js
# → [mint-proxy] listening on http://localhost:8787
```

Serves `/v1/sessions*`, `/v1/sessions/{sid}/speak`, `/v1/sessions/{sid}/interrupt`, `DELETE /v1/sessions/{sid}`, plus `/brain` and `/brain/stream` for Enlighten's streaming brain path.

## Python (FastAPI + uvicorn)

```powershell
# One-time
cd apps\mint_proxy_examples\python
pip install -r requirements.txt

# Run
$env:SK_KEY = "sk_test_..."
uvicorn server:app --port 8787
```

## Cloudflare Worker

```powershell
# One-time
cd apps\mint_proxy_examples\cloudflare_worker
npm install

# Run (local dev)
wrangler dev
```

Deploy: `wrangler deploy` — set `SK_KEY` as a Worker secret in the Cloudflare dashboard.
