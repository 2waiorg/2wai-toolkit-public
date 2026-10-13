# candy_demo — run commands

Adapter 4 (twai-api via mint proxy) · **internal SDK load-test** — Mila + Python mock brain. For the customer-facing Candy pitch, use [`apps/candy_demo_external`](../candy_demo_external/).

Two servers needed: mint proxy + Python mock brain.

## Server 1 — mint proxy (once, leave running)

```powershell
cd apps\mint_proxy_examples\node
$env:SK_KEY = "sk_test_..."
node server.js
```

## Server 2 — mock Candy brain (once, leave running)

```powershell
cd apps\candy_demo
python mock_candy_brain.py
```

## Frontend

```powershell
cd apps\candy_demo
```

**Web:**
```powershell
flutter run -d chrome --web-port 5170
```

**Android** (mostly untested; internal artifact):
```powershell
flutter run -d <phone> --dart-define=MINT_PROXY_URL=http://<lan-ip>:8787
```

**iOS** (mostly untested; internal artifact):
```bash
flutter run -d <iphone> --dart-define=MINT_PROXY_URL=http://<lan-ip>:8787
```
