# avatar_player_lab — RUN

TwaiPlayer capability exerciser. Every SDK knob as a live control. Boot maxed-out, dial back to bisect.

Plan doc: [`docs/twai_player_capability_exerciser_plan.md`](../../docs/twai_player_capability_exerciser_plan.md).

## First-time setup

```powershell
cd c:/Dev/2wai-toolkit
flutter pub get     # workspace-level, resolves this app + all packages
```

## Web (Chrome) — public mode (default)

```powershell
cd c:/Dev/2wai-toolkit/apps/avatar_player_lab
flutter run -d chrome --web-port 5179
```

Boots on Sophi Summers (date outfit) via penthouse-staging Adapter 1. Adapter picker is the first tab in the right pane — 4 rows: Penthouse MSE-over-WS live, twai-api REST + WSS live, WebRTC coming-soon, On-device / Shape #3 coming-soon.

## Web — dev mode

Two ways:

```powershell
flutter run -d chrome --web-port 5179 --dart-define=DEV_MODE=1
```

Or with the app already running in public mode, append `?dev=1` to the URL. Or long-press the version chip (`v0.1`) in the top-left for 2 seconds — dev mode enables on release.

Dev mode surfaces the additional Phase-A/B panels (debug overlay, wire recorder, config sliders, wire inspector, sink override). Boot chrome remains identical; only extra tabs appear.

## Android

```powershell
flutter run -d 1A181JEG501702
```

(Pixel 5a per your setup.)

## Launch script — `run.ps1`

One file, all the wiring. Handles the key fetch (personal Key Vault → shared toolkit-demo fallback), verifies before launching, hands `--dart-define=TWAI_SK` to `flutter run`.

```powershell
cd C:\Dev\2wai-toolkit\apps\avatar_player_lab

.\run.ps1                  # web (Chrome), public mode
.\run.ps1 -Dev             # web, dev-mode panels unlocked
.\run.ps1 -Android         # Pixel 5a
.\run.ps1 -Android -Dev    # Pixel 5a, dev-mode
.\run.ps1 -Shared          # skip Key Vault, force shared key
```

### What it does

1. Reads `TWAI_SK` from the shell env (set it to your `sk_test_...` key before running). The launcher is wired for a secret-store swap — see `Get-PersonalKey` in `run.ps1` if you want to pull from your own vault.
2. Verifies the resolved key starts with `sk_` — bails with an error if not.
4. Prints the SOURCE (personal / shared) + key PREFIX (first 12 chars) so you see what got used.
5. `cd`s into the app dir (so you can launch from anywhere).
6. Runs `flutter run` with `--dart-define=TWAI_SK=<key>` + optionally `--dart-define=DEV_MODE=1`.

### Once Mason grants Key Vault access

Nothing to change on your end. Next `.\run.ps1` will see the personal key succeed + print `SOURCE: personal (Key Vault)` instead of the shared fallback. Zero script edits.

### Or bypass the script entirely

If you'd rather run flutter directly, both dart-defines are still there:

```powershell
flutter run -d chrome --web-port 5179 `
  --dart-define=TWAI_SK=sk_test_...  ` # your developer-portal key
  --dart-define=DEV_MODE=1
```

## What's live in P0

- Skeleton shell — left stage + right tabbed panel bar
- Adapter picker (leftmost tab) — 4 adapter rows + 5 seeded avatars
- Sophi Summers (default) — plays end-to-end via penthouse-staging
- Bella Vaunt — pipelines wired, should play
- Drew Scott — placeholder pipeline (TODO: verify with Mason before demo)
- Mila + Dr. Alman — visible in picker but transport wiring is P1 (twai-api credentials panel)
- P1 panel stubs — Construction, Credentials, Methods, Streams, Idle, Immersive — each shows what knobs it will host

## Coming in P1–P5

See the plan doc. P0 is the skeleton — panels are stubs with "KNOBS PLANNED" bullets, not live controls yet.

## Dev-mode long-press unlock

Hold the `v0.1` chip in the top-left header for 2 seconds. Dev mode enables silently and the chip turns yellow (`v0.1 · DEV`). No page reload needed. Useful during a customer demo if you need to flip into diagnostic mode without exiting the app.
