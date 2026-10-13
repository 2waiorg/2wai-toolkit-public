import Foundation
import AVFoundation
import LiveKit
import TwaiCore

/// The Transport 0 engine for TwaiAvatarKit.
///
/// Owns a LiveKit `Room`, calls the consumer's mint closure, joins the
/// room, subscribes the agent's video + audio tracks, and surfaces chat
/// via LiveKit's data channel.
///
/// Ported from `packages/twai_avatar_sdk_livekit/lib/src/transport0/
/// engine.dart` on the Flutter toolkit. Not a line-for-line port — Swift
/// has `AsyncStream` + actors where Dart has `Stream` + `async*`, so the
/// shape differs. Behavior is intended to be equivalent: same connect
/// flow, same send envelope, same event ladder, same reconnect handling.
///
/// Usage pattern — consumers typically mount `TwaiPlayerView` which
/// owns an instance of this; you only touch `TwaiEngine` directly when
/// you want imperative control from outside a SwiftUI view tree.
@MainActor
public final class TwaiEngine: ObservableObject, @unchecked Sendable {

    // MARK: - Observable state

    /// Rolled-up state for simple UI binding (`@StateObject var engine`).
    @Published public private(set) var state: TwaiEngineState = .idle

    /// Latest avatar-speaking flag — true while the agent audio track is active.
    @Published public private(set) var isSpeaking: Bool = false

    /// Latest completed reply text (reset on each new user turn).
    @Published public private(set) var lastReplyText: String = ""

    // MARK: - Full event stream

    /// Every engine event, in order. Use this when you need more than the
    /// rolled-up state (e.g. per-frame reply chunks, agent-state hints).
    public var events: AsyncStream<TwaiEngineEvent> { eventStream }

    // MARK: - Internals

    private let mint: TwaiMintClosure
    private let room: Room

    /// Read-only access to the underlying LiveKit room, for views that need to
    /// mount its video tracks. Named `liveKitRoom` rather than `room` because
    /// `RoomDelegate` already puts `room(_:...)` methods in this type's scope —
    /// a property called `room` would be shadowed by them at the call site.
    public var liveKitRoom: Room { room }
    private let eventStream: AsyncStream<TwaiEngineEvent>
    private let eventContinuation: AsyncStream<TwaiEngineEvent>.Continuation
    private var connectTask: Task<Void, Never>?
    private var currentTurnId: String?

    // SEND_GRACE_MS from the Flutter engine — 2-4s warm-up after .ready
    // where the agent is still priming TTS. send() during this window
    // throws SessionNotReady; UI should disable Send until state == .ready
    // AND this grace has elapsed. See reference_t0_send_timing in memory.
    // Transport 0 interaction contract — ported from the Dart engine
    // (transport0/engine.dart + session_data.dart). Four channels, not one:
    //
    //   SEND     text stream  `lk.chat`          user turn (JSON envelope)
    //   RECEIVE  data packet  `livealman`        {type:"speaking", value:"start"|"stop"}
    //   RECEIVE  data packet  `2wai.reply`       ReplyFrame {v,reply_id,seq,kind,text?}
    //   RECEIVE  data packet  `2wai.control`     control events
    //   RECEIVE  text stream  `lk.transcription` fallback transcription
    //
    // Speaking state comes from the `livealman` topic — NOT LiveKit's
    // audio-level `didUpdateSpeakingParticipants`, which is energy-based and
    // flaps, so the avatar never settles back to idle.
    private static let topicChat = "lk.chat"
    private static let topicSpeaking = "livealman"
    private static let topicReply = "2wai.reply"
    private static let topicControl = "2wai.control"

    private static let sendGraceSeconds: TimeInterval = 2.0
    private var readyAt: Date?
    private var currentReplyId: String?
    private var replyBuffer: String = ""



    public init(mint: @escaping TwaiMintClosure) {
        self.mint = mint

        // Mandatory LiveKit options for Transport 0 — adaptiveStream MUST
        // be false (per LiveKit Swift SDK + the Flutter engine's note:
        // adaptiveStream drops the video track during our idle periods
        // which breaks the T0 session). dynacast off for the same reason.
        let roomOptions = RoomOptions(
            adaptiveStream: false,
            dynacast: false
        )
        self.room = Room(roomOptions: roomOptions)

        var cont: AsyncStream<TwaiEngineEvent>.Continuation!
        self.eventStream = AsyncStream { c in cont = c }
        self.eventContinuation = cont

        self.room.add(delegate: self)
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Public API

    /// Call mint, connect to the LiveKit room, wait for the agent.
    public func connect() {
        guard connectTask == nil else { return }
        connectTask = Task { [weak self] in
            await self?.doConnect()
        }
    }

    /// Disconnect from the LiveKit room. Idempotent.
    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        try? await room.disconnect()
        releaseReceiveOnlyPlayout()
        state = .disconnected
        emit(.disconnected)
    }

    /// Send a user text turn. Throws `TwaiError.unknown` if the engine
    /// isn't ready or is still in the SEND_GRACE_MS warm-up window.
    public func send(_ text: String, extra: [String: String]? = nil) async throws {
        guard state == .ready else {
            throw TwaiError.unknown(kind: "session_not_ready", message: "Engine state is \(state); send only when .ready")
        }
        if let r = readyAt, Date().timeIntervalSince(r) < Self.sendGraceSeconds {
            throw TwaiError.unknown(kind: "session_warming", message: "Agent still warming up (SEND_GRACE_MS); try again in a moment")
        }

        let envelope = TwaiChatEnvelope(text: text, extra: extra)
        currentTurnId = envelope.turnId
        let payload = try JSONEncoder().encode(envelope)

        // MUST be the text-stream API, not publish(data:).
        //
        // The agent subscribes to the `lk.chat` TEXT STREAM. A legacy data
        // packet on the same topic is never delivered to it, so the turn is
        // silently dropped: the room stays healthy, the avatar keeps streaming
        // its idle loop, and the remote audio track carries real (silent)
        // samples. It looks exactly like "iOS audio is broken" and is not.
        //
        // The Dart engine does the same thing — engine.dart `send()`:
        //   localParticipant.sendText(jsonEncode(envelope),
        //                             options: SendTextOptions()..topic = _topicChat)
        guard let json = String(data: payload, encoding: .utf8) else {
            throw TwaiError.unknown(kind: "encode_failed", message: "Could not encode chat envelope")
        }
        _ = try await room.localParticipant.sendText(json, for: Self.topicChat)
    }

    // MARK: - Connect flow

    private func doConnect() async {
        state = .connecting
        emit(.connecting)

        let mintResult = await mint()
        switch mintResult {
        case .rateLimited(let secs):
            state = .rateLimited(retryAfterSeconds: secs)
            emit(.rateLimited(retryAfterSeconds: secs))
            return

        case .unavailable(let msg, let cause):
            state = .failed(message: msg)
            emit(.failed(message: msg, underlying: cause))
            return

        case .enabled(let url, let token, _):
            self.ensureReceiveOnlyPlayout()
            do {
                try await self.room.connect(
                    url: url.absoluteString,
                    token: token
                )
                // `lk.transcription` text stream — the Dart engine registers
                // this and funnels it into the same reply surface. Agents emit
                // reply text here; without it the client sees no reply at all.
                do {
                    try await self.room.registerTextStreamHandler(for: "lk.transcription") { [weak self] reader, participantIdentity in
                        Task { @MainActor in
                            var assembled = ""
                            do {
                                for try await chunk in reader {
                                    assembled += chunk
                                    self?.emit(.replyText(text: assembled, isFinal: false))
                                }
                            } catch {
                            }
                            if !assembled.isEmpty {
                                self?.lastReplyText = assembled
                                self?.emit(.replyText(text: assembled, isFinal: true))
                                self?.emit(.replyDone(turnId: nil))
                            }
                        }
                    }
                } catch {
                }
                // Room-join succeeded — ready fires once we see the agent
                // participant appear + its audio/video tracks subscribe.
                // See roomDidUpdateConnectionState delegate below.
            } catch {
                state = .failed(message: "LiveKit connect failed: \(error.localizedDescription)")
                emit(.failed(message: "LiveKit connect failed", underlying: error))
            }
        }
    }

    /// iOS/visionOS/tvOS: pin the `AVAudioSession` to a media-playback shape
    /// before connecting.
    ///
    /// Every session this SDK opens is **receive-only** — the client subscribes
    /// to the agent's audio + video and never publishes a microphone track.
    /// LiveKit's dynamic audio-session logic derives its configuration from the
    /// engine's track state, and with no local track it does not land on a
    /// playback-shaped session, so decoded remote audio has an active track but
    /// no active output: the avatar's lips move in silence on a real iPhone.
    ///
    /// Setting `AudioManager.shared.sessionConfiguration` takes precedence over
    /// that dynamic logic (it is ignored only if `customConfigureAudioSessionFunc`
    /// is set, which this SDK never sets). `.playback` is
    /// `.playback` + `[.mixWithOthers]` + `.spokenAudio` — the same shape the
    /// Flutter toolkit's working runs log as
    /// `AVAudioSessionCategoryPlayback` / `mixWithOthers` / `ModeSpokenAudio`.
    ///
    /// Deliberately NOT touching `isSpeakerOutputPreferred`: forcing speaker
    /// output corrupts the native audio config on reconnect (`OSStatus -50`) —
    /// see `docs/mic_lifecycle_ios_livekit.md`. The `.playback` category already
    /// routes to the speaker.
    ///
    /// Applied once per process; `AudioManager` is a singleton.
    ///
    /// NOTE for v0.2 (mic): once a local mic track exists this must become a
    /// save/restore around recognition rather than a one-shot, mirroring
    /// `packages/twai_speech_to_text_patched`.
    /// iOS/visionOS/tvOS: make a **receive-only** session actually audible.
    ///
    /// Two separate things are required, and having only the first is the
    /// silent-avatar failure:
    ///
    /// 1. **Session shape** — `AudioManager.shared.sessionConfiguration = .playback`
    ///    (`.playback` + `[.mixWithOthers]` + `.spokenAudio`). This takes
    ///    precedence over LiveKit's dynamic logic, which never lands on a
    ///    playback shape when there is no local track.
    ///
    /// 2. **A playout requirement** — `acquireSessionRequirement(.playbackOnly)`.
    ///    LiveKit activates the `AVAudioSession` and starts the audio engine
    ///    only while some component holds a playout or recording requirement,
    ///    and those requirements are derived from *published* tracks. A
    ///    subscriber-only client publishes nothing, so nothing ever asks for
    ///    playout: the session is configured correctly, reports
    ///    `category=Playback / mode=SpokenAudio / route=Speaker`, the remote
    ///    audio track subscribes unmuted — and no samples are ever rendered.
    ///    This is the same API LiveKit's own `SoundPlayer` uses to play audio
    ///    without a call. The handle must be **retained**; releasing it drops
    ///    the requirement and stops playout.
    ///
    /// Deliberately NOT touching `isSpeakerOutputPreferred`: forcing speaker
    /// output corrupts native audio config on reconnect (`OSStatus -50`) — see
    /// `docs/mic_lifecycle_ios_livekit.md`. `.playback` already routes to speaker.
    ///
    /// v0.2 (mic): once a local mic track exists, this becomes a save/restore
    /// around recognition, mirroring `packages/twai_speech_to_text_patched`.

    /// Configure the iOS audio session for a receive-only avatar.
    ///
    /// On the pinned pre-rewrite `client-sdk-swift` (2.3.x) LiveKit does NOT
    /// configure the `AVAudioSession` itself — it leaves it at the system
    /// default `.soloAmbient`/`.default`, which renders nothing. In the Flutter
    /// toolkit `flutter_webrtc` performs this step; in pure Swift there is no
    /// equivalent, so the host SDK must do it.
    ///
    /// The category/mode/options below are the configuration validated for 2wai
    /// avatars on iPhone — `docs/sdk_overview.md`:
    ///   `.playAndRecord` / `.default` / `[.defaultToSpeaker, .allowBluetooth, .mixWithOthers]`
    ///
    /// `.defaultToSpeaker` is load-bearing: without it iOS routes playback to
    /// the EARPIECE at near-silent volume.
    private func ensureReceiveOnlyPlayout() {
        #if os(iOS) || os(visionOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
        if #available(iOS 26.0, *) {
            options.insert(.allowBluetoothHFP)
        } else {
            options.insert(.allowBluetooth)
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setActive(true)
        } catch {
        }
        #endif
    }

    private func releaseReceiveOnlyPlayout() {
        // No-op on the pinned 2.3.x SDK: it has no session-requirement API, and
        // flutter_webrtc-era audio management needs no teardown hook here.
    }

    /// Routes an agent data packet by topic. Mirrors `session_data.dart`
    /// `receiveData`, including the agent-identity gate.
    fileprivate func routeAgentData(topic: String, data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        switch topic {
        case Self.topicSpeaking:
            if json["type"] as? String == "speaking", let value = json["value"] as? String {
                markSpeaking(value == "start")
            }

        case Self.topicReply:
            applyReplyFrame(json)

        case Self.topicControl:
            emit(.agentState(String(describing: json)))

        default:
            break
        }
    }

    /// `ReplyFrame` assembly — `{v:1, reply_id, seq, kind, text?}` with
    /// kind ∈ {start, delta, end, cancel, error}. `delta` carries incremental
    /// text; `end`/`cancel`/`error` close the turn.
    private func applyReplyFrame(_ json: [String: Any]) {
        guard json["v"] as? Int == 1,
              let replyId = json["reply_id"] as? String, !replyId.isEmpty,
              let seq = json["seq"] as? Int, seq >= 0,
              let kind = json["kind"] as? String
        else { return }

        switch kind {
        case "start":
            currentReplyId = replyId
            replyBuffer = ""

        case "delta":
            if let text = json["text"] as? String {
                if currentReplyId != replyId { currentReplyId = replyId; replyBuffer = "" }
                replyBuffer += text
                lastReplyText = replyBuffer
                emit(.replyText(text: replyBuffer, isFinal: false))
            }

        case "end", "cancel", "error":
            if let text = json["text"] as? String, !text.isEmpty { replyBuffer = text }
            if !replyBuffer.isEmpty {
                lastReplyText = replyBuffer
                emit(.replyText(text: replyBuffer, isFinal: true))
            }
            emit(.replyDone(turnId: replyId))
            currentReplyId = nil
            replyBuffer = ""

        default:
            break
        }
    }

    private func emit(_ event: TwaiEngineEvent) {
        eventContinuation.yield(event)
    }

    fileprivate func markReady() {
        state = .ready
        readyAt = Date()
        emit(.ready)
    }

    fileprivate func markSpeaking(_ active: Bool) {
        isSpeaking = active
        emit(.speaking(active: active))
    }

    fileprivate func handleIncomingData(_ data: Data) {
        // Try to decode as a TwaiReplyFrame — the only data-channel shape
        // we expect over `lk.chat` from the agent.
        guard let frame = try? JSONDecoder().decode(TwaiReplyFrame.self, from: data) else {
            // Unknown data payload — ignore but don't crash.
            return
        }

        if let text = frame.text, !text.isEmpty {
            lastReplyText = text
            emit(.replyText(text: text, isFinal: frame.isFinal))
        }

        if frame.isFinal {
            emit(.replyDone(turnId: frame.turnId ?? currentTurnId))
        }
    }
}

// MARK: - LiveKit RoomDelegate

extension TwaiEngine: RoomDelegate {

    nonisolated public func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldValue: ConnectionState) {
        Task { @MainActor in
            if connectionState == .connected && oldValue != .connected {
                // Participant discovery happens on another delegate; room
                // connection alone doesn't mean ready. Hold here until the
                // agent's tracks subscribe.
            }
            if connectionState == .disconnected {
                self.state = .disconnected
                self.emit(.disconnected)
            }
        }
    }

    nonisolated public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        // Agent appeared. Readiness is really "video/audio tracks subscribed"
        // but a connected participant is the trigger that readiness is close.
        // The track-subscribe delegate below is what flips state → .ready.
    }

    nonisolated public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if publication.kind == .audio {
                // Remote audio is auto-attached by the SDK's own pipeline; log
                // the state so a silent avatar can be told apart from a missing
                // or muted track.
                #if os(iOS) || os(visionOS) || os(tvOS)
                // Read the ACTUAL AVAudioSession, not LiveKit's intent — a
                // configured-but-inactive session is exactly the receive-only
                // silent-audio failure.
                let avs = AVAudioSession.sharedInstance()
                #else
                #endif
            }
            // When we see the agent's video track subscribe, we're ready.
            if publication.kind == .video {
                self.markReady()
            }
        }
    }

    /// `lk.agent.state` — the LiveKit Agents convention, and the ONLY turn
    /// signal this broker emits. Values: `initializing`, `listening`,
    /// `thinking`, `speaking`.
    ///
    /// This profile sends no data packets at all (verified on device: zero
    /// packets on `livealman` / `2wai.reply` / `2wai.control`), so speaking
    /// start/stop must come from here. Without it the avatar appears to talk
    /// forever because nothing ever reports the turn ending.
    nonisolated public func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard let state = attributes["lk.agent.state"] else { return }
        Task { @MainActor in
            self.emit(.agentState(state))
            // `speaking` is the only state where the avatar is mid-utterance;
            // everything else (listening/thinking/initializing) is not.
            self.markSpeaking(state == "speaking")
        }
    }

    nonisolated public func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        Task { @MainActor in
            self.routeAgentData(topic: topic, data: data)
        }
    }

}
