// twai-api mint proxy — Cloudflare Worker.
//
// Fronts https://twai-api.<...>.azurecontainerapps.io with a browser-safe
// facade the 2wai Flutter SDK can point at. Reads SK_KEY from a Worker
// secret; the browser never sees it.
//
// Deploy:
//   wrangler secret put SK_KEY
//   wrangler deploy
//
// Then point the SDK at your Worker URL (e.g. https://twai-proxy.yourdomain.workers.dev).
//
// Env / secrets:
//   SK_KEY           = sk_test_... or sk_live_... (required secret)
//   UPSTREAM         = https://twai-api.<...>.azurecontainerapps.io (var)
//   ALLOWED_ORIGIN   = https://myapp.com (var; default * — tighten in prod)

const DEFAULT_UPSTREAM =
  'https://twai-api.purpleglacier-ffec85d8.westus2.azurecontainerapps.io';

const EXPOSED_HEADERS = [
  'x-request-id',
  'x-twai-concurrent-sessions',
  'x-twai-max-concurrent-sessions',
  'retry-after',
];

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Requested-With',
    'Access-Control-Expose-Headers': EXPOSED_HEADERS.join(', '),
    'Access-Control-Max-Age': '3600',
  };
}

async function proxy(request, url, sk, path) {
  let body;
  if (request.method !== 'GET' && request.method !== 'DELETE') {
    // Some routes (interrupt) have no body — that's fine, .text() returns ''.
    body = await request.text();
  }
  const upstreamHeaders = { Authorization: `Bearer ${sk}` };
  if (body) upstreamHeaders['Content-Type'] = 'application/json';

  const upstreamResp = await fetch(url + path, {
    method: request.method,
    headers: upstreamHeaders,
    body: body || undefined,
  });

  const headers = new Headers();
  const ct = upstreamResp.headers.get('content-type');
  if (ct) headers.set('Content-Type', ct);
  for (const h of EXPOSED_HEADERS) {
    const v = upstreamResp.headers.get(h);
    if (v) headers.set(h, v);
  }
  return { status: upstreamResp.status, headers, body: await upstreamResp.text() };
}

const SESSION_ROUTES = /^\/v1\/sessions(?:\/([^/]+)(?:\/(speak|interrupt))?)?$/;

export default {
  async fetch(request, env) {
    const origin = env.ALLOWED_ORIGIN || '*';
    const cors = corsHeaders(origin);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors });
    }

    const url = new URL(request.url);
    if (url.pathname === '/healthz') {
      return new Response('{"status":"ok"}', {
        headers: { 'Content-Type': 'application/json', ...cors },
      });
    }

    const m = SESSION_ROUTES.exec(url.pathname);
    if (!m) return new Response('not found', { status: 404, headers: cors });

    const [, sid, subroute] = m;
    if (!env.SK_KEY) {
      return new Response('{"error":"SK_KEY secret not configured on Worker"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json', ...cors },
      });
    }
    const upstream = env.UPSTREAM || DEFAULT_UPSTREAM;

    let allowed = false;
    if (request.method === 'POST' && !sid) allowed = true; // POST /v1/sessions
    if (request.method === 'POST' && sid && subroute) allowed = true; // /speak /interrupt
    if (request.method === 'DELETE' && sid && !subroute) allowed = true;

    if (!allowed) {
      return new Response('method not allowed', {
        status: 405,
        headers: cors,
      });
    }

    try {
      const r = await proxy(request, upstream, env.SK_KEY, url.pathname);
      // Merge CORS onto the proxied response.
      for (const [k, v] of Object.entries(cors)) r.headers.set(k, v);
      return new Response(r.body, { status: r.status, headers: r.headers });
    } catch (e) {
      return new Response(`{"error":"upstream fetch failed: ${e.message}"}`, {
        status: 502,
        headers: { 'Content-Type': 'application/json', ...cors },
      });
    }
  },
};
