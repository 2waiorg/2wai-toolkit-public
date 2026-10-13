import Foundation

/// Events the TwaiEngine emits on its event stream.
///
/// Mirrors the Dart engine's event ladder (`EngineState`, `SpeakingEvent`,
/// `ReplyText` etc.) collapsed into one Swift enum. Consumers either listen
/// to the whole stream via `AsyncSequence` or opt into specific-event
/// SwiftUI modifiers on `TwaiPlayerView`.
public enum TwaiEngineEvent: Sendable {

    // MARK: Lifecycle

    /// Mint closure called, mint succeeded, LiveKit room join starting.
    case connecting

    /// Agent participant appeared in the room; video/audio tracks subscribed.
    /// The player is ready to accept `send(_:)` after this.
    case ready

    /// Session ended normally (room disconnected without error).
    case disconnected

    /// Mint closure returned `.rateLimited`; engine idle until the backoff
    /// elapses, then will retry mint.
    case rateLimited(retryAfterSeconds: Int)

    /// Mint or room-join failed terminally.
    case failed(message: String, underlying: Error?)

    // MARK: Avatar activity

    /// Avatar started/stopped speaking (triggered by the LiveKit audio
    /// track going active/inactive on the agent participant).
    case speaking(active: Bool)

    /// A reply text chunk arrived over the agent's `lk.chat` data channel.
    /// `text` may be a partial sentence; `isFinal` indicates the end of a
    /// reply turn.
    case replyText(text: String, isFinal: Bool)

    /// A full reply turn completed (agent idle, no more text or audio
    /// coming for this user turn).
    case replyDone(turnId: String?)

    /// Agent-side state change hint (e.g. "listening" / "thinking" /
    /// "speaking") derived from LiveKit agent-state attributes.
    case agentState(String)
}

/// Rolled-up engine state used by UI for simple status display.
/// Derived from the event stream; convenience for consumers who don't
/// want to subscribe to every event.
public enum TwaiEngineState: Sendable, Equatable {
    case idle
    case connecting
    case ready
    case rateLimited(retryAfterSeconds: Int)
    case failed(message: String)
    case disconnected
}
