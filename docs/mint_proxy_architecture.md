# Mint proxy — internal (Alex/Mason) vs external (customer developers)

The mint proxy is the piece of Adapter 4 that trips people up first because it means different things to different audiences. This doc pins the framing.

## What a mint proxy is (30 seconds)

A tiny HTTP server the customer runs. It:

1. Holds the `sk_` secret key in server-side environment variables — **never in the browser**.
2. Accepts `/v1/*` requests from the customer's browser (or mobile app).
3. Forwards each request to `api.2wai.ai/v1/*` with `Authorization: Bearer sk_...` added.
4. Returns the response verbatim to the browser.

That's it. ~80 LOC of Node / Python / whatever. Reference implementations at [`apps/mint_proxy_examples/`](../apps/mint_proxy_examples/).

## Why it exists

The gateway accepts two credential shapes:

- **`sk_` (secret key)** — full-privilege. Can mint sessions, list avatars, register voices, delete sessions. **Server-side only.**
- **`client_token`** — short-lived (1hr TTL), scoped to a single WebSocket connection for a single session. Safe to hand to a browser.

The mint proxy exists to bridge these two worlds: the customer's browser needs to `POST /v1/sessions` (an `sk_`-required call) to get a `client_token`, but must NEVER see the `sk_` itself. So the customer's server does the mint on the browser's behalf.

Split-plane security:

```
┌────────────────┐    /v1/sessions      ┌──────────────┐    /v1/sessions    ┌──────────┐
│  Browser       │  ─────────────────► │  Customer's  │ ─── + sk_ Bearer ─►│  2wai    │
│  (no sk_)      │                     │  mint proxy  │                    │  gateway │
│                │ ◄─── client_token ─ │  (holds sk_) │ ◄── client_token ─ │          │
└────────────────┘                     └──────────────┘                    └──────────┘
       │                                                                        ▲
       │            WSS connect with client_token                                │
       └────────────────────────────────────────────────────────────────────────┘
```

Once the WS is up, the browser streams directly from the gateway — the mint proxy is only in the loop for REST calls (`/sessions`, `/speak`, `/interrupt`).

## Two audiences, two very different pictures

The rest of this doc splits the story by who's asking:

---

## Internal — Alex, Mason, the 2wai team

**Short version:** you don't need a mint proxy for anything that touches the gateway with a 2wai-owned `sk_`. You either bypass the proxy (direct sk_ calls from server-side tools) or run a scratch one for a specific dev scenario.

### When the internal team runs a mint proxy

| Scenario | Mint proxy needed? | Notes |
|---|---|---|
| Testing the twai-api gateway with `curl` / Postman / a Dart CLI tool | **No** — server-side sk_ direct | See [`tools/list_avatars.dart`](../tools/list_avatars.dart) for the pattern. |
| Running a demo Flutter web app locally (enlighten, twai_api_starter) | **Yes** — dev-scratch proxy | Node reference on port 8787: `node apps/mint_proxy_examples/node/server.js`. Same sk_ as the real gateway; only exists so the Flutter web app can hit `http://localhost:8787` from the browser without ever holding sk_. |
| Load-testing Mila (`apps/candy_demo`) | **Yes** — dev-scratch proxy | Same Node proxy above. Plus a Python mock brain server on a different port. |
| Building a new internal app that will eventually ship to customers | **Yes** — treat it as an external customer would (see below) | Do this from day one. Never let sk_ leak into any Dart file that gets built for the web target. |
| Talk2Jesus mobile production | **N/A** — Talk2Jesus is on Adapter 1 (penthouse `/ext-api-muse`) which has no proxy story | Adapter 1 uses the `TwaiPlayerHandle()` default constructor and speaks directly to `staging.coreledgergroup.com` / `2wai.ai`. sk_ isn't in the picture for Adapter 1. |

### Where sk_ lives (internal)

- **Personal dev:** in each engineer's local env var (`$env:SK_KEY = "sk_test_..."` before starting a mint proxy). Never checked in.
- **Shared testing:** the `apimila-demo` Azure Container App holds the tenant-shared sk_test. Fetch recipe: `~/.claude/projects/c--Dev-2wai-toolkit/memory/reference_twai_gateway_test_credentials.md` (also documented in the wiki, internal-only page).
- **Prod:** managed by whoever owns the tenant. Rotated on schedule (rotation process TBD — see [`docs/open_questions_and_production_readiness.md`](open_questions_and_production_readiness.md) §1).

### What internal team does NOT need to worry about

- **Deploying a mint proxy to prod infrastructure** — 2wai doesn't run one for its own products. Talk2Jesus (Adapter 1) doesn't need one. Any 2wai product on Adapter 4 would run it as an internal server-side component of that product, not as toolkit infrastructure.
- **CORS setup, TLS, rate limiting on the mint proxy** — customer concerns. Our reference implementations show the minimum; hardening is the customer's responsibility.
- **Multi-tenant isolation** — 2wai gateway owns tenant boundaries. Mint proxies are per-customer by construction.

### Mason-specific: what the toolkit's mint proxies mean for the gateway

- Every request from a mint proxy arrives at `api.2wai.ai` with the customer's `sk_` in the Authorization header. Nothing about the wire changes vs. a direct `curl` call.
- The proxy is invisible to the gateway. If you're debugging a gateway request, `x-request-id` from a mint-proxy-routed call looks identical to any other.
- The proxy adds a client-side hop (browser → customer server → gateway) but does NOT add latency to the WebSocket, which goes direct browser → gateway.

---

## External — a developer at Candy.ai, Enlighten, or any other customer

**Short version:** you write a tiny server. Deploy it anywhere Node / Python / your-preferred-runtime runs. Point your browser / mobile app at it instead of at `api.2wai.ai` directly. Done.

### Three deployment shapes customers actually pick

Ranked by frequency:

**Shape A — mint proxy is your existing backend.** You already have a Node/Rails/Django/Fastify/etc. backend. Add 4 route handlers to it. sk_ becomes another env var alongside your DB creds and Stripe keys. Zero new infrastructure.

Example: `apps/candy_demo_external` (Next.js) — the four `/api/*` Route Handlers ARE the mint proxy. One `npm run start` gives you client + mint in one deploy.

**Shape B — mint proxy is a serverless function.** Cloudflare Worker, Vercel Edge Function, AWS Lambda. sk_ as a secret env var. Point your web/mobile client at the function URL.

Example: [`apps/mint_proxy_examples/cloudflare_worker/`](../apps/mint_proxy_examples/cloudflare_worker/).

**Shape C — mint proxy is a standalone service.** Dedicated tiny Node/Python container. Deploy on Fly.io, Railway, your own Kubernetes, whatever. Best when you have multiple front-ends (web + iOS + Android) all hitting the same proxy.

Example: [`apps/mint_proxy_examples/node/server.js`](../apps/mint_proxy_examples/node/server.js) or the Python variant. This is what Jim's dev box runs on port 8787 for local Flutter testing.

### Deployment topology

```
                              ┌──────────────────────┐
                              │  Customer's users    │
                              │  (browser / mobile)  │
                              └──────────┬───────────┘
                                         │  HTTPS / WSS
                                         ▼
                              ┌──────────────────────┐
                              │  Customer's mint     │
                              │  proxy               │
                              │  (holds sk_)         │
                              └──────────┬───────────┘
                                         │  HTTPS + sk_ Bearer
                                         ▼
                              ┌──────────────────────┐
                              │  api.2wai.ai/v1/*    │
                              └──────────┬───────────┘
                                         │  WSS (direct — bypasses proxy)
                                         ▼
                              ┌──────────────────────┐
                              │  Customer's users    │
                              │  (receiving fMP4)    │
                              └──────────────────────┘
```

REST goes browser → proxy → gateway. WS goes browser → gateway direct (after the proxy mints the `client_token`).

### What the customer's proxy MUST do

1. Accept `POST /v1/sessions` from their frontend; forward to `https://api.2wai.ai/v1/sessions` with `Authorization: Bearer sk_...`; return the response body verbatim (contains `session_id` + `client_token` + `websocket_url`).
2. Same passthrough for `POST /v1/sessions/{sid}/speak`, `POST /v1/sessions/{sid}/interrupt`, `DELETE /v1/sessions/{sid}`.
3. Add CORS headers so the browser can talk to the proxy (customer sets whatever origin their frontend runs on).

That's it. **Four routes**, ~80 LOC in Node.

> **Pitfall — routes MUST include the `/v1/` prefix.** `TwaiApiRestClient` on the client side always resolves paths as `baseUrl.resolve('v1/sessions')` internally. If the customer's proxy mounts routes at `/sessions` (dropping the `v1/`), every mint call returns 404. Match the reference exactly: `POST /v1/sessions`, `POST /v1/sessions/:sid/speak`, `POST /v1/sessions/:sid/interrupt`, `DELETE /v1/sessions/:sid`. See [`docs/flutter_consumer_integration_gotchas.md`](flutter_consumer_integration_gotchas.md) §2.

### What the customer's proxy CAN do (optional value-adds)

- **Wrap their own auth** — require a user session / JWT before minting a `/v1/sessions` call. Prevents anonymous session creation from anyone hitting the URL.
- **Rate limit** — per-user session-mint quotas above and beyond what the gateway enforces.
- **Log request-id correlation** — capture the `x-request-id` from every response for support tickets.
- **Route the brain** — expose `/brain` or `/brain/stream` that proxies to 2wai's production brain (per `apps/mint_proxy_examples/node/server.js`) OR to the customer's own LLM. When wiring `streamingBrain` on the Flutter side, the callback POSTs to whatever URL the customer specifies.

The reference `apps/mint_proxy_examples/node/server.js` includes the optional brain routes; strip them if the customer's LLM is called directly from their frontend without going through the proxy.

### What the customer's proxy MUST NOT do

- Ship `sk_` to the browser (including in any HTML data attribute, JS bundle, or debug console log).
- Log `sk_` in structured logs (it's a bearer token; treat it like a password).
- Accept the `client_token` as auth for `/v1/sessions` calls (client_tokens are session-scoped, not admin-scoped — mint requires sk_).

### Where sk_ lives (external)

- **Dev:** developer's local `.env` file (gitignored) or shell env var.
- **Staging / prod:** platform secret (Vercel Environment Variable, AWS Secrets Manager, Kubernetes Secret, etc.).
- **Rotation:** customer's schedule — they contact 2wai support (or use the admin tool when it goes prime-time) to issue a new key and retire the old.

### Cost / infrastructure story for the customer

The mint proxy adds almost nothing:

- **Latency:** one extra hop for REST calls only (~5-20ms depending on where the proxy lives). WS is unaffected.
- **CPU / memory:** the proxy is a passthrough — no computation. A single-core VM handles thousands of req/s.
- **Cost:** if using their existing backend (Shape A), the marginal cost is zero. If serverless (Shape B), a few cents per million requests. If dedicated (Shape C), a $5/mo Fly.io machine or equivalent.

## Common questions

**Q: Can we skip the mint proxy for prototypes?**

Yes — for a Dart CLI or an internal-only script, use `sk_` directly. Only mandatory for browser / mobile-app deploys where the sk_ would ship in the bundle.

**Q: What if the customer uses Adapter 1 instead of Adapter 4?**

Then no mint proxy needed at all. Adapter 1 (penthouse `/ext-api-muse`) is direct-to-server today. The tradeoff: 2wai owns the LLM (customer can't plug in theirs). See [`docs/pitch_toolkit_platform_matrix.md`](pitch_toolkit_platform_matrix.md) for the adapter decision framing.

**Q: Does the customer's LLM go through the mint proxy?**

Only if they choose to. Two patterns:
- **LLM proxied through mint:** customer's mint proxy exposes `/brain` and `/brain/stream` routes; their Flutter client's `streamingBrain` callback POSTs to those. Server-side, the proxy calls their LLM. Keeps the LLM API key server-side too.
- **LLM called directly from customer's frontend:** their Flutter/JS code calls their LLM's SDK (OpenAI, Anthropic, whatever) directly using their own auth story. Mint proxy only handles the `/v1/*` calls.

Which they pick depends on where they already keep their LLM API key.

**Q: Can 2wai host a mint proxy for the customer as a service?**

Technically yes — we already have the tenant-scoped sk_ story. But then 2wai holds every customer's brain integration secrets, tenant boundaries need per-tenant enforcement on the proxy, and we're on the hook for uptime + rate limits. Long-term product decision (see [`docs/open_questions_and_production_readiness.md`](open_questions_and_production_readiness.md) §2 auth section).

Not a v1 offering today. Customers run their own proxy.

**Q: What breaks if the customer's mint proxy goes down?**

New sessions can't be minted → new users see "connecting…" hang. Existing sessions keep running (their `client_token` is already in the browser and the WS is direct-to-gateway). So it's a partial-degradation, not a full outage.

Standard high-availability practices (multiple instances behind a load balancer) apply. Very small state — no persistence needed — makes HA cheap.

## See also

- [`apps/mint_proxy_examples/`](../apps/mint_proxy_examples/) — three reference implementations (Node / Python / Cloudflare Worker)
- [`apps/candy_demo_external/`](../apps/candy_demo_external/) — a mint proxy fused with a Next.js customer frontend, one deploy
- [`docs/flutter_consumer_integration_gotchas.md`](flutter_consumer_integration_gotchas.md) — the four traps that bite consumer teams first (plugin-registrant stale cache, `/v1/` prefix, layout embellishments, per-platform registrants)
- [`docs/flutter_app_call_flow.md`](flutter_app_call_flow.md) — Adapter 4 sequence diagram showing mint-proxy hop in context
- [`docs/pitch_toolkit_platform_matrix.md`](pitch_toolkit_platform_matrix.md) — when to pick Adapter 1 (no proxy) vs Adapter 4 (proxy)
- [`docs/run_scripts.md`](run_scripts.md) — commands for spinning up mint proxies during local dev
- [`docs/open_questions_and_production_readiness.md`](open_questions_and_production_readiness.md) — gaps we still owe answers on (auth enforcement, admin endpoints, hosted-proxy-as-a-service question)
