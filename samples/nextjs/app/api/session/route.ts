import { AVATAR_ID, VOICE_ID, GATEWAY, IDLE_URL, ensureConfigured, gateway } from '@/lib/gateway';

export async function POST() {
  const guard = ensureConfigured();
  if (guard) return guard;

  const upstream = await gateway('/v1/sessions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ avatar_id: AVATAR_ID, mode: 'video', voice_id: VOICE_ID }),
  });
  if (upstream.status !== 201) {
    console.error('gateway /v1/sessions', upstream.status, (await upstream.text()).slice(0, 200));
    return Response.json({ error: 'gateway rejected session request' }, { status: 502 });
  }
  const data = await upstream.json();
  return Response.json({
    session_id:    data.session_id,
    client_token:  data.client_token,
    websocket_url: data.websocket_url,
    api_origin:    GATEWAY,
    idle_url:      IDLE_URL,
  });
}
