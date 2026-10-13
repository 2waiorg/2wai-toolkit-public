# OpenAPI — 2wai API spec

Snapshot of the 2wai gateway spec. Use it for offline tooling (Postman generation, codegen, samples that pin against a known shape).

## Canonical vs snapshot

- **Canonical URL:** [`https://api.2wai.ai/v1/openapi.yaml`](https://api.2wai.ai/v1/openapi.yaml) — served by Mason's gateway. Deep-copies FastAPI's generated schema and strips `/admin/*`. Always current; may drift ahead of this snapshot.
- **Hand-curated public copy:** [`developers.2wai.ai/openapi.yaml`](https://developers.2wai.ai/openapi.yaml) — same shape as the snapshot but with polished descriptions + examples. Preferred for docs / partner integrations.
- **This snapshot:** frozen version pinned into the repo. Refresh on a cadence (see below).

## What's in scope

11 paths, all under `/v1/*` (the customer surface). `/admin/*` is stripped upstream.

| Path | Purpose |
|---|---|
| `POST /v1/files` | Upload reference audio for voice clones |
| `POST /v1/voices` | Create a voice from an uploaded file |
| `GET/POST /v1/sessions` | List / create avatar sessions |
| `GET/PATCH/DELETE /v1/sessions/{sid}` | Session lifecycle |
| `POST /v1/sessions/{sid}/token` | Mint a short-lived viewer token (split-plane) |
| `POST /v1/sessions/{sid}/waiting_state` | Pre-warm connection |
| `POST /v1/sessions/{sid}/speak` | Push a chat turn |
| `POST /v1/sessions/{sid}/audio` | Push mic audio for STT |
| `POST /v1/sessions/{sid}/interrupt` | Cut off in-flight speech |
| `GET /healthz` | Liveness probe |

## Refresh recipe

```powershell
curl -sS -o openapi/openapi.yaml https://api.2wai.ai/v1/openapi.yaml
git diff openapi/openapi.yaml   # eyeball what changed
```

If the diff has new operations or breaking changes, regenerate the Postman collection under `postman/` and update samples that pin against the old shape.

## What this powers

- `postman/` — collection generated from this snapshot
- `samples/` — vanilla JS / React / Next.js reference clients
- Flutter SDK's Adapter 4 (`packages/twai_avatar_sdk_core/lib/src/adapters/twai_api/`) — the Dart types are hand-modeled after this spec, not codegen'd
