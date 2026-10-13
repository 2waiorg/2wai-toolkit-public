import Foundation

/// Wire-shape types for the twai-api gateway's `/v1/*` surface.
///
/// Mirrors the Dart `TwaiApiAvatar{,Result,GreetingPayload}` and the
/// TypeScript SDK's shapes. Codable so you can `JSONDecoder().decode(...)`
/// a gateway response directly. All field names use `snake_case` keys
/// matching the wire; Swift property names stay `camelCase` via
/// `CodingKeys`.
///
/// All types nested under `TwaiAPI` namespace so a consumer calling
/// `TwaiAPIClient.getAvatar(...)` writes `TwaiAPI.AvatarResult`, not a
/// top-level polluted `TwaiAvatarResult`.
public enum TwaiAPI {

    // MARK: - Session mint

    /// Request body for `POST /v1/sessions`.
    public struct SessionRequest: Codable, Sendable {
        public var avatarId: String
        public var voiceId: String?
        public var mode: SessionMode
        public var transport: String  // Always "livekit" in v0.1

        public init(
            avatarId: String,
            voiceId: String? = nil,
            mode: SessionMode = .video,
            transport: String = "livekit"
        ) {
            self.avatarId = avatarId
            self.voiceId = voiceId
            self.mode = mode
            self.transport = transport
        }

        enum CodingKeys: String, CodingKey {
            case avatarId = "avatar_id"
            case voiceId = "voice_id"
            case mode
            case transport
        }
    }

    public enum SessionMode: String, Codable, Sendable {
        case video
        case audio
    }

    /// Response from `POST /v1/sessions` on Transport 0.
    public struct SessionResponse: Codable, Sendable {
        public let sessionId: String
        public let transport: String
        public let livekitUrl: URL
        public let participantToken: String
        public let roomName: String
        public let agentIdentity: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case transport
            case livekitUrl = "livekit_url"
            case participantToken = "participant_token"
            case roomName = "room_name"
            case agentIdentity = "agent_identity"
        }
    }

    // MARK: - Catalog hydrate (NEW 2026-10-06)

    /// Request + response shape for `GET /v1/avatars/{owner}/{name}`.
    ///
    /// Mirrors the Dart `TwaiApiAvatarResult`. The outer object wraps the
    /// avatar record + an optional view_token (unused today on T0 since the
    /// `sk_` is the auth; present on the wire for future compatibility).
    public struct AvatarResult: Codable, Sendable {
        public let avatar: Avatar
        public let viewToken: String?

        enum CodingKeys: String, CodingKey {
            case avatar
            case viewToken = "view_token"
        }
    }

    /// A single avatar record from catalog hydrate.
    ///
    /// Field mapping documented in `docs/catalog_hydrate_gateway_pr.md`
    /// on toolkit main (now at `docs/internal/`).
    public struct Avatar: Codable, Sendable {
        public let owner: String
        public let name: String  // avatarname (handle, not display)
        public let displayName: String?
        public let avatarId: String  // rid
        public let listed: Bool
        public let idleUrl: URL?
        public let posterUrl: URL?
        public let greeting: GreetingPayload?

        enum CodingKeys: String, CodingKey {
            case owner
            case name
            case displayName = "display_name"
            case avatarId = "avatar_id"
            case listed
            case idleUrl = "idle_url"
            case posterUrl = "poster_url"
            case greeting
        }
    }

    /// Optional greeting payload returned with a hydrated avatar.
    ///
    /// For intro greetings (`kind: .intro`), consumption is tracked
    /// client-side (locally — don't replay the intro on every session).
    /// For return greetings (`kind: .return`), `consumptionKey` is the
    /// server-side idempotency key the client sends back on consume.
    public struct GreetingPayload: Codable, Sendable {
        public let id: String
        public let videoUrl: URL
        public let text: String
        public let kind: Kind
        public let consumptionKey: String?

        public enum Kind: String, Codable, Sendable {
            case intro
            case `return`
        }

        enum CodingKeys: String, CodingKey {
            case id
            case videoUrl = "video_url"
            case text
            case kind
            case consumptionKey = "consumption_key"
        }
    }
}
