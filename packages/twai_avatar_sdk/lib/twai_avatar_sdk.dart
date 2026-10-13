/// 2wai Avatar SDK — Flutter UI surface (interfaces only).
///
/// Re-exports the entire pure-Dart core (`package:twai_avatar_sdk_core`)
/// and defines the [VideoSink] abstraction. Concrete sink
/// implementations live in separate, interchangeable packages:
///
/// - **`package:twai_avatar_sdk_video_player`** — video_player +
///   path_provider backed sinks (incl. video_player_win on Windows).
///   Smaller binary; official Flutter team plugin.
/// - **`package:twai_avatar_sdk_media_kit`** — libmpv-backed sinks via
///   media_kit. Single backend across every platform including Linux
///   and (with extra setup) web. Larger binary; LGPL libmpv.
///
/// Pick one based on your binary-size / license / platform-reach
/// constraints. App code above the sink stays identical either way —
/// both implement the same [VideoSink] interface.
library;

// Re-export everything from the pure-Dart core.
export 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

// Video rendering interface (concrete impls in sibling packages).
export 'src/video_sink.dart' show VideoSink, alwaysNotRendering;

// Canonical customer-facing widget — composes an idle source + a
// concrete sink + a session into the idle↔conversation↔idle cycle
// every customer app needs. See TwaiAvatarStage docstring.
export 'src/avatar_stage.dart' show TwaiAvatarStage;

// Controller-flavored stage — composes a TwaiAvatarPlayerController +
// VideoSink + AvatarIdleSource. Where TwaiAvatarStage takes a
// ChatSession and manages the sink lifecycle internally, this widget
// takes a pre-built controller + sink and just renders them, with the
// sink faded in/out on speaking state. See TwaiAvatarPlayerStage.
export 'src/avatar_player_stage.dart' show TwaiAvatarPlayerStage;

// The developer-facing widget facade. Takes a PlayerAvatar, picks
// the right sink for the platform, composes idle + live + controller
// under the hood. Optional external TwaiPlayerHandle for imperative
// control. See TwaiPlayer.
export 'src/twai_player_widget.dart' show TwaiPlayer, TwaiSinkFactory;

// On-page diagnostic HUD — Flutter port of Mason's ?diag=1 overlay
// (avatar-player/src/main.ts v62). Off by default; enable via
// TwaiDebugController.instance.enable() or wrap your root in
// TwaiDebugOverlayScope. Captures debugPrint + FlutterError.onError +
// PlatformDispatcher.onError into a rolling 100-entry buffer.
export 'src/twai_debug_overlay.dart'
    show
        TwaiDebugController,
        TwaiDebugOverlay,
        TwaiDebugOverlayScope,
        TwaiDebugOverlayCorner,
        DebugEntry,
        DebugEntryKind;

// Wire capture — Flutter port of Mason's ?review=1 fMP4 recorder
// (avatar-player/src/main.ts). Subscribe to a handle's videoBytes
// stream; buffer bit-exactly for save / scrub / round-trip through
// Mason's twai-api/scripts/ CLI.
export 'src/twai_wire_recorder.dart'
    show
        TwaiWireRecorder,
        WireRecorderState,
        WireFragment;

// Chat autoscroller — wraps a scrollable + auto-jumps to bottom on
// itemCount increase. Consumer builds the ListView; this widget just
// orchestrates the post-frame scroll jump. Phase 3 P3.4.
export 'src/twai_chat_auto_scroller.dart' show TwaiChatAutoScroller;

// Keyboard shortcuts overlay — Focus + Shortcuts + Actions stack +
// `/`-triggered help sheet. Web + desktop only. Phase 3 P3.5.
export 'src/twai_keyboard_shortcuts_overlay.dart'
    show
        TwaiKeyboardShortcutsOverlay,
        TwaiShortcut;
// Re-export the handle + core types so `import twai_avatar_sdk` is
// enough for the majority of developer code.
export 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart'
    show
        TwaiPlayerHandle,
        // Also re-export the layered controller — TwaiSinkFactory
        // callers (widget-level sinkFactory override) need to name
        // its type; without this export they'd need a direct
        // twai_avatar_sdk_player dep just to write the sink-picker.
        TwaiAvatarPlayerController,
        PlayerAvatar,
        PlayerOutfit,
        PlayerGesture,
        PlayerFrame,
        PlayerConfig,
        PlayerStatus,
        PlayerStatusEvent,
        XpEvent,
        XpBand,
        LevelUpEvent,
        MoodEvent,
        OverlayEvent,
        OverlayKind,
        // Adapter-1 pipeline-stack enum — the type of
        // PlayerAvatar.deliveryOverride. Consumers setting the
        // override need to name it.
        AvatarDelivery;
export 'src/avatar_idle_source.dart'
    show
        AvatarIdleSource,
        AssetVideoIdle,
        NetworkVideoIdle,
        AssetPosterIdle,
        NetworkPosterIdle,
        SolidColorIdle,
        NoIdle,
        TransparentVideoIdle;

// Layout primitives — pre-built patterns for placing the avatar
// stage alongside customer content. TwaiSideBySideLayout for
// desktop/web-style (2wai.ai pattern); TwaiStackedLayout for phone
// first / avatar-on-top pattern. TwaiImmersiveLayout for widescreen
// 16:9 stages with portrait fallback (Cleopatra / 2wai-edu pattern).
// Full-screen + overlay patterns land when a customer needs them.
export 'src/avatar_layout.dart'
    show
        TwaiSideBySideLayout,
        TwaiStackedLayout,
        TwaiImmersiveLayout,
        AvatarSide,
        AvatarVerticalSide;

// 5-layer immersive stage — plate + atmosphere + feed + overlay +
// tools. Every layer except `feed` is optional; simple opaque
// avatars just fill `feed` and skip the rest. Composes with
// TwaiImmersiveLayout for the widescreen cinematic pattern.
export 'src/avatar_scene_stage.dart' show TwaiSceneStage, StageZoomLevel;

// Connection-status overlay — status-aware wrapper that paints
// caller-supplied "connecting" or "failed" UI on top of a live
// avatar widget. Both slots opt-in; leave null for silent auto-hide.
export 'src/connection_overlay.dart' show TwaiConnectionOverlay;

// Full-viewport cinematic player — for reward clips, transition
// films, or any moment that shouldn't inherit the immersive stage's
// clip / z-stack hierarchy. Widget or `show()` static helper.
export 'src/cinematic_player.dart' show TwaiCinematicPlayer;

// Scene stitching primitives — the layer stack for immersive
// multi-scene experiences (Cleopatra tutor pattern). Each primitive
// is standalone (wraps any child); TwaiSceneNavigator composes them
// into a full stateful multi-scene stage. All optional — apps that
// want a single-scene stage just use TwaiSceneStage directly.
export 'src/scene/scene_anchor.dart' show SceneAnchor;
export 'src/scene/edge_feather.dart' show TwaiEdgeFeather;
export 'src/scene/color_grade.dart' show TwaiColorGrade;
export 'src/scene/contact_shadow.dart' show TwaiContactShadow;
export 'src/scene/ken_burns.dart' show TwaiKenBurnsParallax;
export 'src/scene/scene.dart' show TwaiScene;
export 'src/scene/scene_navigator.dart'
    show TwaiSceneNavigator, TwaiSceneController;

// Per-avatar theming — PlayerAvatarTheme value type + inherited-
// widget scope + the themed chat panel that consumes them. Optional;
// unthemed rendering is what the SDK shipped before B1-B3.
export 'src/player_avatar_theme.dart'
    show PlayerAvatarTheme, PlayerAvatarThemeScope;
export 'src/themed_chat_panel.dart'
    show TwaiThemedChatPanel, TwaiTextureOverlay, TwaiVignette, TwaiGildedRule;

// Pluggable speech-to-text. Default ships a direct dart:js_interop
// wrap of the browser's SpeechRecognition API (free, web only).
// Customers swap in their own Transcriber for native targets or to
// point at a backend (Qwen3, Deepgram, ElevenLabs Scribe, etc).
export 'src/transcriber.dart'
    show Transcriber, TranscriptEvent, TranscriberError;
// Default cross-platform Transcriber — conditional barrel resolves to
// BrowserSpeechTranscriber on web, SpeechToTextTranscriber on native.
// Customers normally use this; the platform-specific classes are
// available for explicit selection.
export 'src/default_transcriber.dart' show DefaultTranscriber;
export 'src/browser_speech/browser_speech_transcriber.dart'
    show BrowserSpeechTranscriber;
export 'src/speech_to_text/speech_to_text_transcriber.dart'
    show SpeechToTextTranscriber;
// Server-side STT Transcriber — POSTs recorded audio to a Whisper-shaped
// endpoint. Web-only in V1 (native is a stub that returns unavailable);
// see http_stt_transcriber_stub.dart for the migration story. Use this
// when browser SpeechRecognition proves unreliable (Brave strips keys
// silently; Chrome retries on network blips). Gen-2wai's Studio moved
// to this path 2026-09-04.
export 'src/http_stt_transcriber.dart' show HttpSttTranscriber;
// Cross-platform Transcriber: captures raw PCM via the `record` package,
// wraps in a WAV header, POSTs to a Whisper-shaped endpoint. Uses
// `audio_session` for explicit platform session management so it coexists
// with an active LiveKit session. The production-proven answer for the
// Android + LiveKit mic gap that SpeechToTextTranscriber has — closes
// docs/mic_android_pending.md's "unresolved" callout. Design:
// docs/audio_stream_transcriber_design.md.
export 'src/record_stt_transcriber.dart' show RecordSttTranscriber;

// Push-to-talk mic button widget. Drives any [Transcriber]; consumer
// wires the transcript to their engine's send(). Push-to-talk by
// default (the wiki-documented architectural fix for iOS hot-mic
// feedback); tap-to-toggle available via the `gesture` param.
export 'src/twai_mic_button.dart'
    show TwaiMicButton, TwaiMicGesture;

// Session openers — [TwaiGreeting] + variants + persistence stores. See
// docs/twai_greeting_design.md.
//
// Phase 1 shipped (2026-10-02): [TwaiGreeting.text] for the programmatic
// opener pattern. [TwaiGreeting.rendered] and [TwaiGreeting.dynamic] are
// declared so consumers can code against the stable API, but the widget
// side ships in Phase 2 alongside catalog hydrate.
export 'src/twai_greeting.dart'
    show
        TwaiGreeting,
        TwaiGreetingNone,
        TwaiGreetingText,
        TwaiGreetingRendered,
        TwaiGreetingDynamic,
        TwaiGreetingPlayedEvent,
        GreetingKind;
export 'src/greeting_store.dart'
    show
        GreetingStore,
        SharedPreferencesGreetingStore,
        InMemoryGreetingStore;

