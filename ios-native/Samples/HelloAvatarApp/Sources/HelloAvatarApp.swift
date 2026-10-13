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
// The Mac's LAN mint proxy (apps/mint_proxy_examples/node, SK_KEY in its env).
// Chosen over Lumara's https proxy because it needs no bearer token — a baked
// JWT expires in ~1h and the app then dies on mint. Requires, on the phone:
// Settings > HelloAvatar > Local Network = ON, plus the ATS exception in this
// target's Info.plist (NSAllowsLocalNetworking alone does NOT cover a numeric
// LAN IP). Re-check the IP with `ipconfig getifaddr en0`.
private let MINT_PROXY_URL = URL(string: "http://192.168.1.42:8787/v1/sessions")!


/// Avatar id on your tenant. Mila's test credentials in the toolkit's
/// memory file (reference_twai_gateway_test_credentials.md) are
/// avt_441ad4d95906438490a85b79 + vc_e72e888d566aca3a4e63fbe8.
private let AVATAR_ID = "avt_4586c4366d51bfa70c0df7cd"  // Dr. Alman (Lumara tenant)
/// Dr. Alman's idle loop (mouth closed, subtle motion) — the same asset the
/// Flutter apps use. Drawn under the live track and shown between turns.
private let IDLE_URL = "https://2waiassets.blob.core.windows.net/avatars/BrianAlman/Default/Idles/BrianAlman_Idle1.mp4"
private let VOICE_ID = "vc_177ec070b504c0a701948fa6"   // brian-alman-ft

// MARK: - Conversation phase
//
// A conversational avatar has turn structure, and a demo has to SHOW it:
//
//   connecting -> greeting -> idle -> (you ask) thinking -> answering -> idle
//
// The server streams one continuous video track (idle frames between
// utterances), so "idle" is a conversation state this client tracks from
// engine events — not a separate video asset to load.
enum Phase: String {
    case connecting = "Connecting…"
    case greeting   = "Greeting"
    case idle       = "Idle — ask me something"
    case thinking   = "Thinking…"
    case answering  = "Answering"
    case failed     = "Failed"

    var isInteractive: Bool { self == .idle }
}

struct Turn: Identifiable {
    let id = UUID()
    let speaker: String
    let text: String
    var isYou: Bool { speaker == "You" }
}

// MARK: - Screen

struct AvatarScreen: View {
    @State private var handle: TwaiPlayerHandle?
    @State private var inputText: String = ""
    @State private var phase: Phase = .connecting
    @State private var transcript: [Turn] = []
    @State private var greetingSent = false
    @State private var idleFallback: Task<Void, Never>?

    private let api = TwaiAPIClient(
        credentials: .mintProxy(url: MINT_PROXY_URL)
    )

    /// Programmatic greeting primer: if an avatar has no pre-rendered intro
    /// video, send a short "opener" message once on ready and let the LLM
    /// generate the actual spoken greeting.
    private let greetingPrimer = "Greet me briefly and ask what I'd like to talk about."

    var body: some View {
        VStack(spacing: 0) {
            // Avatar gets the lion's share of the screen and stays centred.
            TwaiPlayerView(mint: mint, idleURL: URL(string: IDLE_URL))
                .onReady { handle = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
            // Only take space once there is something to show — an empty
            // fixed-height list reads as a broken black void.
            if !transcript.isEmpty {
                transcriptList
            }
            composer
        }
        // Keyed on handle identity: the engine does not exist until onReady
        // fires, so a plain `.task` would run once with `handle == nil` and
        // observe nothing.
        .task(id: handle == nil) {
            await observeEngine()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phase.isInteractive ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(phase.rawValue).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var transcriptList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(transcript) { turn in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.speaker)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(turn.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 160)
    }

    private var composer: some View {
        HStack {
            // Input is gated on the ENGINE being ready, never on `phase`:
            // `phase` is driven by agent-sent speaking events, and if those
            // don't arrive the composer would be disabled forever.
            TextField("Ask Dr. Alman…", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .disabled(handle == nil)
            Button("Send") { Task { await send() } }
                .disabled(handle == nil || inputText.isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Conversation loop

    private func observeEngine() async {
        guard let engine = handle?.engine else { return }
        for await event in engine.events {
            switch event {
            case .ready:
                // Greet once per launch, so every run of the demo opens with a
                // real greeting turn. Set a persisted scope key instead if you
                // want greet-once-forever (see TwaiGreeting.text onceForever).
                if !greetingSent {
                    greetingSent = true
                    phase = .greeting
                    scheduleIdleFallback()
                    await sendWithWarmupRetry(greetingPrimer, speaker: nil)
                }

            case .speaking(let active):
                phase = active ? .answering : .idle
                if active { scheduleIdleFallback() } else { idleFallback?.cancel() }

            case .replyText(let text, let isFinal):
                if isFinal { appendOrReplaceAgent(text) }

            case .replyDone:
                phase = .idle

            case .agentState(let state):
                // Authoritative turn state from the agent (lk.agent.state).
                switch state {
                case "speaking":            phase = .answering
                case "thinking":            phase = .thinking
                case "listening":           phase = .idle; idleFallback?.cancel()
                default:                    break
                }

            case .failed(let message, _):
                phase = .failed
                transcript.append(Turn(speaker: "Error", text: message))

            case .disconnected:
                phase = .connecting

            default:
                break
            }
        }
    }

    /// Falls the phase back to idle if the agent never reports `speaking stop`
    /// or a reply `end`. Display-only safety net so the UI can't look stuck.
    private func scheduleIdleFallback(after seconds: Double = 12) {
        idleFallback?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if phase == .greeting || phase == .answering || phase == .thinking {
                phase = .idle
            }
        }
        idleFallback = task
    }

    private func appendOrReplaceAgent(_ text: String) {
        if let last = transcript.last, !last.isYou {
            transcript[transcript.count - 1] = Turn(speaker: "Dr. Alman", text: text)
        } else {
            transcript.append(Turn(speaker: "Dr. Alman", text: text))
        }
    }

    /// `TwaiEngine.send` rejects for ~2s after `.ready` (SEND_GRACE_MS warm-up).
    /// A fire-and-forget send inside that window is silently dropped, which
    /// looks exactly like a broken avatar: connected, video playing, and an
    /// all-zero audio stream because the agent was never asked to say anything.
    /// Retry until the grace window passes, and surface anything else.
    private func sendWithWarmupRetry(_ text: String, speaker: String?) async {
        for attempt in 1...12 {
            do {
                try await handle?.send(text)
                return
            } catch let err as TwaiError {
                if case .unknown(let kind, _) = err, kind == "session_warming" || kind == "session_not_ready" {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                transcript.append(Turn(speaker: "Error", text: "send failed: \(err)"))
                phase = .idle
                return
            } catch {
                transcript.append(Turn(speaker: "Error", text: "send failed: \(error.localizedDescription)"))
                phase = .idle
                return
            }
            _ = attempt
        }
        transcript.append(Turn(speaker: "Error", text: "agent never left warm-up; send abandoned"))
        phase = .idle
    }

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        transcript.append(Turn(speaker: "You", text: text))
        phase = .thinking
        scheduleIdleFallback()
        await sendWithWarmupRetry(text, speaker: "You")
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

}
