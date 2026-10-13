import Foundation

/// Chat envelope the engine sends over LiveKit's `lk.chat` data channel.
///
/// Ported from `packages/twai_avatar_sdk_livekit/lib/src/transport0/
/// envelope.dart` on toolkit main. Byte-parallel JSON — the field names
/// are what the production brain reads today.
///
/// Shape (v1):
/// ```json
/// {
///   "type": "user_text",
///   "turn_id": "<uuid>",
///   "text": "Hi — tell me what you can do.",
///   "extra": { ... }
/// }
/// ```
public struct TwaiChatEnvelope: Codable, Sendable {
    public let type: String
    public let turnId: String
    public let text: String
    public let extra: [String: String]?

    public init(text: String, extra: [String: String]? = nil, turnId: String = UUID().uuidString) {
        self.type = "user_text"
        self.turnId = turnId
        self.text = text
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case type
        case turnId = "turn_id"
        case text
        case extra
    }
}

/// Reply envelope coming back from the agent over `lk.chat`.
///
/// The server streams multiple frames per user turn — a sequence of
/// partial text chunks terminated by a `final: true` frame. Mirrors
/// the Dart `ReplyFrame` + `ReplyStreamReducer`.
public struct TwaiReplyFrame: Codable, Sendable {
    public let type: String
    public let turnId: String?
    public let text: String?
    public let isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case turnId = "turn_id"
        case text
        case isFinal = "final"
    }
}
