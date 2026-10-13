import Foundation

/// REST client for the twai-api gateway at `api.2wai.ai` (or your mint proxy).
///
/// Two primary surfaces today:
/// - `createSession(_:)` — mint a LiveKit session.
/// - `getAvatar(owner:name:)` — catalog hydrate; resolve `(owner, name)` to
///   a playable record. Pending gateway deploy — returns `503
///   catalogHydrateNotConfigured` until the shared service bearer lands in
///   `twaisecretskv`.
///
/// Mirrors the Dart `TwaiApiRestClient` surface. Async / await throughout.
/// Every error maps to a typed `TwaiError` case; nothing throws raw
/// `URLError` to the caller.
public actor TwaiAPIClient {

    private let credentials: TwaiCredentials
    private let gatewayBaseURL: URL
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// - credentials: how to authenticate (mint-proxy is the primary path).
    /// - gatewayBaseURL: the public gateway. Defaults to `https://api.2wai.ai`.
    ///   Override for staging / local dev.
    /// - urlSession: inject for testing. Defaults to a short-timeout shared
    ///   session.
    public init(
        credentials: TwaiCredentials,
        gatewayBaseURL: URL = URL(string: "https://api.2wai.ai")!,
        urlSession: URLSession = .shared
    ) {
        self.credentials = credentials
        self.gatewayBaseURL = gatewayBaseURL
        self.urlSession = urlSession

        let d = JSONDecoder()
        self.decoder = d

        let e = JSONEncoder()
        self.encoder = e
    }

    // MARK: - Session mint

    /// `POST /v1/sessions` → short-lived LiveKit session.
    ///
    /// For `.mintProxy` credentials the request goes to the customer's
    /// proxy URL (which forwards to the gateway with the sk_). For
    /// `._rawSecretKey` it goes to the gateway directly.
    public func createSession(_ req: TwaiAPI.SessionRequest) async throws -> TwaiAPI.SessionResponse {
        let url = credentials.mintEndpoint(gatewayBaseURL: gatewayBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in credentials.headers() {
            request.setValue(v, forHTTPHeaderField: k)
        }
        do {
            request.httpBody = try encoder.encode(req)
        } catch {
            throw TwaiError.unknown(kind: nil, message: "Failed to encode session request: \(error)")
        }

        let (data, response) = try await perform(request: request)
        return try decode(TwaiAPI.SessionResponse.self, from: data, response: response)
    }

    // MARK: - Catalog hydrate (NEW 2026-10-06)

    /// `GET /v1/avatars/{owner}/{name}` → resolved avatar + optional
    /// greeting.
    ///
    /// Pending gateway deploy — returns `TwaiError.catalogHydrateNotConfigured`
    /// (503) until the shared service bearer lands in `twaisecretskv`. Flutter
    /// equivalent: `TwaiApiRestClient.getAvatar(owner, name)` on toolkit main.
    ///
    /// For `.mintProxy` credentials the request goes to the customer proxy's
    /// matching endpoint (e.g. `https://my-app.com/mint-proxy/v1/avatars/
    /// {owner}/{name}`); the proxy forwards to the gateway with sk_. For
    /// `._rawSecretKey` it goes to the gateway directly.
    public func getAvatar(owner: String, name: String) async throws -> TwaiAPI.AvatarResult {
        // URL-encode owner / name defensively — allow typical handle chars.
        let allowed = CharacterSet.urlPathAllowed
        let o = owner.addingPercentEncoding(withAllowedCharacters: allowed) ?? owner
        let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name

        let endpoint: URL
        switch credentials {
        case .mintProxy(let proxyURL, _):
            // Mint-proxy base is the sessions endpoint; derive the sibling.
            // Convention: strip trailing /v1/sessions, append /v1/avatars/.../...
            let base = proxyURL.deletingLastPathComponent().deletingLastPathComponent()
            endpoint = base.appendingPathComponent("/v1/avatars/\(o)/\(n)")
        case ._rawSecretKey:
            endpoint = gatewayBaseURL.appendingPathComponent("/v1/avatars/\(o)/\(n)")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in credentials.headers() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await perform(request: request)
        return try decode(TwaiAPI.AvatarResult.self, from: data, response: response)
    }

    // MARK: - Internals

    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TwaiError.transport(message: "Non-HTTP response from \(request.url?.absoluteString ?? "")", underlying: nil)
            }
            return (data, http)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw TwaiError.timeout(message: "Request timed out: \(request.url?.absoluteString ?? "")")
        } catch let urlError as URLError {
            throw TwaiError.transport(message: urlError.localizedDescription, underlying: urlError)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
        if (200..<300).contains(response.statusCode) {
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw TwaiError.unknown(kind: nil, message: "Decode failed on 2xx: \(error.localizedDescription)")
            }
        }

        // Error path — try to parse the gateway's typed error envelope.
        // Shape: `{"error": {"kind": "...", "message": "...", ...}}`
        // Declared at file scope (below): Swift forbids nesting a type inside a
        // generic function, which this is.
        if let wire = try? decoder.decode(GatewayErrorWire.self, from: data) {
            let msg = wire.error.message ?? "Gateway error (HTTP \(response.statusCode))"
            throw TwaiError.from(apiKind: wire.error.kind, message: msg, statusCode: response.statusCode)
        }

        // Unparseable body — surface a generic error.
        let body = String(data: data, encoding: .utf8) ?? ""
        let snippet = body.prefix(200)
        throw TwaiError.server(statusCode: response.statusCode, message: "HTTP \(response.statusCode): \(snippet)")
    }
}

// MARK: - Gateway error envelope

/// Typed error envelope the gateway returns on non-2xx:
/// `{"error": {"kind": "...", "message": "..."}}`.
/// File-scope because `decode(_:from:response:)` is generic and Swift does not
/// allow types to be nested in generic functions.
private struct GatewayErrorWire: Decodable {
    let error: GatewayErrorBody
}

private struct GatewayErrorBody: Decodable {
    let kind: String?
    let message: String?
}
