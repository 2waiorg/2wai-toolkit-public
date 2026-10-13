# twai_api_starter

**Reference SDK app for the twai-api (`/v1/*`) wire on Transport 0 (LiveKit)** via the customer **mint-proxy** pattern. Zero `sk_` in the browser; a customer proxy holds the `sk_` server-side and mints short-lived LiveKit tokens for the client.

Smallest possible customer-facing SDK shape on Transport 0. **Echo mode by default** (avatar says the literal text you type) — customers wire their own brain by hitting `/v1/sessions/:sid/speak` directly with generated reply text (**Option β / BYO brain**).

Cross-platform (web + iOS + Android) from one Flutter codebase.

## What this shows

- `TwaiTransport0Player` widget wrapping the T0 engine lifecycle — one-widget drop-in.
- Mint closure via `TwaiApiRestClient.createLiveKitSession` — the SDK never sees the `sk_`.
- Push-to-talk `TwaiMicButton` next to Send — zero-config mic via `DefaultTranscriber()` (browser `SpeechRecognition` on web, `speech_to_text` on native).
- Every parameter heavily commented — read `lib/main.dart` top-to-bottom to understand the customer surface.

## Contrast with other apps

| App                | Brain            | Shape                                    |
| ------------------ | ---------------- | ---------------------------------------- |
| `twai_api_starter` | echo (none)      | Modern SDK facade — starter template      |
| `enlighten`        | server-side      | Full customer shape — Dr. Alman (iPhone-verified) |
| `jesus`            | server-side      | Full customer shape — Talk2Jesus         |
| `mmm_demo`         | server-side      | Full customer shape + Lumara reconnect discipline |
| `candy_demo`       | customer's brain | BYO-brain via `/v1/sessions/:sid/speak`  |
| `twai_api_demo`    | echo             | Zero-SDK harness (raw livekit_client)    |

`twai_api_demo` and `twai_api_starter` exercise the same wire — `twai_api_demo` proves the gateway works with no SDK; `twai_api_starter` proves the SDK's abstraction over the gateway works.

## Run

### 1. Start a mint proxy in a spare shell

Any of the three from [`apps/mint_proxy_examples/`](../mint_proxy_examples/):

```powershell
# Node
cd apps/mint_proxy_examples/node
npm install
$env:SK_KEY = "sk_test_..."
node server.js

# — or Python —
cd apps/mint_proxy_examples/python
SK_KEY=sk_test_... uvicorn server:app --port 8787

# — or Cloudflare Worker —
cd apps/mint_proxy_examples/cloudflare_worker
wrangler dev
```

All three listen on `http://localhost:8787` by default.

### 2. Run this app

```powershell
cd apps/twai_api_starter

# Web (Chrome)
flutter run -d chrome --web-port 5174

# Android (device via adb — override MINT_PROXY_URL with your LAN IP)
flutter run -d <device> --dart-define=MINT_PROXY_URL=http://192.168.1.42:8787

# iOS (from Mac; see apps/enlighten/docs/ios-setup-mac.md for ATS + signing)
flutter run -d <device>
```

## Override any parameter via dart-define

Every knob in `lib/main.dart` is a `String.fromEnvironment('X', defaultValue: ...)` so you can override at run time without editing code:

```powershell
flutter run -d chrome `
  --dart-define=MINT_PROXY_URL=https://your-proxy.example.com `
  --dart-define=AVATAR_ID=avt_your_registered_id `
  --dart-define=VOICE_ID=vc_your_voice_id `
  --dart-define=IDLE_URL=https://your-cdn/your-idle-loop.mp4
```

## Wire your own brain

Open `lib/main.dart` — around the `TwaiPlayerHandle.forApiSession(...)` call, uncomment and fill in ONE of these:

```dart
// Single-shot brain: SDK awaits your full reply, sends it as one /speak.
brain: (userText) async => await myLLM.reply(userText),
```

```dart
// Streaming brain: your brain calls speak(sentence) per clause.
// First sentence starts playing after ~2-3s on web (vs waiting for the
// whole reply). See apps/enlighten/lib/main.dart for a full implementation.
streamingBrain: (userText, speak) async {
  await for (final sentence in myLLM.streamReply(userText)) {
    await speak(sentence);
  }
  return _fullTextForCaption;
},
```

`brain` and `streamingBrain` are mutually exclusive — pass one or the other, not both.
