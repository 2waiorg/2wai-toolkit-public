# @2wai/web-component-t0

**Transitional JS T0 (LiveKit) `<twai-avatar-t0>` custom element for the 2wai Avatar Toolkit.**

This package ships a drop-in JS/TS web-component that speaks the Transport 0 (LiveKit) wire against a mint proxy. It exists to give JS embedders a T0 shape *today*, while the upstream `@twai/web-component` (Mason's `2waiorg/twai-web-sdk`) is on its own release schedule — see [PR #3](https://github.com/2waiorg/twai-web-sdk/pull/3), which contains the same shape as an upstream proposal.

When PR #3 lands and `@twai/web-component` ships its T0 shape, **this package is deprecated** and consumers migrate. Wire, event names, and callable surface are byte-parallel to that PR — the migration is a rename, not a rewrite.

## Install

This package is not published to npm. It's consumed from within the 2wai-toolkit monorepo, or via a `file:` dep from a sibling project. It depends on `@twai/core` from `2waiorg/twai-web-sdk` at branch `feat/livekit-engine` — you need a sibling checkout of that repo (`../../twai-web-sdk/`).

```jsonc
// consumer package.json
{
  "dependencies": {
    "@2wai/web-component-t0": "file:../../packages/twai_web_component_t0"
  }
}
```

Build:

```
cd packages/twai_web_component_t0
npm run build
```

## Use

```html
<script type="module">
  import { defineTwaiAvatarT0 } from '@2wai/web-component-t0'
  defineTwaiAvatarT0()   // registers <twai-avatar-t0>
</script>

<twai-avatar-t0
  mint-url="https://mint.example.com/v1/sessions"
  idle-url="https://cdn.example.com/idle.mp4"
  stt-url="https://stt.example.com/transcribe"
  autoconnect>
</twai-avatar-t0>

<script type="module">
  const el = document.querySelector('twai-avatar-t0')
  el.addEventListener('twai-ready', () => el.send('Hello.'))
  el.addEventListener('twai-reply', e => console.log(e.detail.text))
  // First-gesture autoplay unlock:
  document.addEventListener('click', () => el.resumePlayback(), { once: true })
</script>
```

For host-side mint (custom auth, non-POST, dynamic body), set the JS property before `connect()`:

```js
import { mintResultFromFetch } from '@twai/core'
const el = document.querySelector('twai-avatar-t0')
el.mint = () => mintResultFromFetch(
  fetch('/mint', { method: 'POST', body: JSON.stringify({ avatar_id: 'avt_...' }) })
)
await el.connect()
```

## Attributes

| Attribute | Required | Default | Description |
|---|---|---|---|
| `mint-url` | one of `mint-url` / JS `mint` | — | URL POSTed to for a `MintResult` |
| `idle-url` | no | — | Looping idle video |
| `poster-url` | no | — | Poster image while idle loads |
| `agent-identity-prefix` | no | `livealman-agent-` | Passed to engine |
| `chat-encoding` | no | `envelope` | `envelope` or `text` |
| `keep-tags` | no | absent | Presence keeps direction tags visible (admin review) |
| `fade-ms` | no | `180` | Idle↔live crossfade duration |
| `autoconnect` | no | absent | Connect on mount |
| `stt-url` | no | absent | When set, renders a push-to-talk MIC button overlay; POSTs recorded audio to this endpoint. Composes [`@twai/mic`](https://github.com/2waiorg/twai-web-sdk/tree/main/packages/mic). |
| `mic-auto-send` | no | (auto-send true) | `"false"` disables auto-send of transcripts after mic release |

## Mic

When `stt-url` is set the element renders a circular MIC overlay button bottom-right of the video. Push-to-talk gesture (pointerdown/up). Disabled while the avatar is speaking (hot-mic feedback mitigation). Auto-sends the transcript on release by default.

Imperative API for hosts driving their own mic button:

```js
el.startMic()               // Promise<void>
el.stopMic()                // Promise<string> — final transcript
el.cancelMic()              // void — abort without transcribing
```

Endpoint contract (matches [`@twai/mic`](https://github.com/2waiorg/twai-web-sdk/tree/main/packages/mic) + [gen-2wai's `/api/gen/dictation/transcribe`](https://github.com/2waiorg/gen-2wai/blob/main/app/api/dictation.py)): `POST` multipart form-data with field `audio` (blob), response `{ "text": "..." }`.

## Events

| Event | Detail |
|---|---|
| `twai-warming` | `{ room }` |
| `twai-ready` | `{ room }` |
| `twai-speaking-start` | — |
| `twai-speaking-stop` | — |
| `twai-reply-start` | `{ replyId }` |
| `twai-reply` | `{ replyId, text }` |
| `twai-reply-complete` | `{ replyId, text, kind }` |
| `twai-ended` | `{ cause }` |
| `twai-notice` | `{ kind }` |
| `twai-error` | `{ error }` |
| `twai-mic-start` | — |
| `twai-mic-stop` | — |
| `twai-transcript` | `{ text }` |
| `twai-mic-error` | `{ error }` |

## Migration to upstream

When Mason's `@twai/web-component` T0 shape ships:

1. Change the import from `@2wai/web-component-t0` to `@twai/web-component/livekit`.
2. Rename `defineTwaiAvatarT0` → `defineTwaiAvatarLiveKit`.
3. Change the tag from `<twai-avatar-t0>` to `<twai-avatar-lk>` (or pass `'twai-avatar-t0'` to `defineTwaiAvatarLiveKit` to keep the toolkit tag).

Nothing else changes — attributes, events, callable methods are identical.
