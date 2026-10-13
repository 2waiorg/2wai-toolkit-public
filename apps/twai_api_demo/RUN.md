# twai_api_demo — run commands

Adapter 4 · **raw wire, no SDK** — hand-rolled REST + WebSocket in Dart. Teaching artifact showing what the SDK abstracts. Web + native but web is primary.

## Server (once, leave running)

```powershell
cd apps\mint_proxy_examples\node
$env:SK_KEY = "sk_test_..."
node server.js
```

## Frontend

```powershell
cd apps\twai_api_demo
```

**Web:**
```powershell
flutter run -d chrome --web-port 5173
```

**Android:**
```powershell
flutter run -d <phone> --dart-define=MINT_PROXY_URL=http://<lan-ip>:8787
```

**iOS** (from Mac):
```bash
flutter run -d <iphone> --dart-define=MINT_PROXY_URL=http://<lan-ip>:8787
```
