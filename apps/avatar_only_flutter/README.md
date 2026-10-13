# candy_demo — Flutter twin of `apimila-demo`

Transport 0 (LiveKit) via twai-api `/v1/*` + mint-proxy + BYO-brain callback + Mila. Flutter equivalent of [`c:\Dev\apimila-demo`](../../../../apimila-demo/) (Mason's Python + vanilla-JS customer-server reference), ~10 lines of Dart replacing ~150 lines of hand-rolled JS. Includes push-to-talk mic via `TwaiMicButton` + `DefaultTranscriber`.

> **INTERNAL VALIDATION artifact for the SDK — NOT a customer pitch tool.**
>
> Per the 2026-07-28 Jim/Mason conversation: Mason is (rightly) not going to backstop Flutter-side bugs. This app exists so we can stress-test the SDK against Mila continuously without asking for his ops attention. Every fix that lands here is proof the SDK holds up under real load; only if it does over months do we revisit whether this belongs in a customer conversation.
>
> **For the customer-facing Candy.ai pitch, use [`apps/candy_demo_external`](../candy_demo_external/) instead** — Next.js (matches Candy's actual stack), Mila-branded, ~200 LOC of pitch-ready client. This Flutter version stays internal.

## Shape

```
Browser (candy_demo Flutter web)
    │
    ├──── /v1/sessions, /speak, /interrupt, DELETE ────► mint proxy ──► twai-api gateway ──► Mila
    │                                                    (holds sk_)
    │
    └──── POST /reply {text} ─────► mock_candy_brain (stand-in for Candy's LLM)
```

Wire is identical to `apimila-demo`. Only differences: the customer client is Flutter (not vanilla JS), and the brain lives as a swappable HTTP endpoint (so the SDK's `brain:` callback is what a real Candy integration replaces).

## Run

Three shells.

### 1. Mint proxy

Any of the three references in `apps/mint_proxy_examples/`. Node default:

```powershell
cd apps\mint_proxy_examples\node
npm install     # first time only
$env:SK_KEY = "sk_..."     # Mila's sk_ from staging
node server.js
# → [mint-proxy] listening on http://localhost:8787
```

### 2. Mock Candy brain

```powershell
python apps\candy_demo\mock_candy_brain\server.py
# → [candy-brain] listening on http://127.0.0.1:9090/reply
```

Zero deps, stdlib only. Returns canned in-character Mila replies keyed off simple text matching. In a real Candy integration this file gets replaced by Candy's own LLM service; the SDK doesn't change.

### 3. Flutter app

```powershell
Copy-Item apps\candy_demo\.env.example apps\candy_demo\.env
cd apps\candy_demo
flutter run -d web-server --web-port 5175 --dart-define-from-file=.env
```

Open the URL flutter-web prints (default `http://localhost:5175`) in Chrome.

## Success signals

- App bar shows `proxy: localhost:8787 · brain: localhost:9090`.
- Status dot goes amber (connecting) → green (ready) within a couple seconds.
- Mila's idle plate appears in the 9:16 pane.
- Send "hello" → user bubble appears in the log, then Mila speaks a reply (canned by the brain), status dot goes pink while she's talking.
- Mint proxy shell prints `POST /v1/sessions 201`, `POST /v1/sessions/{sid}/speak 200`.
- Brain shell prints `POST /reply 200`.

## What this proves

- **The T0 wire works end-to-end** through the Flutter SDK against Mason's live gateway.
- **The brain-callback split works** — customer's own model plugs in via `/v1/sessions/:sid/speak` without touching SDK code.
- **The mint-proxy pattern works** — the browser never sees `sk_`; only short-lived LiveKit tokens.
- **Player behavior holds up** on real Mila — engine lifecycle, reconnect classification, speaking-event gating — every mechanism the [conformance test](../../packages/twai_avatar_sdk_livekit/test/livekit_conformance_test.dart) asserts against the shared vectors (7 files, 123 scenarios).

## What this DOES NOT prove yet

- Long-session stability (24h+ uptime, memory growth).
- Non-web platforms — this is a web smoke-test today. iOS / Android / Windows runs are the next stress tests.
- Cap-fill (429), interrupt mid-speech, mid-session outfit switch — none exercised here.
- BYO-TTS via `POST /v1/sessions/{sid}/audio` — that endpoint isn't wired on `TwaiApiRestClient` yet (deferred until a real customer asks).

## Related

- [`c:\Dev\apimila-demo`](../../../../apimila-demo/) — Mason's Python + vanilla-JS reference; this app is the Flutter twin.
- [`wiki/avatar-sdk/how-to/twai-api-integration-reference.md`](../../../../PubDev/2waiwiki/aws-infra/wiki/avatar-sdk/how-to/twai-api-integration-reference.md) — the canonical customer walkthrough.
- [`wiki/avatar-sdk/how-to/flutter-twai-api-quickstart.md`](../../../../PubDev/2waiwiki/aws-infra/wiki/avatar-sdk/how-to/flutter-twai-api-quickstart.md) — the Flutter-side quickstart.
- The pre-Adapter-4 Web Component pitch mock (formerly `apps/candy_demo_legacy/`) was pruned 2026-08-03. Retrievable via git tag `pre-candy-legacy-prune` if needed for archival reference.
