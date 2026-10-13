# iOS microphone + LiveKit audio-session coexistence

**Status (2026-09-19):** solved via vendored `speech_to_text` 7.4.0+lumara.1 patch. Verified on iPhone 15 / iOS 26.6.2 in the Lumara Dr. Alman panel (`feat/alman-under-wellness`), audible across five mic turns plus a post-idle reconnect turn.

**Applies to:** every Transport 0 (LiveKit) sample that offers voice input via `TwaiMicButton` + `SpeechToTextTranscriber` on iOS. Web is unaffected (`BrowserSpeechTranscriber` does not touch `AVAudioSession`). Android has an [open diagnostic](mic_android_pending.md).

---

## The bug

Upstream `speech_to_text` calls `AVAudioSession.setActive(false)` unconditionally in `stopCurrentListen()`. iOS's `AVAudioSession` is **process-wide**, so this call also stops LiveKit / WebRTC's playout unit even though the mic and the avatar session are logically independent. Symptom sequence:

- Cold start → connect avatar → intro audible.
- User taps mic → recognizes → auto-sends transcript → avatar reply **audible** on turn 1.
- User taps mic again → recognizes → auto-sends → avatar reply **silent** from turn 2 onward.
- Silence persists until app relaunch. Video and lip-sync continue; only audio is gone.

Statistically the tell: `AudioReceiverStatsEvent.currentBitrate` stays high (Opus is arriving + decoding), but `idevicesyslog` shows no `AVAudioSession` / audio-unit activity on the app process. Playout unit is dead, decoded frames go nowhere.

Diagnosed jointly with the Lumara app team on 2026-09-01 through 2026-09-19; report: [`lumara/docs/mvp2/LIVEKIT_IOS_MIC_HANDOFF.md`](file:///c:/Dev/lumara/docs/mvp2/LIVEKIT_IOS_MIC_HANDOFF.md).

## Non-fixes (do NOT try these)

All of these were tested during diagnosis and either did not fix the bug or actively made it worse. Documented so a future contributor can skip them:

- `AppDelegate` `AVAudioSession.setCategory(.playAndRecord, [.defaultToSpeaker, ...])` at app launch — no effect.
- Forcing the microphone-permission prompt at launch — no effect (mic permission was already granted).
- `AudioManager.setAudioSessionOptions(AudioSessionOptions.mediaPlayback())` — deleted from `engine.dart` in 53bb4d5 after it silently failed.
- `LiveKitClient.initialize(bypassVoiceProcessing: true)` — no effect.
- `Hardware.instance.setSpeakerphoneOn(true, forceSpeakerOutput: true)` in `onReady` — no effect on the STT bug AND breaks audio on the second LiveKit session with an `OSStatus -50 (paramErr)`.
- Deactivating / reactivating `AVAudioSession` from Dart callbacks after a stop — downstream of the fault; the WebRTC native audio unit is already gone.
- Calling `flutter_webrtc.Helper.ensureAudioSession()` on stop — same reason.

If a symptom looks like this bug on future SDK work, do NOT reach for these. The root cause is the plugin's own deactivation; the fix has to live there.

## The fix

`packages/twai_speech_to_text_patched/` is a byte-verbatim copy of `csdcorp/speech_to_text` 7.4.0 with one Darwin-only change in `SpeechToTextPlugin.swift` (function `stopCurrentListen`):

1. Before `listen`, cache `audioSession.category`, `categoryOptions`, `mode`.
2. Compute `preserveActiveAudioSession = (category ∈ {.playback, .playAndRecord, .multiRoute})` — a session in one of those categories is a media / call / multi-route session that predates recognition; we should return it unchanged, not tear it down.
3. After `stop`, restore the cached category / options / mode.
4. If `preserveActiveAudioSession`: `setActive(true)` — keep the borrowed session alive.
5. Otherwise: fall through to upstream's `setActive(false, .notifyOthersOnDeactivation)` — correct for standalone `speech_to_text` usage with no other media session active.

The check is category-based so it's implicit — `SpeechToTextTranscriber` doesn't need a new Dart-side option, and standalone `speech_to_text` apps (no LiveKit) still get the original behavior. Full details: [`packages/twai_speech_to_text_patched/LUMARA_PATCH.md`](../packages/twai_speech_to_text_patched/LUMARA_PATCH.md).

The workspace root `pubspec.yaml` swaps the patched version in for every workspace member via `dependency_overrides.speech_to_text`.

## External-consumer setup

**If you're depending on the toolkit's SDK packages from outside this workspace** (e.g. a customer app like Lumara), you need to add the same override in your own `pubspec.yaml` until [Path forward](#path-forward) lands upstream:

```yaml
dependency_overrides:
  speech_to_text:
    path: <relative path to your copy of packages/twai_speech_to_text_patched>
```

You can either copy the `packages/twai_speech_to_text_patched/` directory into your app's `third_party/` folder (matches Lumara's approach) or add a git-submodule / relative path back into a checked-out toolkit tree. The Dart-side API is unchanged either way.

Also required on iOS: `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` in your `Info.plist`. Toolkit demo apps have these in [`apps/*/ios/Runner/Info.plist`](../apps/enlighten/ios/Runner/Info.plist).

## Acceptance test (physical iPhone)

Simulator will NOT reproduce the bug (or the fix). Physical device required.

1. `flutter run --profile --dart-define=LK_DEBUG=true` (release drops Dart prints; debug JIT-crashes on iOS 26).
2. Connect the avatar. Confirm intro is audible.
3. Tap the mic. Speak a short phrase. Tap again. Transcript arrives; avatar responds. **Audible.**
4. Repeat 5 mic turns without app relaunch or backgrounding. **Audible throughout.**
5. Let the session idle-timeout (~1 min for the `livealman` broker). Trigger reconnect (send another message → auto-reconnect, or tap refresh). Speak again. **Audible on the reconnected session.**

If any turn goes silent, the patched plugin is not resolving through the dependency graph. Check `dependency_overrides.speech_to_text` in the resolved `pubspec.lock`.

## Path forward

The toolkit tracks two parallel work streams:

- **Path A (shipped 2026-09-19):** vendored patch under the toolkit workspace. Current state.
- **Path C (open, upstream):** contribute the change back to `csdcorp/speech_to_text`. The upstream shape should be a `preserveActiveSessionOnStop: bool` option (default false = current behavior; when true = the vendored logic). Once merged and released, replace the override with the upstream constraint and delete `packages/twai_speech_to_text_patched/`.

Removal criteria for the vendored copy:

1. Upstream `speech_to_text` release exposes an equivalent option (or takes an equivalent behavior change unconditionally).
2. That release is verified on a physical iPhone against a live LiveKit receive-only session using the acceptance test above.

Both required. Do not delete the vendored copy on the strength of a merged PR alone.

## Related

- Upstream tickets:
  - [`csdcorp/speech_to_text#479`](https://github.com/csdcorp/speech_to_text/issues/479) — WebRTC audio turns off after iOS STT.
  - [`livekit/client-sdk-flutter#996`](https://github.com/livekit/client-sdk-flutter/issues/996) — STT and LiveKit remote audio session conflict.
- iOS receive-only audio history (livekit_client 2.9.0 regression → 2.8.1 pin restoration): [`docs/livekit_ios_receive_only_audio.md`](livekit_ios_receive_only_audio.md).
- Android mic status: [`docs/mic_android_pending.md`](mic_android_pending.md).
- Lumara's own handoff: [`lumara/docs/mvp2/LIVEKIT_IOS_MIC_HANDOFF.md`](file:///c:/Dev/lumara/docs/mvp2/LIVEKIT_IOS_MIC_HANDOFF.md).
