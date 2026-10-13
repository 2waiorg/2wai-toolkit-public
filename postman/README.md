# Postman — 2wai API collection

Postman collection + environment for exercising the 2wai gateway. Generated from `openapi/openapi.yaml`.

## Files

- `twai-api.postman_collection.json` — all 11 `/v1/*` operations, grouped by tag.
- `twai-api.postman_environment.json` — three variables: `baseUrl`, `twaiKey`, `sid`.

## Import

1. Postman → **File → Import** → drop both JSON files.
2. Top-right environment selector → pick **2wai API**.
3. Click the environment (eye icon) → set `twaiKey` to your `X-Twai-Key`. Leave `baseUrl` as `https://api.2wai.ai` unless you're hitting a staging deploy.

## Typical flow

```
POST {{baseUrl}}/v1/sessions          → captures `sid` in the response
POST {{baseUrl}}/v1/sessions/{{sid}}/token   → viewer token for the player
POST {{baseUrl}}/v1/sessions/{{sid}}/speak   → push a chat turn
POST {{baseUrl}}/v1/sessions/{{sid}}/interrupt  → cut off in-flight speech
DELETE {{baseUrl}}/v1/sessions/{{sid}}   → end
```

For the split-plane pattern (mint tokens server-side, hand them to the player), see [`apps/mint_proxy_examples/`](../apps/mint_proxy_examples/) and [`apps/twai_api_starter/`](../apps/twai_api_starter/).

## Auth header

Every `/v1/*` operation takes an `authorization` header (case-insensitive). Convention across the toolkit is to send it as `X-Twai-Key: <key>` — the gateway accepts either.

## Regenerating

```powershell
cd postman
npx --yes openapi-to-postmanv2 -s ../openapi/openapi.yaml -o twai-api.postman_collection.json -p
```

Refresh whenever `openapi/openapi.yaml` gets pulled from the canonical URL.
