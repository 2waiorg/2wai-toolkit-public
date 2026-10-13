/*
 * samples/react — React counterpart to samples/vanilla_js.
 * Same wire flow (see docs/call_flow.md): server proxies /api/* to Mason's
 * apimila-demo mint proxy; client uses Mason's ApiAvatarView from @twai/player.
 * The React piece is just useEffect + a container ref; the player owns the DOM
 * inside it.
 */
import { useEffect, useRef, useState, useCallback } from 'react';
import { ApiAvatarView } from '@twai/player';

interface SessionInfo {
  session_id: string;
  client_token: string;
  websocket_url: string;
}

export function App() {
  const containerRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<ApiAvatarView | null>(null);
  const sessionRef = useRef<SessionInfo | null>(null);
  const [status, setStatus] = useState('connecting…');
  const [caption, setCaption] = useState<string | null>(null);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);

  // Mint session + mount player on first render.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const res = await fetch('/api/session', { method: 'POST' });
      if (!res.ok) { setStatus('could not start session'); return; }
      const s: SessionInfo = await res.json();
      if (cancelled || !containerRef.current) return;
      sessionRef.current = s;
      const view = new ApiAvatarView({
        apiOrigin: new URL(s.websocket_url.replace(/^ws/, 'http')).origin,
        sessionToken: s.client_token,
        sessionId: s.session_id,
        speakEndpoint: '/api/say',
        idleUrl: 'https://2waiassets.blob.core.windows.net/avatars/Mila/Idles/Mila_Idle1.mp4',
        callbacks: {
          onStatusChange: (st) => setStatus(st === 'speaking' ? 'speaking…' : st),
          onSpeakingStart: () => setStatus('speaking…'),
          onSpeakingStop: () => setStatus('ready'),
          onReply: (t) => setCaption(t),
          onError: (err) => console.error('[twai]', err),
        },
      });
      viewRef.current = view;
      view.mount(containerRef.current);
      await view.connect();
    })();
    return () => {
      cancelled = true;
      viewRef.current?.destroy();
      const s = sessionRef.current;
      if (s) navigator.sendBeacon('/api/end', JSON.stringify({ session_id: s.session_id }));
    };
  }, []);

  const onSend = useCallback(async () => {
    const t = text.trim();
    if (!t || busy || !viewRef.current) return;
    setBusy(true);
    try { await viewRef.current.send(t); setText(''); }
    finally { setBusy(false); }
  }, [text, busy]);

  const onStop = useCallback(() => {
    const s = sessionRef.current;
    if (!s) return;
    fetch('/api/interrupt', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_id: s.session_id }),
    }).catch(() => {});
  }, []);

  return (
    <>
      <h1 style={{ fontSize: '1.15rem', fontWeight: 600, margin: '0 0 4px' }}>2wai avatar — React sample</h1>
      <p style={{ color: '#9797a8', fontSize: '0.85rem', margin: '0 0 20px' }}>
        Split-plane reference — server holds the sk key, client only holds a scoped token.
      </p>

      <div style={{
        position: 'relative', width: '100%', maxWidth: 480,
        aspectRatio: '3 / 4', background: '#000',
        border: '1px solid #2a2a35', borderRadius: 12, overflow: 'hidden',
      }}>
        <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
        <div style={{
          position: 'absolute', top: 10, left: 10,
          padding: '4px 10px', borderRadius: 999,
          background: 'rgba(0,0,0,0.55)', fontSize: '0.75rem',
          color: status === 'speaking…' ? '#b98cff' : '#9797a8',
          border: `1px solid ${status === 'speaking…' ? '#b98cff' : '#2a2a35'}`,
          zIndex: 2,
        }}>{status}</div>
        {caption && (
          <div style={{
            position: 'absolute', left: 10, right: 10, bottom: 10,
            padding: '10px 12px', background: 'rgba(0,0,0,0.6)',
            border: '1px solid #2a2a35', borderRadius: 10,
            fontSize: '0.9rem', maxHeight: '30%', overflowY: 'auto', zIndex: 2,
          }}>{caption}</div>
        )}
      </div>

      <div style={{ width: '100%', maxWidth: 480, marginTop: 14, display: 'flex', gap: 8 }}>
        <input
          type="text"
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') onSend(); }}
          placeholder="Type something for the avatar to say…"
          autoComplete="off"
          style={{
            flex: 1, padding: '10px 12px', borderRadius: 8,
            border: '1px solid #2a2a35', background: '#17171f',
            color: '#eaeaf0', fontSize: '0.9rem',
          }}
        />
        <button onClick={onSend} disabled={busy}
          style={{
            padding: '10px 16px', borderRadius: 8,
            border: '1px solid #b98cff', background: '#b98cff',
            color: '#1a0e2e', fontSize: '0.9rem', fontWeight: 600,
            cursor: busy ? 'default' : 'pointer', opacity: busy ? 0.5 : 1,
          }}>Send</button>
        <button onClick={onStop}
          style={{
            padding: '10px 16px', borderRadius: 8,
            border: '1px solid #2a2a35', background: '#17171f',
            color: '#eaeaf0', fontSize: '0.9rem', cursor: 'pointer',
          }}>Stop</button>
      </div>
    </>
  );
}
