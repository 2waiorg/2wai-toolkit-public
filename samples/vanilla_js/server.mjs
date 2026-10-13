/*
 * samples/vanilla_js server.mjs — canonical mint proxy.
 *
 * The customer server pattern: sk key lives here (env var), browser gets
 * a scoped client_token, everything talks directly to api.2wai.ai/v1/*.
 * No proxy chains. See docs/call_flow.md for the end-to-end diagram.
 *
 * Zero-dependency Node 20+.
 */
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';

const PORT = Number(process.env.PORT || 5173);
const GATEWAY = (process.env.TWAI_GATEWAY || 'https://api.2wai.ai').replace(/\/$/, '');
const SK_KEY = process.env.TWAI_SK;

// Defaults resolve to a working Mila session on the toolkit's demo tenant.
// A customer swaps these to their own registered avatar + voice.
const AVATAR_ID = process.env.TWAI_AVATAR_ID || 'avt_441ad4d95906438490a85b79';
const VOICE_ID  = process.env.TWAI_VOICE_ID  || 'vc_e72e888d566aca3a4e63fbe8';
const IDLE_URL  = process.env.TWAI_IDLE_URL  ||
  'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4';

if (!SK_KEY) {
  console.warn('[warn] TWAI_SK not set — /api/session will return 503.');
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
};

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString('utf-8');
  if (!raw) return {};
  try { return JSON.parse(raw); } catch { return {}; }
}
function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}
async function gateway(path, init = {}) {
  return fetch(`${GATEWAY}${path}`, {
    ...init,
    headers: { ...(init.headers || {}), Authorization: `Bearer ${SK_KEY}` },
  });
}

const routes = {
  'POST /api/session': async (_req, res) => {
    if (!SK_KEY) return json(res, 503, { error: 'server not configured (TWAI_SK missing)' });
    const upstream = await gateway('/v1/sessions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ avatar_id: AVATAR_ID, mode: 'video', voice_id: VOICE_ID }),
    });
    if (upstream.status !== 201) {
      const text = await upstream.text();
      console.error('gateway /v1/sessions', upstream.status, text.slice(0, 200));
      return json(res, 502, { error: 'gateway rejected session request' });
    }
    const data = await upstream.json();
    return json(res, 200, {
      session_id:    data.session_id,
      client_token:  data.client_token,
      websocket_url: data.websocket_url,
      api_origin:    GATEWAY,
      idle_url:      IDLE_URL,
    });
  },

  'POST /api/say': async (req, res) => {
    if (!SK_KEY) return json(res, 503, { error: 'server not configured' });
    const { session_id, text } = await readJson(req);
    if (!session_id || !text) return json(res, 400, { error: 'session_id and text required' });
    const upstream = await gateway(
      `/v1/sessions/${encodeURIComponent(session_id)}/speak`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
      },
    );
    if (upstream.status !== 200) {
      const body = await upstream.text();
      console.error('gateway /speak', upstream.status, body.slice(0, 200));
      return json(res, 502, { error: 'gateway rejected speak request' });
    }
    // In this sample the "reply" is echoed user text (no brain in the loop).
    // Customers with their own brain replace this with brain(text) → speak(reply).
    return json(res, 200, { reply: text });
  },

  'POST /api/interrupt': async (req, res) => {
    if (!SK_KEY) return json(res, 503, { error: 'server not configured' });
    const { session_id } = await readJson(req);
    if (!session_id) return json(res, 400, { error: 'session_id required' });
    // Best-effort: "stop when nothing is playing" is not a failure.
    await gateway(`/v1/sessions/${encodeURIComponent(session_id)}/interrupt`, { method: 'POST' });
    return json(res, 200, { status: 'interrupted' });
  },

  'POST /api/end': async (req, res) => {
    if (!SK_KEY) return json(res, 503, { error: 'server not configured' });
    // sendBeacon posts as text/plain — be lenient.
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const raw = Buffer.concat(chunks).toString('utf-8');
    let body = {};
    if (raw) { try { body = JSON.parse(raw); } catch { /* ignore */ } }
    const session_id = body.session_id;
    if (!session_id) return json(res, 400, { error: 'session_id required' });
    await gateway(`/v1/sessions/${encodeURIComponent(session_id)}`, { method: 'DELETE' });
    return json(res, 200, { status: 'ended' });
  },
};

async function serveStatic(url, res) {
  const path = url === '/' ? '/index.html' : url;
  try {
    const buf = await readFile(join(import.meta.dirname, 'public', path));
    res.writeHead(200, { 'Content-Type': MIME[extname(path)] || 'application/octet-stream' });
    res.end(buf);
  } catch {
    res.writeHead(404).end('not found');
  }
}

const server = createServer(async (req, res) => {
  const key = `${req.method} ${req.url}`;
  if (routes[key]) return routes[key](req, res);
  if (req.method === 'GET') return serveStatic(req.url, res);
  res.writeHead(404).end('not found');
});

server.listen(PORT, () => {
  console.log(`vanilla_js sample listening on http://localhost:${PORT}`);
  console.log(`gateway: ${GATEWAY}`);
  console.log(`avatar:  ${AVATAR_ID}`);
  console.log(`voice:   ${VOICE_ID}`);
});
