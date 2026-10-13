# twai_speech_to_text_patched

**Vendored `speech_to_text` 7.4.0 with a Darwin-only patch for LiveKit iOS coexistence.**

Package identity is unchanged (`name: speech_to_text`, version `7.4.0+lumara.1`) so the workspace root `dependency_overrides` slots this in for every workspace member. External SDK consumers must add the same override in their own `pubspec.yaml`.

## Why this exists

Upstream `speech_to_text` calls `AVAudioSession.setActive(false)` unconditionally on stop. iOS's `AVAudioSession` is process-wide, so that also tears down LiveKit's playout unit even when the mic and the avatar session are logically independent. Symptom: avatar goes silent from mic turn 2 onward — turn 1 works, then remote audio dies until app relaunch.

The patch (Darwin-only, ~35 LOC in `darwin/speech_to_text/Sources/speech_to_text/SpeechToTextPlugin.swift`):

1. Before `listen`, cache `AVAudioSession.category`, `categoryOptions`, `mode`.
2. Compute `preserveActiveAudioSession = (category ∈ {.playback, .playAndRecord, .multiRoute})` — a category-based test for "was another media / call session already active before recognition borrowed the session?"
3. On `stop`, restore the cached configuration.
4. If `preserveActiveAudioSession`: `setActive(true)` — keep the borrowed session alive.
5. Otherwise: unchanged — fall through to upstream's `setActive(false, .notifyOthersOnDeactivation)`.

Standalone `speech_to_text` apps (no LiveKit or other media session in play) retain the original behavior exactly. The change is transparent to Dart callers.

Full patch details + provenance: [`LUMARA_PATCH.md`](LUMARA_PATCH.md).

## Removal criteria

Delete this directory + the `dependency_overrides.speech_to_text` entry in the workspace root when BOTH:

1. Upstream `csdcorp/speech_to_text` exposes an equivalent session-preserve option (or takes an equivalent behavior change unconditionally). Tracked at [csdcorp/speech_to_text#681](https://github.com/csdcorp/speech_to_text/pull/681) — proposed `SpeechListenOptions.preserveExistingAudioSession` flag.
2. That upstream release is verified on a physical iPhone against a live LiveKit receive-only session (see [`docs/mic_lifecycle_ios_livekit.md`](../../docs/mic_lifecycle_ios_livekit.md) for the acceptance test).

Both required. Do not delete on the strength of a merged PR alone.

## Do NOT change

- The `name:` in `pubspec.yaml` — must remain `speech_to_text` for the override to swap it in for the transitive dep resolution.
- The Darwin patch itself — apply diffs at the plugin level only if you have device verification on an iPhone with a live LiveKit session.
- The BSD-3-Clause LICENSE — this is a downstream copy of `csdcorp/speech_to_text`, not a rewrite.

## Related

- [`docs/mic_lifecycle_ios_livekit.md`](../../docs/mic_lifecycle_ios_livekit.md) — full iOS diagnosis, non-fixes tried, acceptance test, upstream PR tracking.
- [csdcorp/speech_to_text#479](https://github.com/csdcorp/speech_to_text/issues/479) — upstream issue this addresses.
- [livekit/client-sdk-flutter#996](https://github.com/livekit/client-sdk-flutter/issues/996) — same root cause reported on the LiveKit side.
- [`SpeechToTextTranscriber`](../twai_avatar_sdk/lib/src/speech_to_text/speech_to_text_transcriber_native.dart) — the Dart wrapper that consumes this plugin.
