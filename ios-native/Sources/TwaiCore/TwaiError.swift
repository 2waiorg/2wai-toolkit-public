import Foundation

/// Typed error ladder for the 2wai Avatar Toolkit on iOS.
///
/// Maps 1:1 to the Dart SDK's `TwaiError` / `TwaiApiErrorKind` and the
/// TypeScript SDK's `TwaiError` class. The server returns the same `kind`
/// strings on every SDK; `TwaiError.from(apiKind:)` is the one entry point
/// that turns a wire string into a typed case.
///
/// All errors in TwaiAvatarKit's public surface are instances of this type.
/// Catch specific cases where the recovery differs; catch `TwaiError` as a
/// whole where you just want to show "the avatar is unavailable."
public enum TwaiError: Error, LocalizedError, Sendable {

    // Auth + credential errors — the mint proxy or the sk_ was wrong.

    /// `Authorization` header missing a `Bearer sk_...` or no header at all.
    case missingKey(message: String)

    /// `sk_` is unknown, revoked, or the mint proxy returned a bad response.
    case invalidKey(message: String)

    // Avatar + session errors — the request parsed but the resource didn't exist.

    /// `avatar_id` or `(owner, name)` resolved to nothing on the gateway.
    case noSuchAvatar(message: String)

    /// `voice_id` resolved to nothing.
    case noSuchVoice(message: String)

    /// Session id in a WS or REST call isn't live.
    case noSuchSession(message: String)

    // Rate / quota.

    /// Tenant cap hit, 429. `retryAfterSeconds` is the server's hint when provided.
    case rateLimited(retryAfterSeconds: Int?, message: String)

    // Server-side errors — gateway responded 5xx or the bridge returned 503.

    /// Catalog hydrate route returned 503 — the gateway's gen-2wai bridge is
    /// not configured. See the dev-docs catalog-hydrate guide for the current
    /// shape: https://developers.2wai.ai/guides/catalog-hydrate/
    case catalogHydrateNotConfigured(message: String)

    /// Gateway returned 5xx for a reason not above.
    case server(statusCode: Int, message: String)

    // Transport + network errors — the gateway was never reached, or the
    // LiveKit room join failed.

    /// Request timed out at the mint proxy / gateway / bridge level.
    case timeout(message: String)

    /// Network error reaching the mint proxy or gateway.
    case transport(message: String, underlying: Error?)

    /// LiveKit room failed to join, or the token was rejected.
    case liveKitFailed(message: String, underlying: Error?)

    // Catch-all for unexpected wire shapes — new error kinds the SDK doesn't
    // know about yet. Callers should display `message` and offer a retry.
    case unknown(kind: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let m), .invalidKey(let m), .noSuchAvatar(let m),
                .noSuchVoice(let m), .noSuchSession(let m),
                .catalogHydrateNotConfigured(let m),
                .timeout(let m):
            return m
        case .rateLimited(let secs, let m):
            if let s = secs { return "\(m) (retry after \(s)s)" }
            return m
        case .server(let code, let m):
            return "\(m) (HTTP \(code))"
        case .transport(let m, _), .liveKitFailed(let m, _):
            return m
        case .unknown(let kind, let m):
            if let k = kind { return "\(m) (kind: \(k))" }
            return m
        }
    }

    /// Map the gateway's `error.kind` wire string to the typed case.
    /// Unknown kinds fall through to `.unknown`.
    public static func from(apiKind kind: String?, message: String, statusCode: Int) -> TwaiError {
        switch kind {
        case "missing_key": return .missingKey(message: message)
        case "invalid_key": return .invalidKey(message: message)
        case "no_such_avatar": return .noSuchAvatar(message: message)
        case "no_such_voice": return .noSuchVoice(message: message)
        case "no_such_session": return .noSuchSession(message: message)
        case "rate_limited": return .rateLimited(retryAfterSeconds: nil, message: message)
        case "catalog_hydrate_not_configured":
            return .catalogHydrateNotConfigured(message: message)
        default:
            if statusCode >= 500 {
                return .server(statusCode: statusCode, message: message)
            }
            return .unknown(kind: kind, message: message)
        }
    }
}
