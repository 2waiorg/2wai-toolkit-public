import Foundation
import TwaiCore

/// Result shape returned by a consumer's mint closure.
///
/// Consumers implement `TwaiMintClosure` that calls their mint proxy
/// (or `TwaiAPIClient.createSession`) and returns one of these cases.
/// The engine uses the enabled case to connect; disabled surfaces the
/// error to the UI without crashing the engine.
public enum TwaiMintResult: Sendable {
    /// Mint succeeded. The engine will connect to `url` with `token`
    /// and join `room`.
    case enabled(url: URL, token: String, room: String)

    /// Mint failed because the tenant hit a rate cap. The engine
    /// surfaces this as `TwaiEngineState.rateLimited` and waits for
    /// `retryAfterSeconds` before offering a retry.
    case rateLimited(retryAfterSeconds: Int)

    /// Mint failed for any other reason. `message` is shown to the
    /// consumer; `cause` is optional for debugging.
    case unavailable(message: String, cause: Error? = nil)
}

/// The closure a `TwaiPlayerView` calls to obtain a LiveKit session.
///
/// Called once on mount and again on each reconnect attempt. Must be
/// Sendable + async. The simplest implementation wraps a
/// `TwaiAPIClient.createSession` call:
///
/// ```swift
/// let api = TwaiAPIClient(credentials: .mintProxy(url: proxyURL))
/// let mint: TwaiMintClosure = {
///     do {
///         let session = try await api.createSession(.init(
///             avatarId: "avt_...", mode: .video
///         ))
///         return .enabled(
///             url: session.livekitUrl,
///             token: session.participantToken,
///             room: session.roomName
///         )
///     } catch TwaiError.rateLimited(let secs, _) {
///         return .rateLimited(retryAfterSeconds: secs ?? 60)
///     } catch {
///         return .unavailable(message: "\(error)", cause: error)
///     }
/// }
/// ```
public typealias TwaiMintClosure = @Sendable () async -> TwaiMintResult
