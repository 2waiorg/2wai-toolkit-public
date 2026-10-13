# docs/

Public developer references for the 2wai Avatar Toolkit. Anything a developer who's been granted access to this repo needs to read to integrate against the toolkit.

Internal planning docs, pitch material, session handoffs, and design iterations live under [`internal/`](internal/).

## Contents

- [`protocol.md`](protocol.md) — The 2wai avatar wire protocol (short form).
- [`wire_protocol_deep_dive.md`](wire_protocol_deep_dive.md) — Protocol reference, long form.
- [`sdk_overview.md`](sdk_overview.md) — What the Flutter SDK is and how its pieces fit.
- [`architecture.md`](architecture.md) — End-to-end architecture (SDK → gateway → pipeline).
- [`integration_shapes.md`](integration_shapes.md) — Shape-by-shape integration patterns.
- [`avatar_input_spec.md`](avatar_input_spec.md) — What an avatar's input assets look like.
- [`mint_proxy_architecture.md`](mint_proxy_architecture.md) — Why you must hold `sk_` server-side and how the mint proxy pattern enforces that.
- [`catalog_hydrate_service_bearer_install.md`](catalog_hydrate_service_bearer_install.md) — Ops recipe for the shared service bearer between twai-api gateway and gen-2wai.
- [`voice_and_tts.md`](voice_and_tts.md) — Voice clone + TTS reference.
- [`flutter_consumer_integration_gotchas.md`](flutter_consumer_integration_gotchas.md) — Four canonical Flutter integration traps.
- [`mic_lifecycle_ios_livekit.md`](mic_lifecycle_ios_livekit.md) — iOS mic + LiveKit audio-session coexistence rules (what the vendored `twai_speech_to_text_patched` package exists to solve).

## Where to look for more

- [wiki.2wai.ai/avatar-toolkit/](https://wiki.2wai.ai/avatar-toolkit/) — the canonical, searchable reference. The wiki is where cross-repo architecture decisions and the LiveKit transport story live.
- [`internal/`](internal/) — planning docs, session handoffs, pitch material (not for external developers).
- [`../README.md`](../README.md) — top-level toolkit README (install, quickstart, repo map).
- [`../apps/`](../apps/) — public reference apps (and `apps/internal/` for the non-public ones).
