# apps/

Reference applications on top of the 2wai Avatar Toolkit — all Flutter, all Transport 0 (LiveKit).

## Principle: T0 only

Every sample in this folder uses **Transport 0 (LiveKit)**. The older MSE-over-WebSocket and HTTP POST + WebSocket paths are retired on the production gateway. The [`avatar_player_lab/`](avatar_player_lab/) diagnostic exercises the player's full surface for debugging; new consumer code targets T0 directly.

## Public samples

| App | Platform | What it is | Pattern |
|---|---|---|---|
| [`hello_avatar/`](hello_avatar/) | Flutter · Web + iOS + Android + desktop | Smallest working avatar app. ~70 LOC of load-bearing code. | T0 default, server-owned brain |
| [`twai_api_demo/`](twai_api_demo/) | Flutter · Web + native | Zero-SDK harness for the raw `/v1/*` wire. Hand-rolled REST + WebSocket. | Teaching artifact; useful for devs building custom Dart tooling |
| [`twai_api_starter/`](twai_api_starter/) | Flutter · Web + iOS + Android + desktop | Echo-mode starter — copy this file, add your brain callback. | T0 + mint-proxy + customer-held LLM |
| [`avatar_only_flutter/`](avatar_only_flutter/) | Flutter · Web (primary) | Avatar-only pattern: 2wai avatar, bring your own brain. | T0 + external brain over mint-proxy |
| [`avatar_player_lab/`](avatar_player_lab/) | Flutter · all platforms | Diagnostic lab exercising the player's full surface. | Internal diagnostic kept public for consumers to inspect |
| [`embed/`](embed/) | Web | Showcase for the `<twai-avatar>` / `<twai-chat>` Custom Elements. | Drop-in web component (vanilla HTML, no framework) |
| [`mint_proxy_examples/`](mint_proxy_examples/) | Node / Python / CF Worker | Server-side mint-proxy templates every T0 integrator needs. | Reference for the mint-proxy pattern enforced across SDKs |

## See also

- [`../ios-native/`](../ios-native/) — Swift SDK + `HelloAvatar` native-iOS sample.
- [`../samples/`](../samples/) — web sample track (vanilla JS / React / Next.js), pairs with [`twai-web-sdk`](https://github.com/2waiorg/twai-web-sdk).
- [`../docs/`](../docs/) — toolkit-orientation docs.
- [https://developers.2wai.ai/](https://developers.2wai.ai/) — the dev-docs site.
