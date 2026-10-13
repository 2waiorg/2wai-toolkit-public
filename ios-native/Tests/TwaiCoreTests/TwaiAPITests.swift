import XCTest
@testable import TwaiCore

final class TwaiAPITests: XCTestCase {

    // MARK: - Codable round-trips

    func testAvatarResultDecodesWireShape() throws {
        let json = """
        {
          "avatar": {
            "owner": "alman",
            "name": "dr-alman",
            "display_name": "Dr. Alman",
            "avatar_id": "avt_4586c4366d51bfa70c0df7cd",
            "listed": true,
            "idle_url": "https://cdn.example.com/alman/idle.mp4",
            "poster_url": "https://cdn.example.com/alman/poster.jpg",
            "greeting": {
              "id": "grt_123",
              "video_url": "https://cdn.example.com/alman/intro.mp4",
              "text": "Hi, I'm Dr. Alman.",
              "kind": "intro",
              "consumption_key": null
            }
          },
          "view_token": null
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(TwaiAPI.AvatarResult.self, from: json)
        XCTAssertEqual(result.avatar.owner, "alman")
        XCTAssertEqual(result.avatar.name, "dr-alman")
        XCTAssertEqual(result.avatar.displayName, "Dr. Alman")
        XCTAssertEqual(result.avatar.avatarId, "avt_4586c4366d51bfa70c0df7cd")
        XCTAssertTrue(result.avatar.listed)
        XCTAssertEqual(result.avatar.greeting?.kind, .intro)
        XCTAssertEqual(result.avatar.greeting?.id, "grt_123")
        XCTAssertNil(result.avatar.greeting?.consumptionKey)
    }

    func testSessionResponseDecodesT0Shape() throws {
        let json = """
        {
          "session_id": "ses_abc123",
          "transport": "livekit",
          "livekit_url": "wss://2wai.livekit.cloud",
          "participant_token": "eyJhbGciOi...",
          "room_name": "sess_abc123",
          "agent_identity": "livealman-agent-xyz"
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(TwaiAPI.SessionResponse.self, from: json)
        XCTAssertEqual(session.sessionId, "ses_abc123")
        XCTAssertEqual(session.transport, "livekit")
        XCTAssertEqual(session.agentIdentity, "livealman-agent-xyz")
    }

    func testSessionRequestEncodesSnakeCase() throws {
        let req = TwaiAPI.SessionRequest(avatarId: "avt_x", voiceId: "vc_y", mode: .video)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["avatar_id"] as? String, "avt_x")
        XCTAssertEqual(dict?["voice_id"] as? String, "vc_y")
        XCTAssertEqual(dict?["mode"] as? String, "video")
        XCTAssertEqual(dict?["transport"] as? String, "livekit")
    }

    // MARK: - Error ladder

    func testErrorFromKindMaps() {
        XCTAssertEqual(TwaiError.from(apiKind: "no_such_avatar", message: "x", statusCode: 404).errorDescription, "x")
        if case .noSuchAvatar = TwaiError.from(apiKind: "no_such_avatar", message: "x", statusCode: 404) {} else {
            XCTFail("Expected noSuchAvatar")
        }
        if case .catalogHydrateNotConfigured = TwaiError.from(apiKind: "catalog_hydrate_not_configured", message: "pending", statusCode: 503) {} else {
            XCTFail("Expected catalogHydrateNotConfigured")
        }
    }

    func testErrorFromUnknownKind500GoesToServer() {
        if case .server(let code, _) = TwaiError.from(apiKind: "something_new", message: "x", statusCode: 500) {
            XCTAssertEqual(code, 500)
        } else {
            XCTFail("Expected .server for 5xx with unknown kind")
        }
    }

    // MARK: - Credentials shape

    func testMintProxyCredentialsCarryExtraHeaders() {
        let creds: TwaiCredentials = .mintProxy(
            url: URL(string: "https://p.example/v1/sessions")!,
            headers: ["X-App": "HelloAvatar"]
        )
        XCTAssertEqual(creds.headers()["X-App"], "HelloAvatar")
        XCTAssertNil(creds.headers()["Authorization"], "mint-proxy should NOT attach Authorization client-side")
    }

    func testRawSecretKeyCredentialsAttachAuthorization() {
        let creds: TwaiCredentials = ._rawSecretKey("sk_test_1234")
        XCTAssertEqual(creds.headers()["Authorization"], "Bearer sk_test_1234")
    }
}
