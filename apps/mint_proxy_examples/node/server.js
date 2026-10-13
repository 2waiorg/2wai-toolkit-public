// twai-api mint proxy — Node 18+ / Express.
//
// Fronts https://twai-api.<...>.azurecontainerapps.io with a browser-safe
// facade the 2wai Flutter SDK can point at. Reads config from a local
// `.env` file (via dotenv) or process env — the browser never sees the
// sk_ either way.
//
// Config (all read from .env or the shell environment):
//   SK_KEY           = sk_test_... or sk_live_... (required)
//   UPSTREAM         = https://twai-api.<...>.azurecontainerapps.io
//                      (default: staging URL below)
//   ALLOWED_ORIGIN   = https://myapp.com  (default: * — do NOT ship *)
//   PORT             = 8787  (default)
//   BRAIN_URL        = http://<host>       (default: 2wai prod brain)
//   BRAIN_AVATAR     = brian-alman         (default)
//   BRAIN_MODEL      = gpt-4o              (default)
//   BRAIN_PROVIDER   = openai              (default)
//
// Run:
//   cp .env.example .env         # then edit SK_KEY inside
//   npm install
//   node server.js
//
// Then point the SDK at http://localhost:8787.

// dotenv loads .env from the current working directory into process.env
// BEFORE the first process.env read below. `override: false` means a
// value already set in the real shell environment wins over the .env
// file — useful for one-off overrides like PORT=8788 without editing
// the file.
require('dotenv').config({ override: false });

const express = require('express');

const SK = process.env.SK_KEY;
if (!SK || SK.trim() === '' || SK === 'sk_test_REPLACE_ME') {
  console.error(
    'FATAL: SK_KEY is missing or unset.\n' +
      'Copy .env.example → .env and fill in your sk_test_... key, ' +
      'or export SK_KEY in the shell before running node server.js.',
  );
  process.exit(1);
}
const UPSTREAM =
  process.env.UPSTREAM ??
  'https://twai-api.purpleglacier-ffec85d8.westus2.azurecontainerapps.io';
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN ?? '*';
const PORT = Number(process.env.PORT ?? 8787);
// Optional brain endpoint — when set, /brain proxies to it and returns the
// full reply string. Defaults resolve to the 2wai production brain which
// serves the Dr. Alman + Mila personas.
const BRAIN_URL = process.env.BRAIN_URL ?? 'http://20.221.72.255';
const BRAIN_AVATAR = process.env.BRAIN_AVATAR ?? 'brian-alman';
const BRAIN_MODEL = process.env.BRAIN_MODEL ?? 'gpt-4o';
const BRAIN_PROVIDER = process.env.BRAIN_PROVIDER ?? 'openai';
// Catalog hydrate — reference implementation of GET /v1/avatars/{owner}/{name}.
// Dev-only convenience: this bypasses twai-api and talks DIRECTLY to gen-2wai.
// Once the twai-api gateway ships the real /v1/avatars/{owner}/{name} route
// (see docs/catalog_hydrate_plan.md + the GATEWAY_PR artifact), customers
// should DELETE the /v1/avatars route below and just forward it like the
// session routes do.
//
// GEN_UPSTREAM points at a gen-2wai that owns the avatar catalog. Default is
// the 2wai.ai staging host. GEN_BEARER is a session bearer that gen-2wai
// recognises for sk_-equivalent access (dev-mode). In the production gateway
// this will be replaced by the sk_ → tenant mapping that twai-api already
// does for other /v1/* routes.
const GEN_UPSTREAM = process.env.GEN_UPSTREAM ?? 'https://2wai.ai';
const GEN_BEARER = process.env.GEN_BEARER ?? '';

const app = express();
app.use(express.json());

// CORS. See README on tightening this for production.
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader(
    'Access-Control-Allow-Methods',
    'GET, POST, DELETE, OPTIONS'
  );
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type, X-Requested-With'
  );
  res.setHeader(
    'Access-Control-Expose-Headers',
    'x-request-id, x-twai-concurrent-sessions, x-twai-max-concurrent-sessions, retry-after'
  );
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// Passthrough helper — every SDK call goes through here. We add the sk_
// on the server side; the SDK's headers (if any) are stripped.
async function proxy(req, res, method, path, body) {
  try {
    const upstreamResp = await fetch(UPSTREAM + path, {
      method,
      headers: {
        Authorization: `Bearer ${SK}`,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    // Mirror the interesting response headers back.
    for (const h of [
      'x-request-id',
      'x-twai-concurrent-sessions',
      'x-twai-max-concurrent-sessions',
      'retry-after',
    ]) {
      const v = upstreamResp.headers.get(h);
      if (v) res.setHeader(h, v);
    }
    const text = await upstreamResp.text();
    res
      .status(upstreamResp.status)
      .set(
        'Content-Type',
        upstreamResp.headers.get('content-type') ?? 'application/json'
      )
      .send(text);
  } catch (err) {
    res.status(502).json({ error: `upstream fetch failed: ${err.message}` });
  }
}

app.post('/v1/sessions', (req, res) =>
  proxy(req, res, 'POST', '/v1/sessions', req.body)
);
app.post('/v1/sessions/:sid/speak', (req, res) =>
  proxy(req, res, 'POST', `/v1/sessions/${req.params.sid}/speak`, req.body)
);
app.post('/v1/sessions/:sid/interrupt', (req, res) =>
  proxy(req, res, 'POST', `/v1/sessions/${req.params.sid}/interrupt`, null)
);
app.delete('/v1/sessions/:sid', (req, res) =>
  proxy(req, res, 'DELETE', `/v1/sessions/${req.params.sid}`, null)
);

// ── GET /v1/avatars/{owner}/{name} ───────────────────────────────────────
//
// Catalog-hydrate reference handler. See docs/catalog_hydrate_plan.md for
// the full contract + docs/catalog_hydrate_prior_art_analysis.md for why
// the mapping below looks the way it does (gen-2wai AvatarPage is 80 %
// what we want; we strip social fields + enrich greeting + rename).
//
// This is the HANDLER BLUEPRINT that the twai-api gateway PR will lift
// (translated to the gateway's language of choice). Keeping it here first
// lets us smoke-test the SDK end-to-end against gen-2wai without waiting
// on the gateway deploy, AND leaves customers rolling their own proxy a
// reference they can adapt.
//
// Flow:
//   1. Call gen-2wai GET /api/gen/avatar-page/{owner}/{name}
//      → the slim developer-shaped AvatarPage.
//   2. If private AND the requesting tenant owns the avatar, also call
//      gen-2wai GET /api/gen/view-token/{owner}/{avatarname} to mint a
//      view token (300 s TTL by default). Omitted in this reference —
//      the dev gateway BEARER already has read access to private
//      avatars, so we pass a stub viewToken shape for now. The real
//      gateway (post-PR) must gate view-token issuance on sk_ tenant
//      ownership.
//   3. If greeting is present on AvatarPage, call
//      GET /api/gen/avatars/{rid}/greeting-meta (new on gen-2wai; see
//      GATEWAY_PR.md) to enrich with id/kind/consumption_key, OR
//      synthesise sensible defaults if that endpoint is not deployed.
//   4. Translate AvatarPage → TwaiApiAvatar shape (rename + strip).
//   5. Return 404 unchanged — SDK already classifies as
//      TwaiApiAvatarNotFoundException.
app.get('/v1/avatars/:owner/:name', async (req, res) => {
  const { owner, name } = req.params;
  const genPath = `/api/gen/avatar-page/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`;
  try {
    const upstream = await fetch(GEN_UPSTREAM + genPath, {
      method: 'GET',
      headers: GEN_BEARER
        ? { Authorization: `Bearer ${GEN_BEARER}` }
        : {},
    });
    if (upstream.status === 404) {
      return res
        .status(404)
        .json({ detail: 'no_such_avatar' });
    }
    if (!upstream.ok) {
      const body = await upstream.text();
      console.error('[avatars] upstream', upstream.status, body.slice(0, 300));
      return res
        .status(502)
        .json({ error: `avatar-page upstream ${upstream.status}` });
    }
    const page = await upstream.json();

    // Translate AvatarPage → TwaiApiAvatar. Field mapping documented
    // in docs/catalog_hydrate_prior_art_analysis.md.
    const avatar = {
      owner: page.owner,
      name: page.avatarname,       // AvatarPage.avatarname → avatar.name
      display_name: page.name,     // AvatarPage.name → avatar.display_name
      avatar_id: page.rid,         // AvatarPage.rid → avatar.avatar_id
      listed: page.listed,
      idle_url: page.idleUrl ?? null,
      poster_url: page.posterUrl ?? null,
      greeting: page.greeting
        ? {
            // AvatarPage.greeting is {video_url, text} — we synthesise
            // id/kind here as the dev fallback. The REAL gateway PR
            // enriches these from gen-2wai's richer catalog row
            // (which carries row id + intro/return kind +
            // consumption_key for return greetings).
            id: `grt_${page.rid}`,
            video_url: page.greeting.video_url,
            text: page.greeting.text,
            kind: 'intro',
            // consumption_key omitted — the dev fallback can't
            // distinguish intro vs return.
          }
        : null,
    };

    // Private tenant-owned avatars return a view token too. Reference
    // only emits a stub so the SDK's typed-shape path exercises;
    // real gateway integrates with the view-token minting flow.
    const view_token = page.listed === false
      ? { token: 'devOnly-stub-not-for-production', expires_at: null }
      : null;

    return res.json({ avatar, view_token });
  } catch (err) {
    console.error('[avatars] fetch failed', err);
    return res
      .status(502)
      .json({ error: `avatar-page fetch failed: ${err.message}` });
  }
});

// Optional /brain route — takes {text, user_id?} and streams the brain's
// SSE, returning the FINAL reply text as JSON. Used by demo apps whose
// TwaiPlayerHandle wires a brain callback. Skip in production if your
// app has its own brain — this is a reference for the "we mint AND
// brain" case.
app.post('/brain', async (req, res) => {
  const text = (req.body?.text ?? '').toString();
  const user_id = (req.body?.user_id ?? `demo-${Date.now()}`).toString();
  if (!text.trim()) return res.status(400).json({ error: 'text is required' });
  try {
    const upstream = await fetch(`${BRAIN_URL}/chat/stream`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify({
        message: text,
        user_id,
        avatar: BRAIN_AVATAR,
        model: BRAIN_MODEL,
        provider: BRAIN_PROVIDER,
      }),
    });
    if (!upstream.ok) {
      const body = await upstream.text();
      console.error('[brain] upstream', upstream.status, body.slice(0, 200));
      return res.status(502).json({ error: `brain upstream ${upstream.status}` });
    }
    // Read the SSE stream, extract the `final` event's content field.
    const raw = await upstream.text();
    let finalText = '';
    let currentEvent = null;
    for (const line of raw.split(/\r?\n/)) {
      if (!line) { currentEvent = null; continue; }
      if (line.startsWith('event:')) { currentEvent = line.slice(6).trim(); continue; }
      if (line.startsWith('data:') && currentEvent === 'final') {
        try {
          const payload = JSON.parse(line.slice(5).trim());
          if (typeof payload.content === 'string') finalText = payload.content;
        } catch { /* ignore */ }
      }
    }
    if (!finalText) return res.status(502).json({ error: 'brain returned no final event' });
    res.json({ reply: finalText });
  } catch (err) {
    res.status(502).json({ error: `brain fetch failed: ${err.message}` });
  }
});

// Streaming brain: SSE passthrough from BRAIN_URL/chat/stream. The
// Flutter SDK's TwaiStreamingBrainCallback consumes this stream and
// drives per-sentence /speak calls as SSE delta events arrive — the
// same pattern Mason's apimila-demo uses (see
// apimila-demo/app/main.py::_stream_brain_to_speech).
//
// Time-to-first-word drops from ~full-turn-latency to ~first-sentence-
// latency because the avatar starts speaking after the first sentence
// lands, not after the whole reply finishes generating.
app.post('/brain/stream', async (req, res) => {
  const text = (req.body?.text ?? '').toString();
  const user_id = (req.body?.user_id ?? `demo-${Date.now()}`).toString();
  if (!text.trim()) return res.status(400).json({ error: 'text is required' });
  try {
    const upstream = await fetch(`${BRAIN_URL}/chat/stream`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify({
        message: text,
        user_id,
        avatar: BRAIN_AVATAR,
        model: BRAIN_MODEL,
        provider: BRAIN_PROVIDER,
      }),
    });
    if (!upstream.ok) {
      const body = await upstream.text();
      console.error('[brain-stream] upstream', upstream.status, body.slice(0, 200));
      return res.status(502).json({ error: `brain upstream ${upstream.status}` });
    }
    // Stream SSE straight through. Set headers first so Node flushes them
    // before any bytes arrive.
    res.status(200).set({
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no', // hint for reverse-proxy buffering
    });
    if (typeof res.flushHeaders === 'function') res.flushHeaders();
    const reader = upstream.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(Buffer.from(value));
      }
    } finally {
      reader.releaseLock();
      res.end();
    }
  } catch (err) {
    console.error('[brain-stream] fetch failed', err);
    if (!res.headersSent) {
      res.status(502).json({ error: `brain fetch failed: ${err.message}` });
    } else {
      res.end();
    }
  }
});

// Healthcheck for load balancers.
app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.listen(PORT, () => {
  console.log(
    `[mint-proxy] listening on http://localhost:${PORT}  ->  ${UPSTREAM}  (origin: ${ALLOWED_ORIGIN})`
  );
});
