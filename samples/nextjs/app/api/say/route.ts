import { ensureConfigured, gateway } from '@/lib/gateway';

export async function POST(req: Request) {
  const guard = ensureConfigured();
  if (guard) return guard;

  const { session_id, text } = await req.json().catch(() => ({} as Record<string, unknown>));
  if (!session_id || !text) {
    return Response.json({ error: 'session_id and text required' }, { status: 400 });
  }
  const upstream = await gateway(
    `/v1/sessions/${encodeURIComponent(String(session_id))}/speak`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    },
  );
  if (upstream.status !== 200) {
    console.error('gateway /speak', upstream.status, (await upstream.text()).slice(0, 200));
    return Response.json({ error: 'gateway rejected speak request' }, { status: 502 });
  }
  // In this sample the "reply" is echoed user text (no brain in the loop).
  // Customers with their own brain replace this with brain(text) -> speak(reply).
  return Response.json({ reply: text });
}
