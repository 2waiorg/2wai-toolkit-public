# openapi/proposed/ — spec addenda for endpoints not yet on the live gateway

Standalone OpenAPI fragments for API surfaces that are proposed but not yet shipped by Mason's gateway (`api.2wai.ai/v1/*`). Each file is a self-contained OpenAPI 3.1 document — `openapi-to-postmanv2` can generate a Postman collection from any of them.

## Contents

| File | Status | Roadmap item | Notes |
|---|---|---|---|
| `documents-api.yaml` | **Proposed** — spec-first design, not yet live | 3.10 (brain content ingestion) + 3.11 (tagging) | Wraps the brain's existing `POST /document/upsert` (avatar-brain repo). Parameterized source: file upload OR URL / RSS / Notion / future connectors. |

## Promotion rules

An endpoint moves from `openapi/proposed/` to the main `openapi/openapi.yaml` when Mason's gateway serves it in production. The refresh recipe in `openapi/README.md` will pull the new operations in automatically — at which point, delete the proposed file (or leave a redirect stub if we want to track the spec-first history).

## Why keep proposed specs at all

- **Design-first surface for review.** Alex / Mason / Jim can eyeball the wire before anyone writes handler code.
- **Generates a working Postman collection.** Consumers can mock against it (Postman → collection → "Mock server") before the real endpoints exist — useful for SDK-side prototyping.
- **Codifies the parameterization decisions** (like the discriminated union on `source.type` for documents) so those don't get lost in Slack.
