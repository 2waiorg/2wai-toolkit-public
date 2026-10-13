/// LiveKit (WebRTC) transport for the 2wai Avatar SDK — Adapter 5.
///
/// Consumer surface:
///
/// ```dart
/// final rest = TwaiApiRestClient(baseUrl: proxyUrl, credentials: ...);
/// final handle = TwaiPlayerHandle.forLiveKitSession(
///   avatar: drAlman,
///   restClient: rest,
///   autoConnect: true,
/// );
/// TwaiPlayer(controller: handle, avatar: drAlman);
/// ```
///
/// Under the hood: `restClient.createSession(transport: "livekit")` gets
/// `{livekit_url, participant_token, room_name, agent_identity}` from
/// the gateway; [LiveKitChatSession] joins the room, subscribes to the
/// agent's remote audio + video tracks, and forwards the SDK's
/// [ChatSession] surface (replyText / speakingEvents / videoBytes /
/// speakBoundaries / done). [LiveKitVideoSink] adopts the remote video
/// track for rendering — LiveKit owns the WebRTC decode + display, not
/// MSE.
///
/// Port of `clg_penthouse_pets/frontend/src/lean/livekit_transport.ts`
/// (Mason's PenthouseLiveKitTransport). Same topics, same reply
/// protocol, same state machine.
library;

export 'src/reply_stream.dart' show ReplyStreamReducer, ReplyFrame, ReplyTerminalKind, stripExpressionTags;
export 'src/livekit_chat_session.dart' show LiveKitChatSession, LiveKitChatEnvelope;
export 'src/livekit_video_sink.dart' show LiveKitVideoSink;
export 'src/livekit_handle.dart' show createLiveKitHandle, liveKitSinkFactory;
