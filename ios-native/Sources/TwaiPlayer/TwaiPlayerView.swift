import AVFoundation
import SwiftUI
import LiveKit
import TwaiCore
import TwaiLiveKit

/// SwiftUI view that renders a 2wai avatar over Transport 0 (LiveKit).
///
/// Owns a `TwaiEngine`, calls the mint closure on appear, subscribes to
/// the agent's video track, renders it, and surfaces events through
/// modifiers like `.onReady` and `.onReplyText`.
///
/// Minimal usage (the Flow 1 example from the plan doc):
///
/// ```swift
/// struct AvatarScreen: View {
///     @State private var handle: TwaiPlayerHandle?
///
///     var body: some View {
///         TwaiPlayerView(mint: {
///             // ... your mint closure, see TwaiMintClosure docs
///         })
///         .onReady { handle = $0 }
///         .task {
///             try? await handle?.send("Hi — tell me what you can do.")
///         }
///     }
/// }
/// ```
public struct TwaiPlayerView: View {

    private let mint: TwaiMintClosure
    private let onReadyCallback: ((TwaiPlayerHandle) -> Void)?

    /// Looping idle video shown whenever the avatar is NOT speaking.
    ///
    /// On Transport 0 the LiveKit track carries the SPEAKING render only; the
    /// client owns the idle loop. Without this the avatar appears to talk
    /// forever, because the last speaking frame is all there is to show.
    /// Mirrors the Flutter player's `idleBuilder` / `NetworkVideoIdle`.
    private let idleURL: URL?

    @StateObject private var engine: TwaiEngine
    @State private var handle: TwaiPlayerHandle?

    /// - mint: how to obtain a LiveKit session. See `TwaiMintClosure`.
    /// - idleURL: looping idle video, drawn underneath the live track and
    ///   revealed whenever the avatar is not speaking. On Transport 0 the
    ///   LiveKit track carries only the SPEAKING render, so without this the
    ///   avatar appears to talk forever.
    /// - onReady: fires once when the engine reaches `.ready` state, with
    ///   a handle for imperative control. Prefer the `.onReady` modifier.
    public init(
        mint: @escaping TwaiMintClosure,
        idleURL: URL? = nil,
        onReady: ((TwaiPlayerHandle) -> Void)? = nil
    ) {
        self.mint = mint
        self.idleURL = idleURL
        self.onReadyCallback = onReady
        self._engine = StateObject(wrappedValue: TwaiEngine(mint: mint))
    }

    public var body: some View {
        ZStack {
            // Background — black while connecting / disconnected.
            Color.black.ignoresSafeArea()

            // Idle layer — always drawn, underneath everything. When the
            // speaking layer is transparent this is what the viewer sees.
            if let idleURL {
                LoopingVideoView(url: idleURL)
                    .allowsHitTesting(false)
            }

            // Speaking layer — the WebRTC track. Kept MOUNTED once a track
            // exists (opacity-gated, not conditionally removed) so the
            // subscription is never torn down and re-established per turn.
            if let agent = agentParticipant(), let track = firstVideoTrack(for: agent) {
                // `.fit` (not the SDK default `.fill`): the agent renders a
                // landscape frame, and `.fill` crops it to the container —
                // on a portrait phone that slices the avatar's head off and
                // pushes them off-centre. `.fit` letterboxes instead, so the
                // avatar stays whole and centred whatever the container is.
                SwiftUIVideoView(track, layoutMode: .fit)
                    .opacity(engine.isSpeaking ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: engine.isSpeaking)
            }

            // Simple state overlay for v0.1 — Flutter has a richer
            // connection overlay widget; here we show a text status until
            // the agent's video track lands.
            if engine.state != .ready {
                statusOverlay
            }
        }
        .task {
            engine.connect()
        }
        .onDisappear {
            Task { await engine.disconnect() }
        }
        .onChange(of: engine.state) { newState in
            if case .ready = newState, handle == nil {
                let h = TwaiPlayerHandle(engine: engine)
                handle = h
                onReadyCallback?(h)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 12) {
            switch engine.state {
            case .idle, .connecting:
                ProgressView().progressViewStyle(.circular).tint(.white)
                Text("Connecting…").foregroundStyle(.white)
            case .rateLimited(let secs):
                Text("Rate limited — retry in \(secs)s").foregroundStyle(.white)
            case .failed(let msg):
                Text("Error: \(msg)")
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            case .disconnected:
                Text("Disconnected").foregroundStyle(.white)
            case .ready:
                EmptyView()
            }
        }
    }

    private func agentParticipant() -> RemoteParticipant? {
        // The 2wai agent participant's identity starts with "livealman-agent-"
        // on Dr. Alman, or similar per broker profile. Match on remote-
        // participant presence — in v0.1 we expect exactly one remote.
        return engine.liveKitRoom.remoteParticipants.values.first
    }

    private func firstVideoTrack(for participant: RemoteParticipant) -> VideoTrack? {
        // `videoTracks` is an array of publications in the LiveKit Swift SDK
        // (the Dart SDK exposes a map), so iterate it directly.
        for publication in participant.videoTracks {
            if let track = publication.track as? VideoTrack {
                return track
            }
        }
        return nil
    }
}

// MARK: - Modifiers

extension TwaiPlayerView {
    /// Grab a handle to the engine once it reaches `.ready`. Fires once.
    public func onReady(_ callback: @escaping (TwaiPlayerHandle) -> Void) -> TwaiPlayerView {
        return TwaiPlayerView(
            mint: self.mint,
            idleURL: self.idleURL,
            onReady: callback
        )
    }
}

// MARK: - Idle loop

/// Seamlessly looping video, used for the avatar's idle layer.
/// `AVPlayerLooper` + `AVQueuePlayer` gives gapless repeat; muted because the
/// idle asset carries no speech and must never contend with the live track.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(url: url)
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {}
}

final class LoopingPlayerUIView: UIView {
    private var looper: AVPlayerLooper?
    private let queuePlayer = AVQueuePlayer()

    override static var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(url: URL) {
        super.init(frame: .zero)
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.isMuted = true
        // Match the speaking layer's `.fit` so the avatar doesn't jump
        // position or scale when the layers swap.
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = queuePlayer
        queuePlayer.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}
