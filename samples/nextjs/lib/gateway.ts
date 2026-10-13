/*
 * Server-only helper — canonical mint proxy to api.2wai.ai/v1/*.
 * sk key held server-side (TWAI_SK env). Browser never sees it.
 *
 * See docs/call_flow.md for the end-to-end call diagram.
 */
const GATEWAY = (process.env.TWAI_GATEWAY || 'https://api.2wai.ai').replace(/\/$/, '');
const SK_KEY = process.env.TWAI_SK;

// Defaults resolve to a working Mila session on the toolkit's demo tenant.
// A customer swaps these to their own registered avatar + voice.
export const AVATAR_ID = process.env.TWAI_AVATAR_ID || 'avt_441ad4d95906438490a85b79';
export const VOICE_ID  = process.env.TWAI_VOICE_ID  || 'vc_e72e888d566aca3a4e63fbe8';
export const IDLE_URL  = process.env.TWAI_IDLE_URL  ||
  'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4';
export { GATEWAY };

export function ensureConfigured(): Response | null {
  if (!SK_KEY) {
    return Response.json(
      { error: 'server not configured (TWAI_SK missing)' },
      { status: 503 },
    );
  }
  return null;
}

export async function gateway(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${GATEWAY}${path}`, {
    ...init,
    headers: {
      ...(init.headers || {}),
      Authorization: `Bearer ${SK_KEY}`,
    },
    cache: 'no-store',
  });
}
