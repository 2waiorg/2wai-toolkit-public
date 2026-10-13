import Foundation

/// How TwaiAvatarKit obtains a short-lived LiveKit token for a session.
///
/// The mint-proxy pattern is enforced across every 2wai SDK: the `sk_` key
/// NEVER reaches client code. A customer server (the "mint proxy") holds
/// the `sk_`, exchanges it for a short-lived LiveKit JWT, and returns the
/// JWT to the client. `TwaiCredentials.mintProxy(url:)` tells the SDK where
/// that proxy lives.
///
/// Mirrors the Dart `TwaiCredentials` + the TypeScript SDK's
/// `TwaiCredentials.mintProxy()`.
public enum TwaiCredentials: Sendable {

    /// The default and only recommended path.
    ///
    /// - `url`: your mint proxy's `POST /v1/sessions` endpoint. The SDK
    ///   will `POST` the session-mint request body to this URL; your
    ///   server attaches `Authorization: Bearer sk_...` and forwards to
    ///   `api.2wai.ai/v1/sessions`, then returns the gateway's response
    ///   (unchanged) to the client.
    /// - `headers`: optional headers the SDK will attach to every mint
    ///   request. Useful for request-tracing or multi-tenant
    ///   demultiplexing. The SDK never puts credentials in headers; this
    ///   is for your own use.
    case mintProxy(url: URL, headers: [String: String] = [:])

    /// Escape hatch for raw sk_ use. **Not recommended** for shipped
    /// client code — the sk_ ends up embedded in the client. Keep this
    /// for throwaway scripts and smoke tests.
    ///
    /// Flagged with a leading underscore so it's visually obvious at the
    /// call site. Produces `TwaiError.invalidKey` on any 401 just like
    /// the mint-proxy path.
    case _rawSecretKey(String)

    /// Returns the headers that go on every mint-proxy / gateway request.
    /// For `.mintProxy`, this is just whatever custom headers the consumer
    /// supplied. For `._rawSecretKey`, this adds `Authorization: Bearer sk_`.
    internal func headers() -> [String: String] {
        switch self {
        case .mintProxy(_, let extraHeaders):
            return extraHeaders
        case ._rawSecretKey(let sk):
            return ["Authorization": "Bearer \(sk)"]
        }
    }

    /// The endpoint URL the SDK should POST session mints to.
    /// For mint-proxy, this is the customer URL. For raw sk_, this is the
    /// gateway directly.
    internal func mintEndpoint(gatewayBaseURL: URL) -> URL {
        switch self {
        case .mintProxy(let url, _):
            return url
        case ._rawSecretKey:
            return gatewayBaseURL.appendingPathComponent("/v1/sessions")
        }
    }
}
