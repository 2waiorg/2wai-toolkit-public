/// 2wai Avatar Player.
///
/// The SDK's canonical player — a 2wai-owned player modeled after the
/// Penthouse player. "Modeled after" is the ownership framing (this is
/// not a fork). Same capabilities, same timing constants, same
/// state-machine transitions — the only allowed divergence from the
/// reference is where Flutter vs JS forces one. See PRD §5.1 and
/// `docs/port_spec_avatar_player.md`.
///
/// The player is imperative in shape: [TwaiAvatarPlayerController] owns
/// the session lifecycle, state machine, reconnect discipline, and
/// message-flow gating. Widgets and layouts live above; transport
/// (`ChatSession`, video sinks) lives below.
///
/// See the port-status checklist on [TwaiAvatarPlayerController] for
/// what's landed and what remains.
library;

export 'src/player_config.dart' show PlayerConfig;
export 'src/player_controller.dart' show TwaiAvatarPlayerController;
// Re-export mood types from core so consumers only need this one
// package. Mood + MoodEvent flow through `controller.moodEvents` and
// `controller.currentMood`.
export 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart'
    show Mood, MoodEvent;
export 'src/player_state.dart'
    show
        PlayerStatus,
        PlayerStatusEvent,
        PlayerEndReason,
        PlayerDisposed,
        PlayerRemoteClosed,
        PlayerTransientFailure,
        PlayerExhausted;
// Opt-in content-layer helpers: pure data types + a stateless
// rotation utility. Apps that want outfit-based UX use these; apps
// that don't never construct them (no controller-side state, no cost).
export 'src/outfit.dart'
    show
        PlayerAvatar,
        PlayerOutfit,
        PlayerEmote,
        ResolvedOutfit,
        resolveOutfit,
        OutfitAwareController;
export 'src/gesture.dart'
    show
        PlayerGesture,
        PlayerFrame,
        filterGestures,
        filterFrames,
        GestureAwareController;
export 'src/overlay.dart' show OverlayKind, OverlayEvent;
// The developer-facing facade: one class, one call, full pipeline.
export 'src/twai_player_handle.dart' show TwaiPlayerHandle;
export 'src/api/twai_api_client.dart' show TwaiApiClient;
export 'src/api/twai_api_types.dart'
    show PetProgress, AwardMessageResponse, RewardUnlock;
export 'src/api/avatar_catalog.dart'
    show AvatarCatalogResponse, AvatarCatalogOutfitResponse, AvatarDelivery;
export 'src/known_avatars.dart' show KnownAvatars;
// Progression events (opt-in). App tells the controller "user
// earned XP" / "user leveled up"; the controller enforces the
// deferred-while-speaking delivery discipline the reference player
// uses so toasts / modals don't compete with the reply.
export 'src/progression.dart'
    show XpBand, XpEvent, LevelUpEvent;
