# Flutter consumer integration — gotchas

For teams **adding the toolkit SDK to an existing Flutter app** (as opposed to forking one of the `apps/` references). Covers the four traps that have cost real time in the field.

Companion to [`docs/2wai_toolkit_integration.md`](../c-dev-lumara/docs/2wai_toolkit_integration.md) (Lumara's version) and the reference apps in [`apps/`](../apps/). If you're forking one of the reference apps whole-cloth, most of these don't apply — the traps are consumer-side integration friction, not SDK bugs.

## 1. Run `flutter clean` after adding the SDK deps

**Symptom:** you've added `twai_avatar_sdk_video_player` (and/or the other SDK packages) to `pubspec.yaml`, run `flutter pub get`, and started your app. The idle pane renders as a **black rectangle with no error in the browser console**. The idle video URL request never fires. Speaking video (if you get that far) also silently fails to render.

**Cause:** Flutter's incremental build cache reuses a stale `web_plugin_registrant.dart` (and analogous native-side registrants) from before you added the SDK deps. The registrant enumerates plugins to register with the Flutter engine at startup; if it was generated before `video_player_web` (transitively pulled by `twai_avatar_sdk_video_player`) was in the graph, that plugin never registers. Every `VideoPlayerController.initialize()` call then throws `MissingPluginException("No implementation found")` — the SDK's idle logic catches that and degrades to a transparent placeholder, so you see nothing but the sink's default black.

**Fix (one command):**

```powershell
flutter clean && flutter pub get
```

Then rebuild. The registrant regenerates with all currently-listed plugins.

**Diagnosis if you're not sure:**

Grep the generated registrant. On web:

```powershell
grep VideoPlayerPlugin .dart_tool/flutter_build/*/web_plugin_registrant.dart
```

If the grep returns nothing, the cache is stale. If it returns a `VideoPlayerPlugin.registerWith(registrar)` line, the cache is current and the problem is somewhere else.

**Since SDK 2026-08-08:** [`avatar_idle_source.dart`](../packages/twai_avatar_sdk/lib/src/avatar_idle_source.dart) `_LoopingVideoIdle._init()` now detects the `MissingPluginException` shape and emits a distinctive `FlutterError.reportError` message pointing at this exact remedy. If you see that error in your Flutter console, run the fix above.

## 2. Mint proxy routes MUST be under a `/v1/` prefix

**Symptom:** your backend has route handlers at `POST /twai/sessions`, `POST /twai/sessions/:sid/speak`, etc. (following the shape from an old pre-solved integration doc). The Flutter client's `TwaiPlayerHandle.forApiSession(restClient: ...)` fails to mint a session — you see a 404 in your backend logs on requests to `POST /twai/v1/sessions`.

**Cause:** `TwaiApiRestClient` always resolves paths as `baseUrl.resolve('v1/sessions')` internally. It always adds the `v1/` segment. If you set your `baseUrl` to `.../api/twai` and your route handlers are at `.../api/twai/sessions`, the client hits `.../api/twai/v1/sessions` → 404.

**Fix:** match the reference proxy at [`apps/mint_proxy_examples/node/server.js`](../apps/mint_proxy_examples/node/server.js) — routes are `POST /v1/sessions`, `POST /v1/sessions/:sid/speak`, `POST /v1/sessions/:sid/interrupt`, `DELETE /v1/sessions/:sid`. When you mount those routes under your app's namespace, the SDK's `baseUrl` must point at the parent of `v1/`, not at `v1/` itself.

Example (Express):

```javascript
// Correct — routes register with /v1/ prefix
router.post('/v1/sessions', ...);
router.post('/v1/sessions/:sid/speak', ...);
// Mounted under whatever namespace fits your app:
app.use('/api/twai', router);
// Client-side: baseUrl = 'https://your-app/api/twai'
// SDK resolves 'v1/sessions' against that → hits '/api/twai/v1/sessions' ✓
```

## 3. Match the reference verbatim BEFORE embellishing

**Symptom:** you copied the widget tree from one of the reference apps but added your own layout chrome (`ClipRRect`, `IntrinsicHeight`, custom `Padding`, etc.). Idle doesn't render. You try to debug it. Nothing works.

**Cause:** the reference widget tree is load-bearing. Comments in [`apps/enlighten/lib/main.dart`](../apps/enlighten/lib/main.dart) around the `TwaiPlayer` call out the specific pattern:

```dart
Expanded(
  child: ColoredBox(
    color: Colors.black,               // ← diagnostic: 0-sized bug shows as black flash
    child: Center(                     // ← required so AspectRatio gets a bounded axis
      child: AspectRatio(
        aspectRatio: 9 / 16,           // ← without this, TwaiPlayer can render at 0×0
        child: TwaiPlayer(avatar: _drAlman, controller: _handle),
      ),
    ),
  ),
),
```

Common embellishment failures:

- **`ClipRRect(borderRadius: ...)`** wrapping the `AspectRatio` — usually fine, but on web it forces Flutter to composite the platform view through a `RepaintBoundary` that can drop frames or reveal the underlying black.
- **`IntrinsicHeight` ancestor** — collapses `Expanded` to 0 during the intrinsic-size measurement pass. The `TwaiPlayer` renders at 0×0. Symptom identical to "idle not showing." Fix: replace `IntrinsicHeight` with `SizedBox(height: X)` for the row/column of children.
- **Skipping the `Center` wrapper** — `AspectRatio` inside an `Expanded` without `Center` can compute a 0-sized axis if the parent doesn't give it a bounded main-axis constraint. `Center` guarantees the axis constraint.
- **Passing your own `idleSource:` prop to `TwaiPlayer`** — overrides the outfit's `idleUrl` entirely. If your custom `AvatarIdleSource` doesn't render (empty asset, wrong URL, subtle subclass bug), you get the transparent-placeholder degradation. Only pass `idleSource:` when you explicitly want to override the outfit's default.

**Discipline:** stand up a scratch route that renders **only** `TwaiPlayer(avatar: yourAvatar)` verbatim from the reference. Confirm it works. Then embed into your production layout, adding chrome one wrapper at a time and re-testing.

## 4. iOS build vs web build — no shared plugin registrant

The plugin registrant is per-platform. `flutter clean` handles all of them at once. But if you tested web, added the SDK to a project that had never built for iOS, and then run `flutter build ios`, the iOS registrant may be missing `video_player_avfoundation` from a stale iOS-only cache. Same trap, different platform. Same fix.

Any time you add or remove SDK deps and switch platforms, `flutter clean` first.

---

## Complete first-integration checklist (copy this into your PR)

Adding the toolkit SDK to an existing Flutter app:

1. Add these to `pubspec.yaml` `dependencies:`
   ```yaml
   twai_avatar_sdk:
   twai_avatar_sdk_video_player:
   twai_avatar_sdk_web_mse:
   http: ^1.2.0
   ```
2. Run `flutter clean && flutter pub get` — required, not optional
3. Add mint proxy routes to your backend at `/v1/sessions*`, `/v1/sessions/:sid/speak`, `/v1/sessions/:sid/interrupt`, `DELETE /v1/sessions/:sid` — routes MUST include the `/v1/` prefix
4. Stand up a scratch route rendering **only** `TwaiPlayer(avatar: yourAvatar)` — no `AspectRatio`, no `Center`, no chrome. Confirm the idle plays.
5. Add the reference widget tree wrapping (`Expanded > ColoredBox(black) > Center > AspectRatio(9/16) > TwaiPlayer`) verbatim from `apps/enlighten/lib/main.dart`. Confirm the idle still plays.
6. Only then embed into your production layout, adding one wrapper at a time and testing between each.

## See also

- [`docs/2wai_toolkit_integration.md`](../c-dev-lumara/docs/2wai_toolkit_integration.md) (Lumara's version — most consumer-facing recipe)
- [`docs/mint_proxy_architecture.md`](mint_proxy_architecture.md) — the customer-vs-2wai deployment story for the mint proxy
- [`docs/flutter_app_call_flow.md`](flutter_app_call_flow.md) — end-to-end sequence diagrams
- [`apps/enlighten/lib/main.dart`](../apps/enlighten/lib/main.dart) — the reference app to lift from
