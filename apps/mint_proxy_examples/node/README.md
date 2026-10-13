# Node / Express mint proxy

Requires Node 18+ (for native `fetch`).

## Run

```
npm install
SK_KEY=sk_test_... node server.js
```

Then point the Flutter SDK at `http://localhost:8787`:

```dart
final rest = TwaiApiRestClient(
  baseUrl: Uri.parse('http://localhost:8787'),
  credentials: const AnonymousCredentials(),
);
```

## Env

| Var              | Default                                                          |
| ---------------- | ---------------------------------------------------------------- |
| `SK_KEY`         | (required)                                                       |
| `UPSTREAM`       | staging twai-api URL                                             |
| `ALLOWED_ORIGIN` | `*` (tighten in prod)                                            |
| `PORT`           | `8787`                                                           |
| `GEN_UPSTREAM`   | `https://2wai.ai` — target for the dev `/v1/avatars` handler     |
| `GEN_BEARER`     | (optional) session bearer gen-2wai accepts for private avatars   |

## Catalog hydrate (`GET /v1/avatars/{owner}/{name}`)

The handler in `server.js` is the **dev-only reference** for the
catalog-hydrate route. It talks directly to gen-2wai's
`/api/gen/avatar-page/{owner}/{name}` and translates the response
into the shape `TwaiApiRestClient.getAvatar()` consumes:

```
AvatarPage                            TwaiApiAvatar
──────────                            ─────────────
rid                     →             avatar_id
avatarname              →             name
name                    →             display_name
owner                   →             owner
listed                  →             listed
idleUrl                 →             idle_url (nullable)
posterUrl               →             poster_url (nullable)
greeting.{video_url,
          text}         →             greeting.{video_url, text,
                                                id, kind} + null
                                                consumption_key
description, topics,
likeCount, likedByMe,
shareUrl, publicName,
house, ownerDisplay     →             dropped (not toolkit concern)
```

**Not for production.** The twai-api gateway (`c:/Dev/twai-api`) is
the real home for this route. The handler here is a blueprint for
that port + a smoke-test target for the SDK while the gateway PR is
in flight. Once the gateway ships `GET /v1/avatars/{owner}/{name}`,
delete this handler and forward the route the same way the session
routes are forwarded.

Full design + rationale: `docs/catalog_hydrate_plan.md` +
`docs/catalog_hydrate_prior_art_analysis.md` in the toolkit repo.

## Deploy

Any Node hoster works. For customer apps already running Express:
mount the routes from `server.js` onto your existing app under a
prefix like `/twai`; the SDK's `TwaiApiRestClient` supports prefixed
base URLs via `baseUrl: Uri.parse('https://yourapp.com/twai')`.
