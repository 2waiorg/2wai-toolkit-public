# Catalog Hydrate — shared service bearer install recipe

**Status:** 2026-10-06. Awaiting Ops install before either feat branch
can merge.

The catalog-hydrate flow has two services calling each other:

* `twai-api` gateway (`api.2wai.ai`) → `gen-2wai` on `POST
  /api/gen/internal/sk-resolve` and `GET /api/gen/internal/avatars-
  by-name/{owner}/{name}`.

Both calls carry `X-Internal-Bearer: <shared secret>`. The receiving
service compares (constant-time) against its own configured value.
Mismatch → 401. Receiver has no value configured → 401 "Bridge not
configured" (fail-closed).

The two configured values **MUST be the same bytes**; the services
read it under two different env-var names so each repo keeps its
local naming conventions clean.

| Service | Env var | Config attribute |
|---|---|---|
| `twai-api` gateway | `TWAI_GEN_SERVICE_BEARER` | `settings.gen_service_bearer` |
| `gen-2wai` | `GEN_INTERNAL_SERVICE_BEARER` | `settings.gen_internal_service_bearer` |

## Generate

The bearer is 32 bytes of CSPRNG output, encoded as 64 hex chars.
Jim/Mason: run this on your box, keep the output. It is handed to the
Vault once and never kept on disk again (same discipline as every
other sk_).

```python
import secrets
print(secrets.token_hex(32))
```

Already generated (2026-10-06, shared with Jim out-of-band for Vault
install): **64-hex-char value, never committed to any repo.**

## Install (Azure Key Vault + Container App env refs)

The source of truth is `twaisecretskv` (Mason: this is the same
Vault twai-api already reads `sk_test` + Qwen3 ref-audio IDs from).
Both services' Container Apps read `secretRef`s that point at it.

### Step 1 — Vault

```bash
az keyvault secret set \
  --vault-name twaisecretskv \
  --name gen-2wai-internal-service-bearer \
  --value "<64-hex-char bearer from the step above>"
```

### Step 2 — twai-api Container App

Confirm the secretRef, then env mapping:

```bash
# Create (or re-point) the secret ref on the Container App resource.
az containerapp secret set \
  --name twai-api \
  --resource-group <rg> \
  --secrets "twai-gen-service-bearer=keyvaultref:https://twaisecretskv.vault.azure.net/secrets/gen-2wai-internal-service-bearer,identityref:system"

# Point the env var at it (preserves other env; use the --set-env-vars
# convention Mason already uses for TWAI_* vars).
az containerapp update \
  --name twai-api \
  --resource-group <rg> \
  --set-env-vars TWAI_GEN_SERVICE_BEARER=secretref:twai-gen-service-bearer
```

### Step 3 — gen-2wai Container App

```bash
az containerapp secret set \
  --name gen-2wai \
  --resource-group <rg> \
  --secrets "gen-internal-service-bearer=keyvaultref:https://twaisecretskv.vault.azure.net/secrets/gen-2wai-internal-service-bearer,identityref:system"

az containerapp update \
  --name gen-2wai \
  --resource-group <rg> \
  --set-env-vars GEN_INTERNAL_SERVICE_BEARER=secretref:gen-internal-service-bearer
```

### Step 4 — gen-2wai also needs the base URL on the twai-api side

The gateway needs to know where to send the bridge call. In
staging/prod this is the gen-2wai public hostname (`2wai.ai` or the
staging equivalent). Example:

```bash
az containerapp update \
  --name twai-api \
  --resource-group <rg> \
  --set-env-vars TWAI_GEN_BASE_URL=https://2wai.ai
```

The gateway's `settings.gen_bridge_enabled` is a property that
returns `True` only when `gen_base_url` is non-empty AND
`gen_service_bearer` is non-empty, so until step 2 + step 4 are
both done, the gateway's require_sk falls back to its old
behavior (local lookup only, 401 on dev-portal keys) and
`GET /v1/avatars` returns 503 `catalog_hydrate_not_configured`.
This is the same shape every other Vault-rotated secret follows.

## Rotation

Repeat Step 1 with a fresh value, then push a new revision of both
Container Apps (az containerapp revision copy). The two apps swap in
tight sequence so the old bearer stays valid on the twai-api side
until the new one is live on gen-2wai; after a few seconds, flip
twai-api. 60s cache on the twai-api side means the window of mixed
state eats at most one request burst per client.

## Non-prod

Local dev + CI run both services without the bearer at all:
`TWAI_GEN_BASE_URL` unset → gateway's bridge is disabled → `getAvatar`
can't resolve catalog but every other route works. In the gateway's
test suite the bridge is mocked via `respx`; gen-2wai's tests set
`GEN_INTERNAL_SERVICE_BEARER` through `monkeypatch.setenv` per test.

## Why one shared bytes, not a per-call JWT

A JWT would let twai-api prove its identity cryptographically, but
the two services sit inside the same Container Apps tenancy, same
network, and both already read the same Vault. The shared-bearer
pattern is what every other sibling-service call in this stack
already uses (`candy_eval_demo` admin pings, Studio → broker, etc.);
dropping a JWT library in just for this one hop would be out of
proportion.
