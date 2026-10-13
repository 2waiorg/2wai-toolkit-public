# twai_api_demo

**Raw-wire teaching artifact.** Direct exercise of the twai-api gateway on Transport 0 (LiveKit) with **zero** `twai_avatar_sdk_*` deps — uses `livekit_client` directly.

Use to prove the gateway + T0 wire behavior before adopting the higher-level SDK.

## What this app is (and isn't)

This is not the app you build with. This is the app you read to understand what the SDK abstracts.

- **Is:** direct `POST /v1/sessions` → mint LiveKit token → `Room.connect(url, token)` → data-topic subscription → `send()` an `lk.chat` envelope → decode `2wai.reply` frames by hand.
- **Isn't:** ergonomic. There is no `TwaiTransport0Player` widget wrapping the lifecycle, no reconnect discipline, no idle-video crossfade, no mic button. Every wire concern is visible in the source.

If you want a real integration, use [`../twai_api_starter`](../twai_api_starter) (SDK + mint-proxy pattern) or [`../enlighten`](../enlighten) (full customer shape).

## Deliberately not using the SDK

The pubspec declares zero `twai_avatar_sdk_*` dependencies. That's the point — if the wire changes in a way this app doesn't tolerate, the SDK abstraction has failed; if this app works and the SDK-based apps don't, the SDK has a bug the wire doesn't share.

For the same reason, this app deliberately **does not** wire the `TwaiMicButton` — mic is an SDK feature, so its absence keeps the "zero SDK deps" invariant clean.

## Run

See [`RUN.md`](RUN.md) for platform-specific commands. Two-shell setup: mint proxy in one, `flutter run` in the other.

## Related

- Wire spec: [wiki.2wai.ai/avatar-toolkit/protocol/livekit/](https://wiki.2wai.ai/avatar-toolkit/protocol/livekit/)
- SDK-based version of this app: [`../twai_api_starter`](../twai_api_starter)
- Full customer-shape reference: [`../enlighten`](../enlighten)
- Toolkit architecture: [`../../docs/architecture.md`](../../docs/architecture.md)
