/// Dart port of `clg_penthouse_pets/frontend/src/lean/livekit_transport.ts`
/// (PenthouseLiveKitTransport). Same topics, same reply protocol, same
/// warming -> renderer-ready state machine.
///
/// Fits the SDK's [ChatSession] contract. `videoBytes` and
/// `speakBoundaries` are always empty on LiveKit — the video pipe
/// is a WebRTC track (not fMP4 bytes), and there is no clause-level
/// sink signal because LiveKit owns the decoder.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

import 'reply_stream.dart';

// -----------------------------------------------------------------------
// Topic constants — same wire PP ships. Do not rename without changing
// livealman-host in lockstep.
// -----------------------------------------------------------------------
const _topicChat = 'lk.chat';
// Reserved for the `lk.transcription` fallback stream handler (PP's
// `livekit_transport.ts` registerTextStreamHandler pattern), landing
// in a follow-up slice. Kept here so the topic vocabulary stays in
// one place.
// ignore: unused_element
const _topicTranscription = 'lk.transcription';
const _topicSpeaking = 'livealman';
const _topicReply = '2wai.reply';
const _topicControl = '2wai.control';
const _agentIdentityPrefix = 'livealman-agent-';

const _sendGraceMs = 1200;
const _agentJoinTimeoutMs = 10000;
const _rendererTimeoutMs = 45000;

/// Placeholder emitted on videoBytes right after first LK video track
/// is subscribed. Purpose is purely to trigger the controller's ready
/// transition (see [_wireEvents] TrackSubscribedEvent handler for the
/// full explanation). Not a real fMP4 init segment -- LiveKit doesn't
/// use MSE sinks -- but the controller's cached-init read is gated
/// behind a check that only fires for non-web accumulate-then-play
/// sinks, so this is safely inert on the sinks that actually run
/// alongside LiveKit.
final Uint8List _readyPingBytes = Uint8List(1);

/// Envelope the client sends on `lk.chat` per turn. `v: 1` is the
/// protocol version; do not bump without a matching server change.
class LiveKitChatEnvelope {
  final String requestId;
  final String text;
  final num? gamificationLevel;
  final String? avatarStateBlock;

  const LiveKitChatEnvelope({
    required this.requestId,
    required this.text,
    this.gamificationLevel,
    this.avatarStateBlock,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'request_id': requestId,
        'text': text,
        'gamification_level': gamificationLevel,
        'avatar_state_block': avatarStateBlock,
      };
}

/// LiveKit-backed [ChatSession].
///
/// Wire flow:
///
/// 1. `connect(avatar)` -> mint via [TwaiApiRestClient.createLiveKitSession]
/// 2. `room.connect(livekit_url, participant_token)`
/// 3. Listen for agent participant + track subscribes
/// 4. When first video track arrives, wait [_sendGraceMs] then flip to
///    ready. Callers may now call [sendMessage].
/// 5. `sendMessage(text)` publishes a JSON envelope on `lk.chat`.
/// 6. Agent replies on `2wai.reply` (protocol) or `lk.transcription`
///    (fallback); [replyText] emits assembled text.
/// 7. Agent publishes speaking start/stop on `livealman`;
///    [speakingEvents] mirrors them.
/// 8. `close()` disconnects the room.
class LiveKitChatSession implements ChatSession {
  LiveKitChatSession({
    required TwaiApiRestClient restClient,
    String? userId,
  })  : _rest = restClient,
        _userId = userId;

  final TwaiApiRestClient _rest;
  final String? _userId;

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  // Note: the broker's `identity` field (surfaced as
  // mint.agentIdentity) is the VIEWER identity, not the agent's --
  // deliberately not stored. _isAgent uses the `livealman-agent-`
  // prefix contract from PP's transport instead.

  final _replyController = StreamController<String>.broadcast();
  final _speakingController = StreamController<SpeakingEvent>.broadcast();
  final _videoBytesController = StreamController<Uint8List>.broadcast();  // always empty
  final _speakBoundariesController = StreamController<void>.broadcast();   // always empty
  final _doneCompleter = Completer<ChatSessionEndReason>();
  // Currently-subscribed agent video track, as a durable state slot.
  //
  // Same discipline as Mason's `engine.ts` and `avatar-player/main.ts`:
  // both write the incoming track straight into the consumer's own
  // render surface (`element.srcObject = new MediaStream([track])`)
  // rather than event-broadcasting it. The Flutter analogue is a
  // `ValueNotifier` the consumer's `ValueListenableBuilder` wraps
  // around a `VideoTrackRenderer(track: ...)` — the widget always
  // exists, always reflects the current track, and there is no
  // subscription race. The previous broadcast-stream shape dropped
  // the track when [LiveKitVideoSink] bound after the
  // `TrackSubscribedEvent` had already fired (sink binds on the
  // ready-status transition, which fires ~1200ms AFTER the video
  // track subscribes; broadcast streams don't replay).
  final ValueNotifier<lk.RemoteVideoTrack?> _videoTrack =
      ValueNotifier<lk.RemoteVideoTrack?>(null);

  late final ReplyStreamReducer _replies = ReplyStreamReducer(
    onText: (text, _) => _replyController.add(text),
    onComplete: (text, kind, _) {
      // Emit the terminal text too — some consumers only listen to the
      // last frame. Sends idempotent updates to any subscriber that has
      // been streaming deltas the whole time.
      _replyController.add(text);
    },
  );

  bool _connected = false;
  bool _closed = false;
  bool _ready = false;
  Timer? _joinTimer;
  Timer? _rendererTimer;

  /// Currently-subscribed agent video track, as a listenable state
  /// slot. `null` when no track is active. [LiveKitVideoSink] wraps
  /// this with a `ValueListenableBuilder` around a
  /// `VideoTrackRenderer(track: ...)`; the renderer always exists and
  /// always reflects the current track, matching Mason's
  /// element-owns-srcObject discipline on the JS side.
  ValueListenable<lk.RemoteVideoTrack?> get videoTrack => _videoTrack;

  @override
  Stream<String> get replyText => _replyController.stream;

  @override
  Stream<SpeakingEvent> get speakingEvents => _speakingController.stream;

  @override
  Stream<Uint8List> get videoBytes => _videoBytesController.stream;

  @override
  Stream<void> get speakBoundaries => _speakBoundariesController.stream;

  @override
  Future<ChatSessionEndReason> get done => _doneCompleter.future;

  // -----------------------------------------------------------------------
  // connect
  // -----------------------------------------------------------------------

  @override
  Future<void> connect(Avatar avatar) async {
    if (_connected) throw const ChatSessionAlreadyConnectedException();
    _connected = true;

    // Mint the LiveKit envelope through the gateway. This is the only
    // network call the SDK owns — livealman-host coordination is on the
    // broker side.
    final TwaiApiLiveKitMint mint;
    try {
      mint = await _rest.createLiveKitSession(
        TwaiApiLiveKitSessionRequest(
          avatarId: avatar.id,
          voiceId: avatar.voiceId,
          userId: _userId,
        ),
      );
    } catch (e) {
      throw ChatSessionConnectException(
        'Failed to mint LiveKit session: $e', e,
      );
    }
    final room = lk.Room();
    _room = room;
    final listener = room.createListener();
    _listener = listener;

    _wireEvents(listener, room);

    try {
      await room.connect(mint.livekitUrl.toString(), mint.participantToken);
    } catch (e) {
      throw ChatSessionConnectException(
        'Failed to join LiveKit room: $e', e,
      );
    }

    // Agent may already be in the room. If not, wait for join.
    final hasAgent = room.remoteParticipants.values.any(_isAgent);
    if (hasAgent) {
      _armRendererTimer();
    } else {
      _armJoinTimer();
    }
  }

  bool _isAgent(lk.RemoteParticipant p) {
    // ALWAYS use the prefix contract PP ships. The broker's `identity`
    // field (which the gateway forwards as `agent_identity` in the
    // mint envelope) is actually the VIEWER's identity, not the
    // agent's -- verified against broker output at
    // http://20.230.153.80:7871/token which returns `viewer-<hex>`.
    // livealman-host/host.py:860 uses `livealman-agent-{req.id}` for
    // the actual agent identity. Trusting the mint's identity field
    // for agent detection means we never match, tracks + data topics
    // stay ignored, and we hit the 45s renderer timeout.
    return p.identity.startsWith(_agentIdentityPrefix);
  }

  void _wireEvents(lk.EventsListener<lk.RoomEvent> l, lk.Room room) {
    l.on<lk.TrackSubscribedEvent>((e) {
      if (!_isAgent(e.participant)) return;
      final track = e.track;
      if (track is lk.RemoteVideoTrack) {
        _videoTrack.value = track;
        // SEND_GRACE_MS: LK reports track subscribed slightly before
        // the first decoded frame is visible. Wait, then:
        //  1. Flip the internal `_ready` flag so sendMessage() accepts turns.
        //  2. Emit a placeholder byte on videoBytes. The controller
        //     (player_controller.dart:1036) flips PlayerStatus to
        //     `ready` on the FIRST videoBytes arrival -- that's what
        //     hides TwaiConnectionOverlay's connecting spinner. On the
        //     LiveKit transport the video track handles rendering, so
        //     videoBytes doesn't feed a sink; the byte is purely a
        //     signal that "the pipeline is producing content." The
        //     controller also stashes it as `_cachedInitSegment`
        //     which is only consumed by MSE non-web sinks (we're on
        //     livekit_client's own renderer, so ignored).
        Timer(const Duration(milliseconds: _sendGraceMs), () {
          if (_closed || _ready) return;
          _ready = true;
          if (!_videoBytesController.isClosed) {
            _videoBytesController.add(_readyPingBytes);
          }
        });
        _rendererTimer?.cancel();
        _rendererTimer = null;
      }
      // Audio tracks: LiveKit auto-plays via the participant's audio
      // element; nothing to do here for us. Speaker output routing on
      // native is handled by the livekit_client platform channel.
    });

    l.on<lk.TrackUnsubscribedEvent>((e) {
      if (!_isAgent(e.participant)) return;
      if (e.track is lk.RemoteVideoTrack) {
        _videoTrack.value = null;
      }
    });

    l.on<lk.DataReceivedEvent>((e) {
      final sender = e.participant;
      if (sender != null && !_isAgent(sender)) return;
      final Object? payload;
      try {
        payload = jsonDecode(utf8.decode(e.data));
      } catch (_) {
        return;
      }
      switch (e.topic) {
        case _topicSpeaking:
          final m = payload is Map ? payload : const {};
          if (m['type'] == 'speaking') {
            final value = m['value']?.toString() ?? '';
            final state = value == 'start'
                ? SpeakingState.start
                : value == 'stop'
                    ? SpeakingState.stop
                    : null;
            if (state != null) {
              _speakingController.add(SpeakingEvent(value: state));
            }
          }
        case _topicReply:
          final frame = ReplyFrame.tryParse(payload);
          if (frame != null) _replies.apply(frame);
        case _topicControl:
          // Passthrough: consumer apps subscribe to these via a future
          // extension. For now we ignore control events at the session
          // level.
          break;
        default:
          // Ignore unrecognised topics — servers may add new ones
          // faster than the SDK rebuilds.
          break;
      }
    });

    l.on<lk.ParticipantConnectedEvent>((e) {
      if (_isAgent(e.participant)) {
        _joinTimer?.cancel();
        _joinTimer = null;
        _armRendererTimer();
      }
    });

    l.on<lk.ParticipantDisconnectedEvent>((e) {
      if (_isAgent(e.participant) && !_closed) {
        _finish(const ChatSessionClosed('agent-ended'));
      }
    });

    l.on<lk.RoomDisconnectedEvent>((e) {
      if (!_closed) {
        _finish(const ChatSessionClosed('transport-ended'));
      }
    });
  }

  void _armJoinTimer() {
    _joinTimer?.cancel();
    _joinTimer = Timer(const Duration(milliseconds: _agentJoinTimeoutMs), () {
      if (_ready || _closed) return;
      _finish(const ChatSessionFailed(
        'LiveKit agent did not join within timeout.',
        isPermanent: false,
      ));
    });
  }

  void _armRendererTimer() {
    _rendererTimer?.cancel();
    _rendererTimer = Timer(const Duration(milliseconds: _rendererTimeoutMs), () {
      if (_ready || _closed) return;
      _finish(const ChatSessionFailed(
        'LiveKit renderer did not deliver a video track within timeout.',
        isPermanent: false,
      ));
    });
  }

  // -----------------------------------------------------------------------
  // sendMessage
  // -----------------------------------------------------------------------

  @override
  Future<void> sendMessage(String text,
      {num? gamificationLevel, Object? avatarStateBlock}) async {
    if (!_connected || _closed) {
      throw const ChatSessionNotConnectedException();
    }
    final room = _room;
    if (room == null || !_ready) {
      throw const ChatSessionNotConnectedException();
    }
    final participant = room.localParticipant;
    if (participant == null) {
      throw const ChatSessionNotConnectedException();
    }
    _replies.reset();
    final envelope = LiveKitChatEnvelope(
      requestId: 'req-${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      gamificationLevel: gamificationLevel,
      avatarStateBlock: avatarStateBlock?.toString(),
    );
    try {
      final opts = lk.SendTextOptions()..topic = _topicChat;
      await participant.sendText(jsonEncode(envelope.toJson()), options: opts);
    } catch (e) {
      throw ChatSessionSendException('LiveKit send failed: $e', e);
    }
  }

  // -----------------------------------------------------------------------
  // close
  // -----------------------------------------------------------------------

  @override
  Future<void> close() async {
    if (_closed) return;
    _finish(const ChatSessionClosed('closed'));
  }

  void _finish(ChatSessionEndReason reason) {
    if (_closed) return;
    _closed = true;
    _joinTimer?.cancel();
    _rendererTimer?.cancel();
    final room = _room;
    _room = null;
    _listener?.dispose();
    _listener = null;
    if (room != null) {
      // Fire-and-forget — LK's own graceful close, we don't block on it.
      unawaited(room.disconnect());
    }
    if (!_doneCompleter.isCompleted) _doneCompleter.complete(reason);
    scheduleMicrotask(() {
      _videoTrack.dispose();
      _replyController.close();
      _speakingController.close();
      _videoBytesController.close();
      _speakBoundariesController.close();
    });
  }
}
