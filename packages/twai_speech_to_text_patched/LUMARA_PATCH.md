# speech_to_text iOS audio-session patch (Lumara / 2wai toolkit)

This directory vendors `speech_to_text` 7.4.0 under its BSD-3-Clause license
(see `LICENSE`). Package identity is unchanged (`name: speech_to_text`,
`version: 7.4.0+lumara.1`) so a workspace-root
`dependency_overrides.speech_to_text: { path: ... }` slots it in for every
member of the workspace.

## Why the patch is here

Upstream `speech_to_text` calls `AVAudioSession.setActive(false)` when speech
recognition stops. iOS's `AVAudioSession` is **process-wide**, so that call
also tears down any concurrent WebRTC/LiveKit playout unit. In this SDK's
context (`twai_avatar_sdk_livekit`, Transport 0), that means the avatar
subscriber's audio dies the moment the user commits their first mic turn:

- turn 1: mic → transcript delivered → avatar speaks → **audible**
- turn 2 onward: avatar speaks → **silent** until app relaunch

The patch is a Darwin-only change to `SpeechToTextPlugin.swift`:

1. Before `listen`, cache the current audio session's category, category
   options, and mode.
2. Compute `preserveActiveAudioSession` — true when the category is
   `.playback`, `.playAndRecord`, or `.multiRoute` (indicating an existing
   media / call / multi-route session was already active before recognition
   borrowed the session).
3. After `stop`, restore the cached category / options / mode.
4. If `preserveActiveAudioSession` is true, `setActive(true)` — keep the
   session alive so LiveKit playout resumes.
5. Otherwise, `setActive(false, .notifyOthersOnDeactivation)` — upstream's
   original behavior. This preserves correctness for apps that use `speech_to_text`
   standalone (no LiveKit or other media session in play).

The change is transparent to Dart callers. `SpeechToTextTranscriber` in
`twai_avatar_sdk` needs no API-level change to benefit.

## Provenance

Patch authored in the Lumara app repo
(`c:/Dev/lumara/lumara_flutter_app/third_party/speech_to_text/`) on 2026-09-19,
verified on iPhone 15 / iOS 26.6.2 that same day
(see `docs/mic_lifecycle_ios_livekit.md` in this repo). Copied here verbatim
on 2026-09-19 so every workspace member (demo apps + downstream toolkit
consumers) inherits the correct behavior transparently.

## Upstream references

- csdcorp/speech_to_text #479 — WebRTC audio turns off after iOS STT
- livekit/client-sdk-flutter #996 — STT and LiveKit remote audio session
  conflict
- Apple: `AVAudioSession` activation and live speech recognition (single
  shared session)
- flutter-webrtc `RTCAudioSession.h` — callers should coordinate through the
  shared session and balance activation/deactivation

## Path forward (removal criteria)

Keep this override in place until BOTH of the following:

1. Upstream `csdcorp/speech_to_text` exposes an iOS session-preserve /
   session-ownership option (or takes an equivalent behavior change).
2. That upstream release is device-verified against a live LiveKit
   receive-only session on a physical iPhone.

When both land, delete this directory + the `dependency_overrides.speech_to_text`
entry in the root `pubspec.yaml`, and switch `SpeechToTextTranscriber` to opt
into the upstream API.

## Do NOT change

- The `name:` in `pubspec.yaml` — must remain `speech_to_text` for the
  override to swap it in for the transitive dep resolution.
- The Darwin patch itself — apply diffs at the plugin level only if you have
  device verification on an iPhone with a live LiveKit session.
- The BSD-3-Clause LICENSE — this is a downstream copy, not a rewrite.
