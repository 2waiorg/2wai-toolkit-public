# Cloudflare Worker mint proxy

Zero-infra, edge-deployed. ~5ms cold start.

## Deploy

```
npm install -g wrangler
wrangler login
wrangler secret put SK_KEY   # paste sk_test_... at the prompt
wrangler deploy
```

Wrangler prints a URL like `https://twai-mint-proxy.<you>.workers.dev`.
Point the Flutter SDK at it:

```dart
final rest = TwaiApiRestClient(
  baseUrl: Uri.parse('https://twai-mint-proxy.your.workers.dev'),
  credentials: const AnonymousCredentials(),
);
```

## Configure per environment

Edit `wrangler.toml` (or use `wrangler deploy --var ALLOWED_ORIGIN=...`)
to lock down the CORS origin:

```toml
[env.production.vars]
ALLOWED_ORIGIN = "https://myapp.com"
```

Then `wrangler deploy --env production`.

## Custom domain

If you want the SDK to point at `https://myapp.com/twai` instead of
the workers.dev subdomain, add a route in the Cloudflare dashboard:
Workers & Pages → your worker → Triggers → Add Custom Domain →
`myapp.com/twai/*`. The SDK's `TwaiApiRestClient` will preserve the
`/twai` prefix through all four endpoint calls.
