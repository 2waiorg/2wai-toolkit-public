# 2wai Avatar SDK — Product Overview

> A cross-platform Flutter SDK for embedding talking, lip-synced AI avatars into any consumer app. One codebase deploys to Android, iOS, Web, Windows, macOS, and Linux. Backend is 2wai's production avatar pipeline; SDK is the client surface. Also ships as a drop-in HTML Web Component for non-Flutter sites.

---

## What it is

The **2wai Avatar SDK** lets a Flutter app — or any web page — open a conversational session with any registered avatar: text or voice in, video + audio + reply text out, sub-2-second perceived latency on the streaming transport. The avatar lip-syncs to a generated voice clone, responds via a customizable LLM persona, and renders inside the host app's existing UI.

The reference avatar today is **Talk2Jesus** — a theologically-grounded Jesus persona validated end-to-end on Chrome, Android, Windows, and iOS (real iPhone + simulator); macOS untested. The SDK was exercised against the live staging backend with text + voice input + lip-synced video + speaker audio on each validated target.

**The same SDK, same configuration, runs Penthouse Pets' Sophi / Krystal / Bella / Tahlia personas in production.** The avatar id is the only thing that changes — transport, voice, lip-sync, and brain routing are all server-driven.

## What it isn't

- **Not a chat UI library.** The reference app shows what's possible; production apps bring their own UI design system. The SDK provides the transport + session lifecycle + video rendering primitives.
- **Not the avatar pipeline itself.** The Wav2Lip GAN, the Qwen3 voice cloning, the brain LLMs — those are 2wai's hosted infrastructure. The SDK is the client.
- **Not opinionated about persona, content, or monetization.** Subscriptions, gamification, paywalls, gestures, outfit transitions — all out of scope. The SDK gives you the conversational primitive; you build the product around it.

---

## Why this matters for entertainment

A modern conversational avatar is the convergence of five hard problems:

1. **Real-time lip-sync rendering** (Wav2Lip GAN on a dedicated GPU)
2. **Voice cloning fidelity** (Qwen3-Omni vLLM, ElevenLabs, or equivalent)
3. **LLM persona shaping** (per-avatar prompt + RAG + guardrails)
4. **Streaming media transport** with sub-2-second perceived latency
5. **Voice-input STT** — cross-platform mic capture + transcription with a pluggable backend

Each of those is independently a 6–12 month engineering investment. The SDK + platform delivers all five wrapped behind a single Dart API call (`session.sendMessage(text)`, transcripts auto-fill the input) — or, for non-Flutter sites, a single HTML tag: `<twai-avatar avatar-id="..." voice-id="...">` with `element.startListening()` exposed as JS.

Cross-platform reach matters because IP audiences live everywhere. Flutter compiles one codebase to:

| Platform | Video | Voice input | Status |
|---|---|---|---|
| Web (Chrome / Edge / Safari) | ✅ MSE live | ✅ browser SpeechRecognition | **Validated end-to-end** |
| Android | ✅ media_kit | ✅ speech_to_text | **Validated on Pixel 5 (Jesus + Sophi)** |
| Windows | ✅ media_kit | ✅ speech_to_text | **Validated** — MediaKit backend re-confirmed alongside Android (commit `da3e780`) |
| iOS | ✅ video_player + AVPlayer | ✅ speech_to_text | **Validated on iPhone 15 + iOS 26.5 simulator (2026-06-01)** — three known UX issues remain (see roadmap) |
| macOS | ⚙️ should work | ⚙️ speech_to_text supports | Untested; entitlements + Info.plist wired |
| Linux | ⚙️ media_kit works | ✗ no STT plugin | Mic button auto-hides where unavailable |

---

## High-level architecture

```
┌──────────────────────────────────────────────────────────────────┐
│       HOST APP (Flutter, customer's)  —or—  HOST PAGE (HTML)     │
│                                                                  │
│   final twai = TwaiClient(env: env, publishableKey: 'pk_...');   │
│   final session = twai.mseStreamSession(ttsSelection: 'tts5');   │
│   await session.connect(Avatar(id: 'jesus', voiceId: '...'));    │
│   sink.attach(session);  sink.buildWidget(); // → video pane     │
│                                                                  │
│   OR, in plain HTML:                                             │
│   <script src="embed.js" defer></script>                         │
│   <twai-avatar avatar-id="jesus" voice-id="..."                  │
│                api-key="pk_..." env="2wai-prod"></twai-avatar>   │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Public API (transport-agnostic)
                              │
┌──────────────────────────────────────────────────────────────────┐
│                  twai_avatar_sdk  (Flutter UI layer)             │
│   ────────────────────────────────────────────────────────────   │
│   • VideoSink (interface) + concrete sinks in sibling packages:  │
│       twai_avatar_sdk_video_player                               │
│         video_player + path_provider; web has MSE-live sink      │
│       twai_avatar_sdk_media_kit                                  │
│         libmpv; single binary across every native platform       │
│                                                                  │
│   • Transcriber (interface) + concrete impls:                    │
│       BrowserSpeechTranscriber  (web — direct dart:js_interop    │
│                                  wrap of SpeechRecognition)      │
│       SpeechToTextTranscriber   (native — speech_to_text plugin) │
│       DefaultTranscriber()      (conditional barrel picks the    │
│                                  right impl per build target)    │
│                                                                  │
│   Two pluggable video backends + a pluggable STT abstraction.    │
│   App picks sinks per-target; transcriber auto-resolves; both    │
│   accept customer-implemented backends (Qwen3 / Deepgram /       │
│   ElevenLabs Scribe / their own /stt-api/transcribe endpoint).   │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌──────────────────────────────────────────────────────────────────┐
│         twai_avatar_sdk_core  (pure Dart — no Flutter)           │
│                                                                  │
│   • TwaiClient: tenant identity entry point                      │
│       env + publishable/secret keys → scoped sessions + admin    │
│   • TwaiEnvironment: named dev/staging/prod profiles             │
│                                                                  │
│   • ChatSession: abstract chat lifecycle interface               │
│   • MseStreamChatSession ┐                                       │
│     ├── MseStreamClient  │ Adapter 1: penthouse MSE-over-WS      │
│     └── ChatGateway      ┘ (low latency, streaming fMP4)         │
│                                                                  │
│   • PipelineV13ChatSession ─ PipelineV13Client                   │
│       Adapter 2: simple POST /chat → complete MP4                │
│                                                                  │
│   • AvatarAdminClient: register / list / edit avatars            │
│                                                                  │
│   Pluggable. Add new transports without touching app code.       │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │  HTTPS / WSS  (Authorization: Bearer)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│                   2WAI AVATAR PIPELINE (hosted)                  │
│                                                                  │
│  ┌─────────────────┐  ┌────────────────┐  ┌─────────────────┐    │
│  │   main_service  │  │  inference_svc │  │   brain (LLM)   │    │
│  │  • routing      │  │  • Wav2Lip GAN │  │  • Anthropic    │    │
│  │  • avatar DB    │→ │  • muxer       │  │    Claude       │    │
│  │  • TTS/voice    │  │  • PyAV encode │  │  • OpenAI GPT   │    │
│  │    selection    │  │  • H.264 / AAC │  │  • Gemini       │    │
│  └─────────────────┘  └────────────────┘  └─────────────────┘    │
│                                                                  │
│  ┌─────────────────────┐  ┌──────────────────────────────────┐   │
│  │  Qwen3 voice clone  │  │   Asset storage (object store)   │   │
│  │  (labs-gpu-01 VM)   │  │  avatars/<id>/{latents, frames}  │   │
│  └─────────────────────┘  └──────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

The SDK is split into **three packages** for a reason. The pure-Dart core has zero Flutter dependency, which makes it usable from CLI tools, server-side Dart, or non-Flutter UI frameworks. The two Flutter UI layers — `twai_avatar_sdk_video_player` and `twai_avatar_sdk_media_kit` — are interchangeable video backends; an app picks one (or both) based on target platform and binary-size constraints. They both re-export the core for one-stop import.

---

## Layered model

| Layer | Responsibility | Concrete types |
|---|---|---|
| **Identity** | One handle to the tenant's env + keys; produces scoped sessions and admin | `TwaiClient`, `TwaiEnvironment` |
| **Transport** | Open the wire to the backend; send chat; receive bytes | `MseStreamClient` (WS), `ChatGateway` (POST), `PipelineV13Client` (POST) |
| **Session** | Compose transport into a lifecycle (connect → send → close); expose typed streams | `MseStreamChatSession`, `PipelineV13ChatSession` (both implement `ChatSession`) |
| **Video sink** | Render `videoBytes` stream into a Flutter widget | `VideoPlayerMseStreamSink`, `VideoPlayerMseLiveSink`, `VideoPlayerPipelineV13Sink`, `MediaKitMseStreamSink`, `MediaKitPipelineV13Sink` (all implement `VideoSink`) |
| **Voice input (STT)** | Capture mic, emit transcripts as the user speaks | `BrowserSpeechTranscriber` (web), `SpeechToTextTranscriber` (native), `DefaultTranscriber()` (factory), customer-implemented backends (Qwen3 / Deepgram / etc) — all implement `Transcriber` |

App code touches Identity + Session + Sink + (optional) Transcriber, and never touches transport directly. Adding a new backend (e.g. WebRTC, gRPC, MQTT) means writing one new Transport + one new Session and the app picks it up by changing one constructor call. Adding a new STT backend means implementing one `Transcriber` and passing it where `DefaultTranscriber()` would otherwise be used.

---

## Transport adapters

Two transports are shipped today. A third is sketched as a future option.

### Adapter 1 — Penthouse MSE-over-WS *(production, validated)*

**Used by:** Penthouse Pets (Sophi, Krystal, Bella Reid, Bella Vaunt, Tahlia, etc.) **and** Talk2Jesus (RedJesusTalk1–4)

**Wire:**
- `POST /ext-api/human` — send user text → returns LLM reply text immediately
- `WS /ext-api/mse_stream` — open WS at session start; server pushes fragmented MP4 frames (`moof`+`mdat`) and JSON `speaking start/stop` events with playback timestamps

**Why MSE-over-WS:** ~1–2 second perceived latency on the web MSE-live sink. The avatar starts speaking before the reply is fully rendered, because video fragments stream in alongside generation. This is the same technique YouTube/Netflix use for adaptive bitrate streaming, applied to a generated avatar.

**Codec contract:** H.264 Constrained Baseline 3.1, 720×1280 portrait, 25 fps, AAC-LC 16 kHz mono. Documented in [`protocol.md`](protocol.md).

### Adapter 2 — Pipeline v1.3 `POST /chat` → MP4 *(simple, unit-tested)*

**Used by:** Any backend that prefers request/response over streaming. Trade ~5–9 second latency for a much simpler server implementation.

**Wire:**
- `POST /chat` with `{message, history?}` — returns a complete MP4 body + reply text in `X-Response-Text` header

**Why include it:** Some customers will host their own simpler pipeline. The same SDK + same `ChatSession` interface works against either. App code that uses `ChatSession session` doesn't care which transport is underneath.

### Adapter 3 — WebRTC *(interface preserved, not built)*

WebRTC SDP offer/answer dance against `/blade-virtual/ai/call/getAiOffer` — what `2wai.ai/jesus` runs in production via the Nuxt frontend. The `ChatSession` interface accommodates this transport; implementation deferred until a specific customer asks for it.

---

## End-to-end chat flow (Adapter 1)

```
APP                          SDK                          BACKEND
 │                            │                            │
 │  twai = TwaiClient(...)    │                            │
 │  session =                 │                            │
 │   twai.mseStreamSession(.) │                            │
 │  session.connect(avatar)   │                            │
 │  ─────────────────────────▶│                            │
 │                            │  WS handshake              │
 │                            │  ?key=pk_live_xxx          │
 │                            │ ─────────────────────────▶ │
 │                            │  session_id, avatar_id,    │
 │                            │  voiceId, tts              │
 │                            │ ◀───────────── fMP4 init   │
 │                            │ ◀───────────── idle frames │
 │                            │   (continuous, ~2KB/sec)   │
 │                            │                            │
 │  user types "hi"           │                            │
 │  session.sendMessage("hi") │                            │
 │  ─────────────────────────▶│  POST /ext-api/human       │
 │                            │  Authorization: Bearer pk_ │
 │                            │ ─────────────────────────▶ │
 │                            │ ◀──── {res: "Hello..."}    │
 │  ◀── replyText: "Hello..." │                            │
 │                            │                            │
 │                            │ ◀──── speaking start@1.2s  │
 │  ◀── speakingEvents        │                            │
 │                            │                            │
 │                            │ ◀──── speech fMP4 chunks   │
 │  ◀── videoBytes (stream)   │                            │
 │                            │                            │
 │  → VideoSink.attach()      │                            │
 │  → MSE SourceBuffer appends fragments in real time     │
 │                            │                            │
 │                            │ ◀──── speaking stop@8.7s   │
 │  ◀── speakingEvents        │                            │
 │                            │ ◀──── idle frames resume   │
 │                            │                            │
 │  user types another...     │                            │
 │  (repeats steps 5–13)      │                            │
 │                            │                            │
 │  app shuts down            │                            │
 │  session.close()           │  WS close (code 1000)      │
 │  twai.close()              │                            │
 │  ─────────────────────────▶│ ─────────────────────────▶ │
```

**Key latency characteristics:**

| Event | Time from `sendMessage()` | Source |
|---|---|---|
| Reply text in app | ~1–3s | LLM generation (Anthropic Claude or equivalent) |
| First speech frame on screen (MSE-live sink) | ~1–2s | First fMP4 fragment + decoder warmup |
| First speech frame on screen (buffered sink) | ~5–9s | Accumulate until speaking:stop + 2s tail window |
| Speech complete | text length × ~12 char/sec | TTS speaking rate |
| Idle resumes | immediate | server continuously emits idle loop |

Replies that arrive while a previous turn is still playing are **queued and played in order** — no skipped or cut-off turns under rapid input.

---

## Public API surface

The SDK is intentionally minimal. Four classes do almost everything an app needs.

### `TwaiClient`

The single entry point. One client per tenant; everything else flows from it.

```dart
final twai = TwaiClient(
  env: TwaiEnvironment.named('2wai-prod'),
  publishableKey: 'pk_live_xxx',  // chat-scope, safe in browser HTML
  secretKey: 'sk_live_xxx',       // admin-scope, server-side only
);

// Scoped session — env + publishable key already wired in.
final session = twai.mseStreamSession(ttsSelection: 'tts5');

// Scoped admin client — throws if secretKey was null.
final admin = twai.admin(developerMode: true);

twai.close();  // releases the shared http.Client when fully done
```

Server-side integrations that proxy multiple customers hold N `TwaiClient`s — one per tenant identity. The client is long-lived configuration; sessions are short-lived.

### `TwaiEnvironment`

Named backend profiles with `--dart-define` and `.env`-file support.

```dart
final env = TwaiEnvironment.named('2wai-prod');
// Customers self-host? Register their own env once at app boot:
TwaiEnvironment.register(TwaiEnvironment(
  name: 'acme-prod',
  baseUrl: Uri.parse('https://avatars.acme.example'),
));
```

Builtins: `local-dev`, `2wai-staging`, `2wai-prod`.

### `Avatar`

```dart
class Avatar {
  final String id;        // 'RedJesusTalk1', 'SophieSummersCasual2', etc.
  final String? voiceId;  // Qwen3 voice clone UUID (optional override)
  const Avatar({required this.id, this.voiceId});
}
```

### `ChatSession` (abstract)

```dart
abstract class ChatSession {
  Future<void> connect(Avatar avatar);

  // Optional brain-context kwargs (penthouse Patch #70 r14) — Adapter 1
  // forwards them in the POST /ext-api/human body; Adapter 2 ignores
  // them (server doesn't accept). Both default to omitted/safe.
  Future<void> sendMessage(
    String text, {
    num? gamificationLevel,   // → brain Trust Stage mapping
    Object? avatarStateBlock, // → brain opaque mood/pose context
  });

  Stream<String> get replyText;             // 1 emit per turn
  Stream<SpeakingEvent> get speakingEvents; // start/stop + pts
  Stream<Uint8List> get videoBytes;         // fragmented MP4 or full MP4

  Future<ChatSessionEndReason> get done;
  Future<void> close();
}

// Adapter-1-only extras on MseStreamChatSession (not on the abstract):
abstract class MseStreamChatSession implements ChatSession {
  // Brain-inferred mood, sourced from X-Mood + X-Mood-Humanized response
  // headers on /human (penthouse Patches #62 r14, echoed from the brain's
  // SSE "event: mood" frame — avatar-brain/src/core/mood/).
  //
  // Emits zero-or-one MoodEvent per sendMessage turn; absent/empty
  // headers filtered out. MoodEvent carries:
  //   - .mood        — typed Mood enum (9 slugs + .unknown for forward-compat)
  //   - .slug        — raw wire slug (preserved when .mood is Mood.unknown)
  //   - .humanized   — per-avatar tooltip ("Sophi is feeling good") or null
  Stream<MoodEvent> get moodEvents;
}

// The mood vocabulary (closed across all avatars per Alex's roster).
// Mood.unknown is the forward-compat slot — when the brain ships a new
// slug, MoodEvent.slug preserves it.
enum Mood {
  warmCurious, dryTeasing, hyped, frisky,
  softQuiet, offHerGame, homesick,
  afterglow,   // post-roleplay transient
  mad,         // user-triggered (sustained cruelty / coldness; sticky)
  unknown,
}
```

Concrete implementations are produced by `TwaiClient`:

```dart
final session = twai.mseStreamSession(ttsSelection: 'tts5');  // Adapter 1
final session = twai.pipelineV13Session();                    // Adapter 2
```

**Rest of the app code is identical** regardless of adapter — same `connect`, `sendMessage`, `replyText`, `videoBytes`. The transport-agnostic abstraction is the SDK's main differentiator.

### `VideoSink`

```dart
abstract class VideoSink {
  Future<void> attach(ChatSession session);
  Widget buildWidget();           // returns a Flutter widget
  Future<void> dispose();
}
```

Concrete sinks across the two backend packages:

| Sink | Backend | Adapter | Notes |
|---|---|---|---|
| `VideoPlayerMseStreamSink` | `video_player` | 1 | Buffered, all platforms (incl. web via Blob URL) |
| `VideoPlayerMseLiveSink` | `video_player` + raw `<video>` + MSE | 1 | **True streaming, ~1–2s first frame. Web only.** |
| `VideoPlayerPipelineV13Sink` | `video_player` | 2 | Plays one MP4 per turn |
| `MediaKitMseStreamSink` | `media_kit` (libmpv) | 1 | Buffered, native targets |
| `MediaKitPipelineV13Sink` | `media_kit` (libmpv) | 2 | Plays one MP4 per turn, native |

Usage:

```dart
final sink = kIsWeb
  ? VideoPlayerMseLiveSink()      // streaming MSE on web
  : MediaKitMseStreamSink();      // libmpv on native
await sink.attach(session);

// In your widget tree:
SizedBox(height: 480, child: sink.buildWidget())
```

### `Transcriber`

```dart
abstract class Transcriber {
  Future<bool> initialize();                      // capability probe
  bool get isAvailable;
  Future<void> start();                           // tap-to-toggle UX
  Future<void> stop();
  Future<void> cancel();
  Stream<TranscriptEvent> get transcripts;        // {text, isFinal}
  Stream<TranscriberError> get errors;
  Future<void> dispose();
}
```

Concrete implementations:

| Transcriber | Where it runs | What it wraps |
|---|---|---|
| `BrowserSpeechTranscriber` | Web (Chrome / Edge / Safari) | `dart:js_interop` direct wrap of `SpeechRecognition` — no plugin, no key, no setup |
| `SpeechToTextTranscriber` | Android / iOS / macOS / Windows | `speech_to_text` plugin against platform-native STT (Android `SpeechRecognizer`, iOS / macOS `Speech` framework) |
| `DefaultTranscriber()` | All targets | Conditional barrel — resolves to BrowserSpeech on web, SpeechToText on native. Customer-facing factory; one line works everywhere. |
| *Customer-implemented* | Anywhere | Implement `Transcriber` to point at Qwen3, Deepgram, ElevenLabs Scribe, your own `/stt-api/transcribe` — same interface, plugs into the same UI |

Typical usage:

```dart
final transcriber = DefaultTranscriber();
await transcriber.initialize();
transcriber.transcripts.listen((ev) {
  if (ev.isFinal) inputController.text = ev.text;
});
// tap-to-toggle:
await transcriber.start();    // mic on
// later:
await transcriber.stop();     // mic off; final transcript fires
```

The mic button is conditionally rendered on `transcriber.isAvailable`, so platforms / browsers without STT support never see one — customer code doesn't gate on platform.

### `AvatarAdminClient`

Programmatic API for the backend's avatar registry. Useful for onboarding new avatars, swapping voice clones, updating personas.

```dart
final admin = twai.admin(developerMode: true);

await admin.addAvatar(
  avatarId: 'MyCelebrityTalk1',
  prompt: '<persona system prompt>',
  voiceId: '<voice clone UUID>',
);

await admin.changeVoiceList({'MyCelebrityTalk1': '<new uuid>'});

final avatars = await admin.allAvatars();
```

---

## Authentication

The SDK uses a **two-key scheme** modeled on Stripe / Twilio:

| Key | Scope | Where it lives | Header |
|---|---|---|---|
| **Publishable** (`pk_live_...`, `pk_test_...`) | Chat sessions only | Safe in browser HTML, mobile app config, JS embeds | `Authorization: Bearer <key>` on HTTP; `?key=<key>` on the WS handshake (browser WebSocket API can't set headers) |
| **Secret** (`sk_live_...`, `sk_test_...`) | Admin operations (register avatars, edit personas, manage voices) | Server-side only — never in browser, never in mobile binary | `Authorization: Bearer <key>` on every request |

`TwaiClient` enforces the scope split: `twai.admin()` throws if `secretKey` was null at construction, so a publishable-only client (e.g. one initialized from browser-visible config) can't accidentally hand admin power to the wrong layer.

Both keys default to null — until the backend turns on validation, requests with no Authorization header succeed (anonymous mode). Customers adopt keys as the backend lights them up.

### Typed auth errors

Auth failures surface as catchable, specific exception types — no string parsing required:

| HTTP | Chat-session exception | Admin exception | Meaning |
|---|---|---|---|
| 401 | `ChatSessionUnauthorizedException` | `AvatarAdminUnauthorizedException` | Missing or invalid key — rotate / correct |
| 403 | `ChatSessionForbiddenException` | `AvatarAdminForbiddenException` | Key valid but lacks scope for this op / tenant |
| 429 | `ChatSessionRateLimitedException` | `AvatarAdminRateLimitedException` | Quota exhausted — retry after window |

WebSocket closes for auth (codes 1008 / 4401 / 4403 / 4429) surface as `MseStreamCloseReason.Unauthorized` and propagate to `ChatSession.done` as `ChatSessionFailed(isPermanent: true)`.

The Web Component embed fires an `error` CustomEvent with `{kind, message, permanent}` so page-level JS can branch on `event.detail.kind === 'unauthorized'` without parsing strings.

---

## Voice input

Both the embed and native Flutter apps ship with cross-platform mic capture + transcription. UX is **tap-to-toggle**: tap mic → speak → recognizer auto-commits on natural pause (or user taps again to force-stop early) → transcript pre-fills the input → user reviews + taps Send.

The mic button is conditionally rendered on `transcriber.isAvailable`, so platforms without STT support never show a mic — customer code doesn't gate on platform.

### Pluggable transcription backend

The SDK ships with two default backends matched to where the app runs:

- **Web** — direct `dart:js_interop` wrap of the browser's `SpeechRecognition` API (Chrome / Edge / Safari 14.5+). Free, zero-config, zero-key. Google's cloud handles transcription transparently.
- **Native** (Android / iOS / macOS / Windows) — wraps the `speech_to_text` plugin against each platform's built-in speech service.

Both implement the same `Transcriber` interface. `DefaultTranscriber()` is a conditional-import factory that resolves to whichever fits the build target.

Customers who need different backends — Qwen3 (the 2wai pipeline's TTS), Deepgram, ElevenLabs Scribe, OpenAI Whisper, their own `/stt-api/transcribe` endpoint — implement `Transcriber` once and pass it where `DefaultTranscriber()` would otherwise be used. Same UI, different backend.

### Pattern matched against penthouse

Penthouse's production mic flow (`frontend/src/lean/mic.ts`) was the reference: MediaRecorder capture → POST audio blob to `/stt-api/transcribe` → backend returns `{text}`. The backend's actual transcription engine (currently Qwen3 in production; the team has tested Deepgram and others) is intentionally opaque to the client. The SDK's `Transcriber` abstraction follows the same shape — the client knows it gets transcripts, doesn't care which engine produced them. Customer swaps engines server-side without touching the SDK.

### Per-platform setup

The SDK auto-selects the right backend; the host app declares the per-platform permission strings:

| Platform | Permission |
|---|---|
| iOS | `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` in `Info.plist` |
| macOS | Same Info.plist keys + `com.apple.security.device.audio-input` + `com.apple.security.network.client` in entitlements (App Sandbox) |
| Android | `<uses-permission android:name="android.permission.RECORD_AUDIO"/>` + `INTERNET` + `<queries>` for SpeechRecognizer discovery on Android 11+ |
| Web | Browser prompts on first `start()` — no manifest required |

Audio routing on iOS — validated on iPhone 15 (iOS 26.5) and the iOS 26.5 simulator. The host app's `AppDelegate` must set `AVAudioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])` after `super.application(...)`, with **no** `setActive(true)` — the `speech_to_text` and `video_player` plugins activate the session lazily; activating eagerly fights the plugins and produces inconsistent routing. Without `.defaultToSpeaker`, iOS routes playback through the earpiece at near-silent volume — penthouse hit the same trap in `lean/mic.ts`.

Apple targets use the `video_player` backend exclusively. The `media_kit` chain (`media_kit`, `media_kit_video`, `media_kit_libs_ios_video`, `volume_controller`) has been removed from iOS — `volume_controller-3.5.0` instantiates the deprecated `MPVolumeView()` at plugin registration via a Swift `static let`, and iOS 26.5 hard-crashes on it. If libmpv is ever needed on iOS, fork `volume_controller` first.

---

## Web Component embed

For non-Flutter sites (jQuery-era PWAs, plain HTML pages, any framework that can render a custom element), the SDK ships as a single JavaScript bundle that registers two HTML custom elements:

```html
<script src="https://cdn.example/embed.js" defer></script>

<!-- video pane only — host page drives its own chat UI via JS -->
<twai-avatar
  avatar-id="RedJesusTalk1"
  voice-id="9c32e898-e99c-4287-89a1-57f5243aa454"
  api-key="pk_live_xxx"
  env="2wai-prod"></twai-avatar>

<!-- video + self-contained chat UI -->
<twai-chat
  avatar-id="..." voice-id="..." api-key="..." env="..."></twai-chat>
```

Imperative JS API (both elements):

```js
const el = document.querySelector('twai-avatar');
await el.connect();
await el.send('Hello');
await el.disconnect();

// Voice input — tap-to-toggle UX on the page side
await el.startListening();        // mic on
await el.stopListening();         // mic off; commits final transcript
await el.cancelListening();       // mic off; discards
el.voiceInputAvailable();         // sync check; false on platforms without STT

el.sessionId; // diagnostic
```

`<twai-chat>` ships with a built-in mic button next to send. `<twai-avatar>` exposes the methods only (host page draws its own mic button) — both shapes work; pick based on whether you want a self-contained chat UI or to hand-roll one.

Events dispatched on the element (all bubble):

| Event | `detail` | Fires when |
|---|---|---|
| `connected` | — | Session handshake completes |
| `reply` | reply text (string) | LLM reply arrives |
| `speaking-start` | PTS (number, seconds) | Avatar begins a speech turn |
| `speaking-end` | PTS (number, seconds) | Avatar finishes a speech turn |
| `transcript` | transcript text (string) | Interim STT result as the user speaks |
| `transcript-final` | committed transcript (string) | Recognizer committed the utterance |
| `error` | `{kind, message, permanent}` | Any session or voice error |
| `disconnected` | end-reason string | Session ended |

Error `kind` values: `unauthorized`, `forbidden`, `rate-limited`, `transport`, `voice-permission-denied`, `voice-no-speech`, `voice-network-error`, `voice-not-supported`, `voice-error`, `unknown`. Page JS branches on the `kind` to decide retry-vs-rotate-key-vs-prompt-for-mic.

**V1 constraint:** one `<twai-avatar>` *or* one `<twai-chat>` per page (Flutter Web's single-engine model). Multi-instance is a known follow-on.

---

## Backend platform — what 2wai provides

The SDK is a client. Behind it sits 2wai's avatar platform:

| Component | What it does | Hosted location today |
|---|---|---|
| **main_service** | Routes chat → render. Owns avatar registry (MongoDB). Selects voice + TTS provider (`tts1`–`tts5` slots only — `tts1`=xtts, `tts2`=gtts, `tts3`=edgetts, `tts4`=index-TTS, `tts5`=qwen-tts, verified). Proxies WS upgrades to inference workers. Also has a server-side ASR factory (FunASR) for transcription. | krystal-avatar.westus2.cloudapp.azure.com (Azure NC40ads H100) |
| **inference_service** | Runs **Wav2Lip+GAN team-fine-tuned** (Rudrabha + `hq_wav2lip_train.py` track; sync loss 0.0269 at step 399k; checkpoint at `/home2_current/zl/Wav2Lip/checkpoints/all/checkpoint_step000399000_loss0.026887.pth`). Mixes generated audio with rendered video frames. Muxes to fragmented MP4. | Same VM as main_service, raw endpoint at `:8001`, orchestration at `:443` |
| **2wai-avatar-pipeline** *(separate, simpler request/response server — Adapter 2)* | Gemini LLM + **ElevenLabs TTS** (`eleven_flash_v2_5`) + standard Rudrabha Wav2Lip. Endpoints: `POST /chat`, `POST /tts-only`, `GET /health`. **ElevenLabs is already in production on this server.** | TBD separate deployment (per `2waiorg/2wai-avatar-pipeline`) |
| **TTS pronunciation rules engine** *(NEW Jun 2026 — `mason/tts-global-pronunciation`)* | Two-stage hot-reloadable rules layer: `brain_normalize` (in main_service before LLM output leaves) + `tts_prepass` (in inference_service before Qwen3 call). v2 schema with `global` / `app:<id>` / `avatar:<id>` scoping, per-rule `lang` tagging. Source of truth: `backend/data/tts_rules.json` in penthouse repo; VM polls `/api/tts/rules` once/min. Companion: `tools/tts_harness/` QA package (discovery + correction + mandatory human review). | Same krystal-avatar VM; rules sourced from penthouse repo via cron poll. Full breakdown in [`voice_and_tts.md`](voice_and_tts.md). |
| **Qwen3-Omni vLLM TTS (`2wai-voicelab`)** | Voice cloning. Stores reference audio clips by UUID; generates speech in cloned voice on demand. Drives the `tts5` slot in main_service. | labs-gpu-01 (separate H100 VM), `:7865` |
| **Brain (LLM) (`avatar-brain`)** | Persona-shaped LLM with RAG (Qdrant) + memory (Mem0) + PromptLayer. Default: `prod.brain.2wai.ai`. Per-avatar overrides: Container Apps for specialized personas (e.g. Talk2Jesus uses Anthropic Claude + theological-honesty guardrails). | Azure Container Apps + various providers |
| **Production transports** | Penthouse uses Adapter 1 (MSE-over-WS); `2wai.ai/jesus` uses **WebRTC** (`aiortc`) per `avatar-player`. The MSE transport is per-outfit opt-in on the 2wai side (only `KenanAutoTrader` enables it today). | Same krystal-avatar VM |
| **Asset storage** | Per-avatar latents, source frames, coords. Auto-downloaded to VM on first `addAvatar` call. | Object store, `avatars/<id>/...` |

The customer never directly touches any of this. They make one network call (`session.sendMessage(text)`) and the platform delivers a lip-synced video response.

---

## Per-avatar customization

Each avatar is a row in `main_service`'s registry with three configurable knobs:

| Knob | What it controls | Set via |
|---|---|---|
| **Avatar id** | Which Wav2Lip asset bundle the worker uses (face, body, background) | `AvatarAdminClient.addAvatar(avatarId: ...)` — assets auto-downloaded from object storage |
| **Voice clone** | Which Qwen3 reference audio drives TTS | `addAvatar(voiceId: ...)` or `changeVoiceList({avatarId: newUuid})` |
| **Brain persona** | LLM endpoint + system prompt | `addAvatar(prompt: ...)` for default brain, or per-avatar URL override in `BRAIN_BASE_URL_OVERRIDES` (server-side config — for specialized personas) |

Onboarding a new celebrity / talent / character = 4 steps:

1. **Capture** — talking-head footage at 25 fps per the content-pipeline spec
2. **Process** — run through the content pipeline (Wav2Lip preprocessing, latents, source-frame extraction) → upload to object storage at `avatars/<avatar_id>/`
3. **Voice clone** — record ~10s of reference audio → POST to the Qwen3 service → get a UUID
4. **Register** — `addAvatar(avatarId, prompt, voiceId)` and the avatar is live

The SDK handles step 4 programmatically. Steps 1–3 are content production work (Mason/Allie's team for 2wai; the customer's team for customer-owned IP).

---

## Reference implementations

The repo ships three reference apps:

### [`apps/jesus/`](../apps/jesus/) — native Flutter (Android / iOS / Windows / Web)

The Talk2Jesus consumer experience. Demonstrates:
- `TwaiClient` initialization from `--dart-define` or `.env`
- Session lifecycle (`connect` → `sendMessage` → render → `close`)
- Live stats panel (env name + URL, connection state, byte counters, speaking events, reply text)
- Scrolling chat history with user/assistant/error bubbles
- Video pane sized to portrait 9:16 with the avatar centered
- Platform-aware sink selection (`media_kit` on native, `video_player` on web)

The reference app is ~250 lines of Flutter:

```dart
// The entire SDK integration, condensed:
final _twai = TwaiClient(env: _env, publishableKey: _publishableKey);

_session = _twai.mseStreamSession(ttsSelection: 'tts5');
_sink = kIsWeb ? VideoPlayerMseLiveSink() : MediaKitMseStreamSink();
await _sink.attach(_session);
await _session.connect(avatar);

_session.replyText.listen((text) => /* show in chat UI */);
_session.sendMessage(userInput);
```

### [`apps/embed/`](../apps/embed/) — Web Component bundle

The same SDK compiled to a single web bundle that registers `<twai-avatar>` and `<twai-chat>` as HTML custom elements. Customer integration is two lines:

```html
<script src="embed.js" defer></script>
<twai-avatar avatar-id="..." voice-id="..." api-key="..."></twai-avatar>
```

Demo page exercises both shapes side-by-side, logs all CustomEvents, and shows the imperative `element.send(text)` JS API.

### [`apps/admin/`](../apps/admin/) — internal admin app (Flutter Web)

The 2wai team's internal admin surface. Two features today: avatar registry management (list / inspect / add) and a pipeline tracker for new avatars moving through the canonical 8-stage content pipeline (raw_capture → standardize → color → master_frame → glue → morphs → renditions → upload). Includes a real master-frame picker that captures a PNG data URL from a video URL via `<video>` + `<canvas>`. Backed by `shared_preferences` (localStorage on web) for alpha; will migrate to a server-backed store once the backend ingest API lands. Full breakdown in [`admin.md`](admin.md).

---

## Reference tooling

Beyond the SDK itself, the repo ships pure-Dart CLI tools in [`tools/`](../tools/):

- **`list_avatars.dart`** — list every avatar registered on a backend. Read-only.
- **`register_jesus.dart`** — example avatar onboarding script. Idempotent.

These run via `dart tools/<script>.dart` — no Flutter context needed, because they depend only on `twai_avatar_sdk_core`. Same code path the SDK uses in-app; just exercised from the CLI.

---

## Test coverage

The pure-Dart core has **102 unit tests** covering every adapter, session, the admin client, the `TwaiClient` entry point, auth header plumbing, and typed exception mapping. Tests use an in-process WebSocket server + `MockClient` from `package:http/testing` — zero live-backend hits in CI. The Flutter app layer has a smoke widget test that verifies the boot path with injected transport fakes.

Test execution: `flutter test` from the core package (~3 seconds), or `flutter test` from the Jesus app.

---

## Platform deployment matrix

| Platform | Video | Voice input | Status |
|---|---|---|---|
| **Web** (Chrome / Edge / Safari) | ✅ MSE-live sink (~1–2s first frame) | ✅ BrowserSpeechTranscriber | **Validated end-to-end in Chrome** — text + voice + lip-synced video + audio |
| **Android** | ✅ media_kit | ✅ SpeechToTextTranscriber | **Validated end-to-end on Pixel 5** — text + voice + video |
| **Windows** | ✅ media_kit | ✅ SpeechToTextTranscriber | **Validated** alongside Android in commit `da3e780`. MediaKit backend confirmed playing avatar video; no outstanding regressions. |
| **iOS** | ✅ video_player + AVPlayer | ✅ SpeechToTextTranscriber | **Validated on iPhone 15 (iOS 26.5) + iOS 26.5 simulator on 2026-06-01.** Build + sign + install + launch + text chat + mic input + avatar render all working. AVAudioSession is `.playAndRecord` / `.default` / `[.defaultToSpeaker, .allowBluetooth, .mixWithOthers]`, set after `super.application(...)` with no `setActive(true)` (plugins activate lazily). The media_kit / volume_controller dependency chain was permanently removed — `volume_controller-3.5.0` hard-crashes on iOS 26.5 via deprecated `MPVolumeView()` at registration. Apple targets use `video_player` only. |
| **macOS** | ⚙️ media_kit | ⚙️ SpeechToTextTranscriber | Untested. Info.plist + Debug/Release entitlements wired for mic + sandbox. Should work; needs a run. |
| **Linux** | ⚙️ media_kit | ✗ no STT plugin | Pure-Dart core works; mic button auto-hides. Untested in app. |

**One Flutter codebase, six target platforms. Plus a Web Component bundle for non-Flutter sites, and an internal Flutter Web admin app at `apps/admin/` for managing the avatar registry + tracking new avatars through the content pipeline (see [`admin.md`](admin.md)).**

---

## What's currently shipped vs roadmap

### Shipped (production-grade)
- ✅ `TwaiClient` tenant identity entry point + `TwaiEnvironment` named profiles (DEV / STAGE / PROD with `--dart-define` + `.env` support; registry self-initializes on first access)
- ✅ Two-key auth scheme (publishable / secret) with `Authorization: Bearer` plumbing
- ✅ Typed auth exceptions (401 / 403 / 429) across HTTP and WebSocket layers
- ✅ Adapter 1 transport: `MseStreamClient` + `ChatGateway` (penthouse MSE-over-WS)
- ✅ Adapter 1 session: `MseStreamChatSession`
- ✅ Adapter 1 video sinks — buffered (`VideoPlayerMseStreamSink`, `MediaKitMseStreamSink`) **and true-streaming** (`VideoPlayerMseLiveSink`, web only via MediaSource Extensions). Buffered sinks use a 2s tail-window delay before flush so the speech tail isn't truncated (fixes the early-flush regression flagged in `architecture.md`'s Phase-1 known-issues).
- ✅ Reply queueing — both buffered sinks play turns serially under rapid input
- ✅ Adapter 2 transport: `PipelineV13Client` (v1.3 POST /chat)
- ✅ Adapter 2 session + sinks for both backends
- ✅ `AvatarAdminClient` (register/list/delete/edit avatars), with admin-scope Authorization headers wired
- ✅ **Voice input** — `Transcriber` abstraction, `BrowserSpeechTranscriber` (web, free), `SpeechToTextTranscriber` (native), `DefaultTranscriber()` factory, tap-to-toggle UX, customer-pluggable for Qwen3 / Deepgram / etc
- ✅ Reference app: Talk2Jesus validated on **Web, Android (Pixel 5), Windows, and iOS (iPhone 15 + simulator on iOS 26.5)**
- ✅ Web Component bundle (`<twai-avatar>` / `<twai-chat>`) with structured event API + voice input
- ✅ **Internal admin app** ([`apps/admin/`](../apps/admin/)) — Flutter Web. Feature 1: avatar registry management (list / add / inspect). Feature 2 alpha (shipped 2026-06-02): pipeline tracker for new avatars through the canonical 8-stage content pipeline, with a real master-frame picker (HTMLVideoElement + canvas → PNG data URL). Full breakdown in [`admin.md`](admin.md).
- ✅ CLI tools: `list_avatars`, `register_jesus`
- ✅ 102 core unit tests + 1 widget test passing

### Active triage
- 🔧 **iOS hot-mic feedback (highest-priority iOS UX issue).** With mic continuously hot, the loud speaker leaks avatar speech back into the recognizer and the avatar talks to itself in a loop. Mitigated today by `cancel-on-Send` + `cancel-on-speaking-start`; the architecturally clean fix is **push-to-talk** — `speech_to_text.listen()` only while the user is actively engaged with the mic button. AVAudioSession `.voiceChat` mode would get hardware echo cancellation for free but narrows the avatar voice's response (more compressed) — keep as fallback if push-to-talk gets rejected on UX grounds.
- 🔧 **iOS mic-tap reliability.** Occasional double-tap-to-engage. Likely subsumed by the push-to-talk state-machine rewrite.
- 🔧 **iOS first-launch crash (non-blocking, non-reproducible).** Original `EXC_BAD_ACCESS (code=50)` recurs once on first mic interaction after a fresh install; relaunch is clean. Suspected: race between first permission grant + AVAudioSession activation + `speech_to_text` engine setup. Capture an Xcode native stack if it surfaces during testing. Mitigation if it persists: defer `speech_to_text.initialize()` until first mic tap (also aligns with push-to-talk fix above).

### Near-term roadmap
- ⚙️ **iOS push-to-talk redesign** — picks up Issue A + likely Issue B above in one architectural change. ~1 day of work, no external dependencies. Highest-leverage next item.
- ⚙️ **Brain SSE direct mode** (`Stream<String>` token-by-token replies for chat-only experiences without avatar render). Unlocks a separate text-only product use case. 1–2 days.
- ⚙️ **macOS validation pass** — entitlements + Info.plist already wired; needs a run.
- ⚙️ **Admin tool roadmap** — local-file upload in the master-frame picker, avatar edit/delete in Feature 1, voice-id picker against Qwen3, cross-record bulk view. Tracked in [`admin.md`](admin.md).
- ⚙️ **Multi-instance Web Component** — V1 ships one embed per page (Flutter Web single-engine constraint); multi-instance is a real ask. 3–5 days; needs research.
- ⚙️ **Customer Transcriber backends** — reference `HttpUploadTranscriber` (penthouse `/stt-api/transcribe` shape) so customers have a working starting point for their own STT backend.
- ⚙️ **pub.dev publish prep** — customers can pull via path/git today; pub.dev is the standard distribution. 1–2 days mechanical.

### Mid-term
- Adapter 3 — WebRTC. Built only if a customer needs to drop into a `blade-virtual`-style backend.
- Server-side key issuance / rotation / revocation (the SDK sends keys; backend issuance + validation is the parallel workstream).
- Server-side STT (Path B) — Qwen3 / Deepgram / etc behind a backend `/stt-api/transcribe`, with the SDK's `Transcriber` pointing at it instead of the on-device recognizer. Needed for commercial deployments where transcript quality matters more than per-device free STT.
- Per-tenant resource hints on `TwaiClient` (priority lanes, region routing, plan-tier allocation).
- Multi-avatar UI helpers: avatar picker, outfit switcher (consumer-app concerns, may stay app-level).

---

## Integration model for a customer

A customer integrating the SDK has three workstreams:

| Workstream | Owned by | Effort |
|---|---|---|
| **App integration** | Customer's Flutter team (or any web team for the embed) | Flutter: 1–2 weeks to wire `TwaiClient` + `VideoSink` into existing design system. Web embed: 1 afternoon to drop the script tag and wire `send()` + `reply` events. |
| **Avatar production** | Customer's content team (or 2wai's, as a service) | 2–6 weeks per avatar — capture, processing, voice clone, persona prompt tuning |
| **Backend hosting** | 2wai (managed) **or** customer (licensed pipeline) | Hosted: customer pays per active session. Licensed: customer hosts main_service + inference + voice clone services themselves |

The SDK is the same regardless of hosting model. App code points at whichever backend URL the customer's `TwaiEnvironment` is configured for.

---

## Code shape

```
2wai-toolkit/                              Dart workspace root
├── docs/
│   ├── architecture.md                        ← internal architecture
│   ├── protocol.md                            ← wire protocol spec
│   ├── sdk_overview.md                        ← this document
│   └── admin.md                               ← admin tool overview + roadmap
├── packages/
│   ├── twai_avatar_sdk_core/                  ← pure Dart, no Flutter dep
│   │   ├── lib/
│   │   │   ├── twai_avatar_sdk_core.dart      (public barrel)
│   │   │   └── src/
│   │   │       ├── twai_client.dart           (TwaiClient entry point)
│   │   │       ├── environment.dart           (TwaiEnvironment profiles)
│   │   │       ├── chat_session.dart          (abstract interface + typed errors)
│   │   │       ├── adapters/
│   │   │       │   ├── mse_stream/            (Adapter 1)
│   │   │       │   └── pipeline_v13/          (Adapter 2)
│   │   │       └── admin/                     (AvatarAdminClient)
│   │   └── test/                              102 unit tests
│   ├── twai_avatar_sdk/                       ← Flutter UI: VideoSink + Transcriber
│   │   └── lib/src/
│   │       ├── video_sink.dart                (interface)
│   │       ├── transcriber.dart               (interface + TranscriptEvent)
│   │       ├── default_transcriber.dart       (conditional barrel: web vs native)
│   │       ├── browser_speech/                (web SpeechRecognition wrap)
│   │       └── speech_to_text/                (native plugin wrap)
│   ├── twai_avatar_sdk_video_player/          ← video_player + Blob URL + MSE backend
│   └── twai_avatar_sdk_media_kit/             ← libmpv backend (not used on iOS)
├── apps/
│   ├── jesus/                                 ← reference native Flutter app
│   │   ├── android/ ios/ macos/ windows/ web/ ← all six target platforms scaffolded
│   │   └── lib/main.dart                      (TwaiClient + DefaultTranscriber)
│   ├── embed/                                 ← Web Component bundle
│   └── admin/                                 ← internal Flutter Web admin app
│       └── lib/src/                           (avatar registry + pipeline tracker)
└── tools/                                     ← pure-Dart CLI utilities
    ├── list_avatars.dart
    └── register_jesus.dart
```

Customer apps depend on `twai_avatar_sdk` + a backend package (`twai_avatar_sdk_video_player` and/or `twai_avatar_sdk_media_kit`). Web Component customers depend on nothing — they just include the prebuilt `embed.js` bundle. CLI/server-side integrations depend on `twai_avatar_sdk_core` (pure Dart). All packages live in the same workspace, single lockfile, no Melos needed.

---

## Talking points for the pitch

1. **"Drop-in conversational avatars for any Flutter app — or any web page."**
   - One Dart import → working talking avatar in 50 lines. Or one `<twai-avatar>` tag for non-Flutter sites.

2. **"One codebase, six platforms."**
   - Web + Android + Windows + iOS validated end-to-end with text + voice + video. macOS + Linux architecture-complete.

3. **"Same SDK runs Sophi and Jesus."**
   - Already validated against two distinct production personas, swappable with a one-line config change

4. **"Transport-agnostic by design."**
   - Pluggable adapter pattern. Today: penthouse MSE-over-WS + simpler v1.3 POST/chat. Future: WebRTC, gRPC, anything

5. **"Two interchangeable video backends."**
   - `video_player` (small binary, official Flutter plugin, MSE-live web sink) and `media_kit` (libmpv, single binary every platform). Customer picks per target.

6. **"Sub-2-second first frame on the streaming web sink."**
   - True MediaSource Extensions streaming — fragments hit the `<video>` element as they arrive on the WebSocket. The SOTA path the penthouse pipeline was designed for.

7. **"Voice input modality across every supported platform."**
   - Tap mic → speak → transcript → send. Web uses the browser's free SpeechRecognition; native uses platform-built-in STT. Both behind one `DefaultTranscriber()`. Customers swap to Qwen3 / Deepgram / 11labs / their own backend with one class.

8. **"Multi-tenant by construction."**
   - `TwaiClient` is the tenant identity object. Two-key scheme (publishable for browser, secret for server) prevents the credential foot-guns by API design.

9. **"Avatar onboarding is programmatic."**
   - `twai.admin().addAvatar(...)` and your celebrity is live — assets auto-fetch from object storage

10. **"Pure-Dart core means tools, server-side, CI all work without Flutter."**
    - Avatar registration scripts, monitoring tools, batch jobs — all run as plain Dart

11. **"Pluggable backend hosting."**
    - 2wai hosts the pipeline as a service, OR customers license + self-host. SDK doesn't change.

12. **"Wav2Lip + voice cloning + LLM persona + STT — all the hard parts behind one network call."**
    - Customer ships product instead of building a 12-month avatar platform

13. **"Backed by production deployments at scale today."**
    - Penthouse Pets in production; Talk2Jesus validated end-to-end on Web, Android, Windows, and iOS.
