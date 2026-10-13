# hello_avatar

The **smallest possible 2wai Avatar app** on Transport 0 (LiveKit). One screen, one widget, one send button, one mic button. Reference implementation of the minimum-viable T0 embed.

If you're new to the toolkit, read this app's `lib/main.dart` (~150 LOC) top-to-bottom before touching any of the fuller samples.

## What it uses

- **[`TwaiTransport0Player`](../../packages/twai_avatar_sdk_livekit/lib/src/transport0/twai_transport0_player.dart)** — the drop-in T0 widget. Consumer provides a mint closure + an idle-video URL + a handful of callbacks.
- **[`TwaiMicButton`](../../packages/twai_avatar_sdk/lib/src/twai_mic_button.dart)** — push-to-talk / tap-to-toggle mic button. Zero-config default via `DefaultTranscriber()` (browser `SpeechRecognition` on web, `speech_to_text` on native).
- **[`TwaiApiRestClient`](../../packages/twai_avatar_sdk_core/lib/src/twai_api/twai_api_rest_client.dart)** — REST client for `POST /v1/sessions` against a customer's mint proxy.
- **[`NetworkVideoIdle`](../../packages/twai_avatar_sdk/lib/src/avatar_idle_source.dart)** — looping idle video source.

What's NOT here: reconnect discipline, chat log, status badge, styled UI, error surfacing. Those live in the fuller samples ([`enlighten`](../enlighten/), [`jesus`](../jesus/), [`mmm_demo`](../mmm_demo/)).

## Running

Two shells: mint proxy in one, `flutter run` in the other.

```bash
# 1. Mint proxy (once, leave running)
SK_KEY=sk_... node apps/mint_proxy_examples/node/server.js

# 2. Frontend
cd apps/hello_avatar
flutter run -d chrome                         # web
flutter run -d <device-id>                    # Android / iOS
```

## Config overrides (dart-define)

```bash
flutter run -d chrome \
  --dart-define=MINT_PROXY_URL=https://<your-proxy>.example.com \
  --dart-define=AVATAR_ID=avt_... \
  --dart-define=IDLE_URL=https://... \
  --dart-define=STT_URL=https://...   # optional: switches mic to HttpSttTranscriber
```

## Read next

- [`../enlighten`](../enlighten/) — full customer-shape app (chat log, status, error handling). Verified on iPhone 15.
- [`../mmm_demo/lib/product_chat_screen.dart`](../mmm_demo/lib/product_chat_screen.dart) — same shape + full Lumara reconnect discipline (`_reconnectToken`, `_pendingUserText`).
- [Toolkit architecture](../../docs/architecture.md).
- [iOS mic + LiveKit coexistence](../../docs/mic_lifecycle_ios_livekit.md) — why the workspace pins `speech_to_text` to a patched copy.
- [Android mic status](../../docs/mic_android_pending.md) — intermittent silent-drop diagnostic + recipe.
