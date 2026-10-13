import SwiftUI
import TwaiCore
import TwaiLiveKit
import TwaiPlayer

// HelloAvatar — minimum-possible T0 Swift sample.
//
// Mint-and-play: single screen, SwiftUI, 2wai avatar over Transport 0
// (LiveKit). Point MINT_PROXY_URL at your running mint proxy (see
// apps/mint_proxy_examples/node/ in the toolkit for a reference) and
// AVATAR_ID at an avatar on your tenant.
//
// Mirrors apps/hello_avatar/ (Flutter) in shape and scope. ~70 LOC of
// load-bearing code.

@main
struct HelloAvatarApp: App {
    var body: some Scene {
        WindowGroup {
            AvatarScreen()
        }
    }
}

// MARK: - Configure these two before running

/// Your running mint proxy's /v1/sessions endpoint. See
/// apps/mint_proxy_examples/node/ in the toolkit for a reference
/// server you can point at.
private let MINT_PROXY_URL = URL(string: "https://your-mint-proxy.example.com/v1/sessions")!

/// Avatar id on your tenant. Mila's test credentials in the toolkit's
/// memory file (reference_twai_gateway_test_credentials.md) are
/// avt_441ad4d95906438490a85b79 + vc_e72e888d566aca3a4e63fbe8.
private let AVATAR_ID = "avt_441ad4d95906438490a85b79"
private let VOICE_ID = "vc_e72e888d566aca3a4e63fbe8"

// MARK: - Screen

struct AvatarScreen: View {
    @State private var handle: TwaiPlayerHandle?
    @State private var inputText: String = ""
    @State private var lastReply: String = ""

    private let api = TwaiAPIClient(
        credentials: .mintProxy(url: MINT_PROXY_URL)
    )

    var body: some View {
        VStack(spacing: 0) {
            TwaiPlayerView(mint: mint)
                .onReady { handle = $0 }

            // Simple chat composer below the avatar.
            VStack(alignment: .leading, spacing: 8) {
                if !lastReply.isEmpty {
                    Text(lastReply)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                HStack {
                    TextField("Say hi…", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        Task { await send() }
                    }
                    .disabled(handle == nil || inputText.isEmpty)
                }
                .padding()
            }
            .background(.ultraThinMaterial)
        }
        .task {
            // Observe reply events for the UI echo above.
            guard let engine = handle?.engine else { return }
            for await event in engine.events {
                if case .replyText(let text, let isFinal) = event, isFinal {
                    lastReply = text
                }
            }
        }
    }

    // Mint closure — the one function every TwaiPlayerView needs.
    private func mint() async -> TwaiMintResult {
        do {
            let session = try await api.createSession(.init(
                avatarId: AVATAR_ID,
                voiceId: VOICE_ID,
                mode: .video
            ))
            return .enabled(
                url: session.livekitUrl,
                token: session.participantToken,
                room: session.roomName
            )
        } catch TwaiError.rateLimited(let secs, _) {
            return .rateLimited(retryAfterSeconds: secs ?? 60)
        } catch {
            return .unavailable(message: "Mint failed: \(error.localizedDescription)", cause: error)
        }
    }

    private func send() async {
        guard !inputText.isEmpty else { return }
        let text = inputText
        inputText = ""
        try? await handle?.send(text)
    }
}
