# Mint-proxy reference implementations

Three ~50-line reference servers that let a browser-side app talk to the
2wai `/v1/*` API without shipping the `sk_` key. Each one:

1. Reads `SK_KEY` from its own environment (a secret manager / dotenv).
2. Exposes the same `/v1/*` shape as `twai-api` — `POST /v1/sessions`,
   `POST /v1/sessions/{sid}/speak`, `POST /v1/sessions/{sid}/interrupt`,
   `DELETE /v1/sessions/{sid}`.
3. Proxies each request to the upstream `twai-api` with an
   `Authorization: Bearer sk_...` header the browser never sees.
4. Serves CORS headers so the browser SDK can call it from any origin
   you allow.

Point the Flutter SDK at your proxy like this:

```dart
final rest = TwaiApiRestClient(
  baseUrl: Uri.parse('https://myapp.com/twai'),   // your proxy
  credentials: const AnonymousCredentials(),      // no sk_ in browser
);
final session = TwaiApiChatSession(restClient: rest, brain: myBrain);
```

## Which one to pick

| Runtime          | Best for                                              |
| ---------------- | ----------------------------------------------------- |
| **node/**        | Node 18+, Express — plugs into an existing web app    |
| **python/**      | Python 3.11+, FastAPI — matches most 2wai backends    |
| **cloudflare_worker/** | Edge deploy, zero infra, ~5ms cold start        |

All three are functionally identical (same 4 endpoints, same CORS
behavior). Pick whichever fits your stack — if you're already running
one, use that; if you're greenfield, Cloudflare Worker is the least
work to deploy.

## What the reference proxies DON'T do (yet)

These are starting points, not production-grade. Before customer traffic
hits them, add:

- **Origin allowlist** — replace `Access-Control-Allow-Origin: *` with
  your app's actual origin(s). Wildcard + `sk_`-backed proxy is a
  cross-origin session-mint vending machine.
- **Rate limiting** — the upstream `twai-api` per-key concurrency cap is
  the ONLY thing standing between an abusive caller and your bill.
- **User auth** — the proxies here don't authenticate their callers.
  In prod you almost certainly want to bind each mint to an
  authenticated user id so you can track / rate-limit per-user.
- **Session ownership** — `POST /speak`, `DELETE`, etc. currently trust
  the caller to only touch sessions they minted. Add an ownership check
  keyed off the auth in the previous bullet.

The reference SDK app in `apps/twai_api_starter/` (coming next) shows
how a Flutter client wires up to one of these.
