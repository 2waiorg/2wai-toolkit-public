# twai_api_starter — run commands

Adapter 4 (twai-api via mint proxy) · echo-mode starter template · web + Android + iOS.

## Server (once, leave running)

```powershell
cd apps\mint_proxy_examples\node
$env:SK_KEY = "sk_test_..."
node server.js
```

## Frontend

```powershell
cd apps\twai_api_starter
```

**Web:**
```powershell
flutter run -d chrome --web-port 5174
```

**Android** (`<phone>` = `adb devices` output, `<lan-ip>` = `ipconfig | Select-String IPv4`):
```powershell
flutter run -d <phone> --dart-define=MINT_PROXY_URL=http://<lan-ip>:8787
```

**iOS** (from Mac):
```bash
flutter run -d <iphone> --dart-define=MINT_PROXY_URL=http://<lan-ip>:8787
```
