import { ensureConfigured, gateway } from '@/lib/gateway';

export async function POST(req: Request) {
  const guard = ensureConfigured();
  if (guard) return guard;

  const { session_id } = await req.json().catch(() => ({} as Record<string, unknown>));
  if (!session_id) return Response.json({ error: 'session_id required' }, { status: 400 });
  // Best-effort: "stop when nothing is playing" is not a failure.
  await gateway(`/v1/sessions/${encodeURIComponent(String(session_id))}/interrupt`, { method: 'POST' });
  return Response.json({ status: 'interrupted' });
}
