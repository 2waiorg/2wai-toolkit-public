import { ensureConfigured, gateway } from '@/lib/gateway';

export async function POST(req: Request) {
  const guard = ensureConfigured();
  if (guard) return guard;

  // sendBeacon posts as text/plain — be lenient about how we parse.
  let body: Record<string, unknown> = {};
  const raw = await req.text();
  if (raw) { try { body = JSON.parse(raw); } catch { /* ignore */ } }
  const session_id = body.session_id;
  if (!session_id) return Response.json({ error: 'session_id required' }, { status: 400 });
  await gateway(`/v1/sessions/${encodeURIComponent(String(session_id))}`, { method: 'DELETE' });
  return Response.json({ status: 'ended' });
}
