/// Transport 0 — the LiveKit-native path.
///
/// This is the current LiveKit consumer surface for the 2wai Avatar
/// SDK. It is a Dart port of Mason's `@twai/core` engine
/// (`packages/core/src/engine.ts` on twai-web-sdk
/// `feat/livekit-engine`), which itself is a port of PP's production
/// `PenthouseLiveKitTransport`. Same six seams, same load-bearing
/// lifecycle rules, same 864-session-incident discipline.
///
/// See:
///
/// - `src/transport0/engine.dart` — the state machine
/// - `src/transport0/twai_transport0_player.dart` — drop-in widget
/// - `src/transport0/room_lifecycle.dart` — host reconnect policy helper
///
/// The **older** LiveKit path (`LiveKitChatSession`,
/// `LiveKitVideoSink`, `createLiveKitHandle`, `liveKitSinkFactory`
/// re-exported from `twai_avatar_sdk_livekit.dart`) is retained
/// unchanged, orphaned. New integrations use this barrel; old
/// integrations keep working while we transition.
library;

export 'src/transport0/barrel.dart';
