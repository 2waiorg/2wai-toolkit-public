import Foundation
import TwaiCore
import TwaiLiveKit

/// Imperative control surface for `TwaiPlayerView` from parent SwiftUI code.
///
/// Grab via `.onReady { handle in ... }`:
///
/// ```swift
/// TwaiPlayerView(mint: mint)
///     .onReady { handle = $0 }
///     .task { try? await handle?.send("Hi") }
/// ```
///
/// Thin wrapper over `TwaiEngine` — all methods delegate.
@MainActor
public final class TwaiPlayerHandle: ObservableObject {

    public let engine: TwaiEngine

    public init(engine: TwaiEngine) {
        self.engine = engine
    }

    /// Send a user turn to the avatar. Throws `TwaiError` on failure
    /// (session not ready, warming up, network, etc.).
    public func send(_ text: String, extra: [String: String]? = nil) async throws {
        try await engine.send(text, extra: extra)
    }

    /// Disconnect from the LiveKit room. Idempotent.
    public func disconnect() async {
        await engine.disconnect()
    }

    /// Current rolled-up engine state. For UI binding, prefer observing
    /// `engine.state` via `@ObservedObject var engine`.
    public var state: TwaiEngineState { engine.state }
}
