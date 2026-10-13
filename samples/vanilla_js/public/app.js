/*
 * samples/vanilla_js — bit-for-bit copy of Mason's working flow.
 * Server-side (server.mjs) proxies /api/session|say|interrupt|end straight
 * through to Mason's apimila-demo backend at
 * https://staging.coreledgergroup.com/apimila-api/*.
 * Browser-side uses Mason's canonical player (ApiAvatarView from
 * @twai/player, bundled locally) with the session_token that comes back.
 */
import { ApiAvatarView } from '/twai-player.js';

const statusBadge = document.getElementById('statusBadge');
const captionEl = document.getElementById('caption');
const textInput = document.getElementById('textInput');
const sendBtn = document.getElementById('sendBtn');
const stopBtn = document.getElementById('stopBtn');

// 1. Mint a session via our server (which proxies Mason's /apimila-api/session).
const sessionRes = await fetch('/api/session', { method: 'POST' });
if (!sessionRes.ok) {
  statusBadge.textContent = 'could not start session';
  throw new Error(`/api/session ${sessionRes.status}`);
}
const { session_id, client_token, websocket_url } = await sessionRes.json();

// api_origin is the origin of the returned websocket_url.
const apiOrigin = new URL(websocket_url.replace(/^ws/, 'http')).origin;

// 2. Wire up Mason's player. All wire plumbing (MSE, WS, autoplay unmute,
// speaking-event crossfade, reconnect) lives inside @twai/player.
const view = new ApiAvatarView({
  apiOrigin,
  sessionToken: client_token,
  sessionId: session_id,
  speakEndpoint: '/api/say',
  // Mila's idle asset — pulled from Mason's own bundle
  // (staging.coreledgergroup.com/assets/lean-chat-*.js Et.outfits[0].idleUrl).
  idleUrl: 'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4',
  callbacks: {
    onStatusChange: (s) => {
      statusBadge.textContent = s;
      statusBadge.classList.toggle('speaking', s === 'speaking');
    },
    onSpeakingStart: () => {
      statusBadge.textContent = 'speaking…';
      statusBadge.classList.add('speaking');
    },
    onSpeakingStop: () => {
      statusBadge.textContent = 'ready';
      statusBadge.classList.remove('speaking');
    },
    onReply: (text) => {
      captionEl.hidden = false;
      captionEl.textContent = text;
    },
    onError: (err) => console.error('[twai]', err),
  },
});

view.mount(document.getElementById('avatar'));
await view.connect();

// 3. UI events.
sendBtn.addEventListener('click', async () => {
  const text = textInput.value.trim();
  if (!text) return;
  sendBtn.disabled = true;
  textInput.disabled = true;
  try { await view.send(text); textInput.value = ''; }
  finally { sendBtn.disabled = false; textInput.disabled = false; textInput.focus(); }
});
textInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') sendBtn.click(); });
stopBtn.addEventListener('click', () => fetch('/api/interrupt', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ session_id }),
}).catch(() => {}));
window.addEventListener('pagehide', () => {
  view.destroy();
  navigator.sendBeacon('/api/end', JSON.stringify({ session_id }));
});
