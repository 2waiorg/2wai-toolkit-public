# embed — run commands

Adapter 1 (via Web Component) · `<twai-avatar>` / `<twai-chat>` drop-in tags for non-Flutter web sites · web only.

**No server needed.**

## Frontend (web only)

```powershell
cd apps\embed
flutter run -d chrome --web-port 5179
```

## For a customer HTML site

Build the bundle once, drop into their page:

```powershell
cd apps\embed
flutter build web
# → build\web\ — copy contents to customer's static hosting
```

Then in customer HTML:

```html
<script type="module" src="/twai-embed/main.dart.js"></script>
<twai-avatar avatar-slug="jesus"></twai-avatar>
```
