/// The LiveKit engine — spec §6. Dart port of
/// `packages/core/src/engine.ts` on twai-web-sdk `feat/livekit-engine`,
/// itself a port of PP's production
/// `PenthouseLiveKitTransport` (`clg_pp_payment
/// frontend/src/lean/livekit_transport.ts`).
///
/// **This is a port, not a rewrite.** The lifecycle here carries fixes
/// paid for by a real incident, in which an auto-reconnecting client
/// opened 864 sessions in 48 hours. Six things were changed in Mason's
/// port and nothing else, and this Dart translation carries the same
/// six seams (adapted to Flutter idioms where forced):
///
///   1. `LiveKitEngine(options)` replaces the four-positional-argument
///      constructor.
///   2. Minting is injected. The engine never fetches; hosts pass a
///      zero-arg closure (see `mint_helpers.dart`).
///   3. Callbacks became broadcast streams (`onSpeaking`, `onReady`,
///      `onReplyText`, etc). Plus one additive `onTranscript` stream
///      on the fallback path.
///   4. `send(text, {extra})` builds the envelope engine-side.
///   5. The audio pathway is delegated to `livekit_client`'s own
///      remote-audio auto-attach; the Flutter engine has no HTMLAudio
///      element, so there is no two-sink mode. Speaking events remain
///      the sole visibility signal.
///   6. An observable `state`: [state] is a `ValueListenable<EngineState>`.
///
/// **Behaviours that are load-bearing and must not be "cleaned up":**
///
///   - `_closeRoom` sets `_closed = true` BEFORE `room.disconnect()`,
///     so the room's own `Disconnected` handler finds the session
///     already closed and does not re-enter. Every teardown that HAS a
///     room funnels through it, exactly once.
///   - **The engine NEVER reconnects on its own.** It classifies the
///     ending (`agentEnded` vs `transportEnded`), emits `ended`, and
///     stops. What happens next is host policy — that is the incident
///     fix. Host reconnect logic lives in [LiveKitRoomLifecycle].
///   - `adaptiveStream: false, dynacast: false`. A surface that fades
///     the video element to opacity 0 between replies would otherwise
///     have its subscription paused by adaptiveStream, stalling
///     exactly when the next reply arrives.
///   - The reply protocol supersedes fallback transcription
///     (`sawProtocol`), and expression tags are stripped on BOTH paths
///     — the fallback does not go through the reducer, so it cannot
///     inherit the strip.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'envelope.dart';
import 'engine_lifecycle.dart';
import 'engine_types.dart';
import 'session_data.dart';

const String _topicChat = 'lk.chat';
const String _topicTranscription = 'lk.transcription';
const String _defaultAgentPrefix = 'livealman-agent-';

/// `connect()` reached a joined room, or the host's mint said chat is
/// off.
///
/// `connected` is also what a connect() that RACED a disconnect()
/// returns: the session is torn down rather than joined, but the call
/// did its job and the host already knows, because it is the one that
/// called disconnect(). Read [state], not this, to find out whether a
/// session is live.
enum ConnectResult { connected, disabled }

/// The consumer's render surface(s), passed in at engine construction
/// time. The engine writes into these slots — matching Mason's
/// `element.srcObject = new MediaStream([track])` discipline on the JS
/// side. Widget code (`TwaiTransport0Player`) wraps these listenables
/// with `ValueListenableBuilder` around a `VideoTrackRenderer`.
///
/// Two slots because the Flutter renderer needs the [lk.RemoteVideoTrack]
/// as its widget prop, and the widget rebuilds when the value
/// changes. Audio auto-plays via livekit_client's own remote-track
/// pipeline — nothing to bind here.
class LiveKitEngineMedia {
  final ValueNotifier<lk.RemoteVideoTrack?> videoSlot;
  const LiveKitEngineMedia({required this.videoSlot});
}

class LiveKitEngineOptions {
  /// Resolve a room to join. Zero-arg: the host already knows which
  /// avatar it is opening.
  ///
  /// Every rejection propagates out of [LiveKitEngine.connect] by
  /// identity — [MintRateLimited], [MintUnavailable], or anything else
  /// the host throws. The engine does not classify, wrap, or retry,
  /// and a 429 must not be retried behind the user's back (spec §6.2).
  final Future<MintResult> Function() mint;

  /// Where the engine puts the media.
  final LiveKitEngineMedia media;

  /// Identity prefix that marks a participant as our renderer agent.
  /// Defaults to `livealman-agent-`.
  final String agentIdentityPrefix;

  /// Admin review: keep direction tags in the DISPLAYED text.
  final bool Function()? keepTags;

  /// Where a throwing host event handler goes. Defaults to writing
  /// the error and event name to stderr via a `print`. Must not
  /// throw; if it does, it is ignored.
  final void Function(Object err, String event)? onHandlerError;

  const LiveKitEngineOptions({
    required this.mint,
    required this.media,
    this.agentIdentityPrefix = _defaultAgentPrefix,
    this.keepTags,
    this.onHandlerError,
  });
}

/// One avatar chat session over a LiveKit room.
///
/// See the library doc for the six seams and the load-bearing
/// behaviours. The public surface is `connect() → send() → disconnect()`
/// plus the observable [state] and the event streams.
class LiveKitEngine {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  Future<void>? _disconnectFuture;
  bool _closed = false;
  final ValueNotifier<EngineState> _state =
      ValueNotifier<EngineState>(EngineState.idle);
  String? _mintedRoom;
  final _tracks = <String, lk.RemoteTrack>{};
  late final LiveKitSessionDataDispatcher _sessionData;
  late final LiveKitEngineLifecycle _lifecycle;

  final _warming = StreamController<WarmingEvent>.broadcast();
  final _ready$ = StreamController<ReadyEvent>.broadcast();
  final _speaking = StreamController<SpeakingActiveEvent>.broadcast();
  final _replyStart = StreamController<ReplyStartEvent>.broadcast();
  final _replyText = StreamController<ReplyTextEvent>.broadcast();
  final _replyComplete = StreamController<ReplyCompleteEvent>.broadcast();
  final _control = StreamController<ControlEvent>.broadcast();
  final _transcript = StreamController<TranscriptEvent>.broadcast();
  final _ended = StreamController<EndedEvent>.broadcast();
  final _notice = StreamController<NoticeEvent>.broadcast();

  final LiveKitEngineMedia _media;
  final String _agentPrefix;
  final bool Function() _keepTags;
  final Future<MintResult> Function() _mint;
  final void Function(Object err, String event) _onHandlerError;
  LiveKitEngine(LiveKitEngineOptions options)
      : _media = options.media,
        _agentPrefix = options.agentIdentityPrefix,
        _keepTags = (() => options.keepTags?.call() ?? false),
        _mint = options.mint,
        _onHandlerError = options.onHandlerError ??
            ((err, event) {
              // Fallback sink: last line, must not throw.
              // ignore: avoid_print
              print("[twai] engine '$event' handler threw: $err");
            }) {
    _sessionData = LiveKitSessionDataDispatcher(
      agentIdentityPrefix: _agentPrefix,
      keepTags: _keepTags,
      onSpeaking: (event) => _safeEmit(_speaking, event, 'speaking'),
      onReplyStart: (event) => _safeEmit(_replyStart, event, 'reply:start'),
      onReplyText: (event) => _safeEmit(_replyText, event, 'reply:text'),
      onReplyComplete: (event) =>
          _safeEmit(_replyComplete, event, 'reply:complete'),
      onControl: (event) => _safeEmit(_control, event, 'control'),
      onTranscript: (event) => _safeEmit(_transcript, event, 'transcript'),
    );
    _lifecycle = LiveKitEngineLifecycle(
      isClosed: () => _closed,
      onState: (state) => _state.value = state,
      onNotice: (event) => _safeEmit(_notice, event, 'notice'),
      onWarming: (event) => _safeEmit(_warming, event, 'warming'),
      onReady: (event) => _safeEmit(_ready$, event, 'ready'),
      onSpeaking: (event) => _safeEmit(_speaking, event, 'speaking'),
    );
  }

  /// Where the session is. Note that the `warming` STATE and the
  /// `onWarming` STREAM answer different questions: the stream fires
  /// as soon as a room has been minted (so a host can paint
  /// "connecting…" immediately), while the state means specifically
  /// "the agent is here, the renderer has not painted yet".
  ValueListenable<EngineState> get state => _state;

  /// Convenience getter. `true` once the settle window has elapsed
  /// and the room hasn't torn down. Deliberately does NOT gate on
  /// `room.connectionState == connected` — that has flaked briefly
  /// under Flutter's client (single tick of `.reconnecting` between
  /// stable frames), causing `send()` to throw [SessionNotReady] even
  /// with a fully-alive session. If the room genuinely can't publish,
  /// `sendText` itself throws downstream.
  bool get isReady => _lifecycle.ready && !_closed && _room != null;

  /// The room this session is joined to, or `null` before [connect]
  /// and after teardown. Hosts correlate their own logs and spend
  /// against it, so it is the minted name — what the token was issued
  /// for — rather than anything read back off the transport.
  ///
  /// Empty string is possible and is not an error: some token
  /// endpoints omit `room` and let the server name it, in which case
  /// the authoritative name only exists on the Room object.
  String? get roomName => _mintedRoom;

  // ─── Streams ──────────────────────────────────────────────
  Stream<WarmingEvent> get onWarming => _warming.stream;
  Stream<ReadyEvent> get onReady => _ready$.stream;
  Stream<SpeakingActiveEvent> get onSpeaking => _speaking.stream;
  Stream<ReplyStartEvent> get onReplyStart => _replyStart.stream;
  Stream<ReplyTextEvent> get onReplyText => _replyText.stream;
  Stream<ReplyCompleteEvent> get onReplyComplete => _replyComplete.stream;
  Stream<ControlEvent> get onControl => _control.stream;
  Stream<TranscriptEvent> get onTranscript => _transcript.stream;
  Stream<EndedEvent> get onEnded => _ended.stream;
  Stream<NoticeEvent> get onNotice => _notice.stream;

  // ─── Public API ───────────────────────────────────────────

  Future<ConnectResult> connect() async {
    // Not re-entrant. A second connect() on a live session would
    // orphan the first room — still joined, still billing, with
    // nothing holding its reference — which is the shape of the
    // 864-session incident. Retry IS still legal from 'idle', which
    // is where a failed mint and a disabled mint both leave the
    // session; after 'ended' this throws.
    if (_state.value != EngineState.idle) {
      throw StateError(
        "connect() is not re-entrant (state: ${_state.value.name}); "
        "create a new engine, or retry only from 'idle'",
      );
    }
    // state -> minting: the host's closure is in flight.
    _state.value = EngineState.minting;
    MintResult minted;
    try {
      minted = await _mint();
    } catch (err) {
      // state -> idle: nothing was constructed, so the session is
      // exactly where it started. A disconnect() that landed mid-mint
      // already ended this session, and that verdict wins.
      if (!_closed) _state.value = EngineState.idle;
      rethrow;
    }
    // disconnect() while the mint was in flight — the host has
    // already given up on this session.
    if (_closed) return ConnectResult.connected;
    if (minted is MintResultDisabled) {
      // state -> idle: a real outcome, not a failure — chat is off.
      _state.value = EngineState.idle;
      return ConnectResult.disabled;
    }
    final enabled = minted as MintResultEnabled;
    _mintedRoom = enabled.room;
    _safeEmit(_warming, WarmingEvent(room: enabled.room), 'warming');
    // state -> joining: from here until the agent is seen.
    _state.value = EngineState.joining;

    final room = lk.Room(
      // adaptiveStream / dynacast: false — see library doc for why.
      roomOptions: const lk.RoomOptions(
        adaptiveStream: false,
        dynacast: false,
      ),
    );
    _room = room;
    final listener = room.createListener();
    _listener = listener;

    _wireEvents(listener, room);

    try {
      await room.connect(enabled.url, enabled.token);
    } catch (err) {
      // Connect failure IS a mint-side or transport-side outcome;
      // classify as transport-ended so host retry policy decides.
      // Do the same closed-race check as the mint path.
      if (_closed) return ConnectResult.connected;
      await _closeRoom(room);
      _safeEmit(
          _ended, const EndedEvent(cause: EndedCause.transportEnded), 'ended');
      rethrow;
    }
    if (_closed) {
      await room.disconnect();
      return ConnectResult.connected;
    }
    var alreadyPresent = false;
    for (final participant in room.remoteParticipants.values) {
      if (_isAgent(participant)) alreadyPresent = true;
    }
    if (alreadyPresent) {
      _lifecycle.joined(
        agentAlreadyPresent: true,
        roomName: room.name ?? _mintedRoom ?? '',
      );
    } else {
      _lifecycle.joined(
        agentAlreadyPresent: false,
        roomName: room.name ?? _mintedRoom ?? '',
      );
    }
    return ConnectResult.connected;
  }

  /// Publish a chat turn.
  ///
  /// The envelope is built here, not by the host: `extra` is spread
  /// FIRST so the engine's own fields always win. A host cannot forge
  /// `request_id`, downgrade `v`, or substitute the text that the user
  /// actually typed.
  Future<void> send(String text, {Map<String, Object?>? extra}) async {
    if (_room == null || !isReady) throw const SessionNotReady();
    // A chat turn normally originates directly from a button click or Enter
    // keypress, so this is a reliable browser user-activation boundary. Start
    // audio before the first await; deferring it until after sendText would
    // lose the browser gesture and leave an otherwise healthy remote audio
    // track muted. This is harmless for programmatic sends and native clients.
    unawaited(resumePlayback());
    _sessionData.beginTurn();
    final envelope = buildLiveKitChatEnvelope(text, extra: extra);
    final opts = lk.SendTextOptions()..topic = _topicChat;
    await _room!.localParticipant
        ?.sendText(jsonEncode(envelope), options: opts);
  }

  /// Unblock browser autoplay for the remote audio pipeline. Port of
  /// Mason's `livekit_transport.ts:116-125` `resumePlayback()`,
  /// trimmed to what the Dart client actually exposes: only
  /// `Room.startAudio()` (no `startVideo` — video autoplay is handled
  /// by `VideoTrackRenderer` internally through its own
  /// HTMLVideoElement).
  ///
  /// livekit_client's Room has a Web autoplay gate: on cold page load
  /// without a prior user gesture, remote audio tracks are subscribed
  /// but muted by the browser. `Room.startAudio()` lifts that gate,
  /// but ONLY when called from a synchronous gesture handler (click /
  /// touch). Widgets should call this from a `GestureDetector.onTap`
  /// or equivalent. Safe to call at any time — no-op if audio already
  /// playing or if the room isn't connected yet.
  Future<void> resumePlayback() async {
    final room = _room;
    if (_closed || room == null) return;
    try {
      await room.startAudio();
    } catch (_) {
      // First call before a gesture returns rejected; the caller
      // should retry on the next gesture.
    }
  }

  Future<void> disconnect() async {
    if (_closed) {
      if (_disconnectFuture != null) await _disconnectFuture;
      return;
    }
    final room = _room;
    if (room != null) {
      await _closeRoom(room);
      return;
    }
    _closed = true;
    _lifecycle.close();
    // state -> ended: the same teardown as _closeRoom, for a session
    // that never got as far as building a room.
    _state.value = EngineState.ended;
    _mintedRoom = null;
    _sessionData.reset();
    _tracks.clear();
  }

  /// Release stream controllers. Call after [disconnect] when the
  /// engine will not be used again.
  Future<void> dispose() async {
    await _warming.close();
    await _ready$.close();
    await _speaking.close();
    await _replyStart.close();
    await _replyText.close();
    await _replyComplete.close();
    await _control.close();
    await _transcript.close();
    await _ended.close();
    await _notice.close();
    _state.dispose();
  }

  // ─── Internals ───────────────────────────────────────────

  bool _isAgent(lk.Participant p) => p.identity.startsWith(_agentPrefix);

  void _wireEvents(lk.EventsListener<lk.RoomEvent> l, lk.Room room) {
    room.registerTextStreamHandler(
      _topicTranscription,
      (lk.TextStreamReader reader, String participantIdentity) {
        final id = reader.info?.id;
        if (id == null) return;
        final chunks = reader.map((chunk) => utf8.decode(chunk.content));
        unawaited(_sessionData.consumeFallbackTranscription(
          id: id,
          participantIdentity: participantIdentity,
          localParticipantIdentity: room.localParticipant?.identity,
          chunks: chunks,
          isClosed: () => _closed,
        ));
      },
    );

    l.on<lk.TrackSubscribedEvent>((e) {
      if (_closed || !_isAgent(e.participant)) return;
      final track = e.track;
      // Only two track kinds matter: audio and video. Everything
      // else is ignored (as on Mason's engine).
      if (track is lk.RemoteVideoTrack) {
        try {
          e.publication.setVideoQuality(lk.VideoQuality.HIGH);
        } catch (_) {
          // best-effort; some SFU/room combos reject this
        }
        _attachVideo(track);
        _lifecycle.rendererReady(room.name ?? _mintedRoom ?? '');
      } else if (track is lk.RemoteAudioTrack) {
        _tracks['audio'] = track;
        // livekit_client auto-attaches remote audio via its own
        // participant pipeline; nothing else to do.
      }
    });

    l.on<lk.TrackUnsubscribedEvent>((e) {
      final track = e.track;
      if (track is lk.RemoteVideoTrack) {
        if (_tracks['video'] != track) return;
        _tracks.remove('video');
        _media.videoSlot.value = null;
      } else if (track is lk.RemoteAudioTrack) {
        if (_tracks['audio'] != track) return;
        _tracks.remove('audio');
      }
    });

    l.on<lk.DataReceivedEvent>((e) {
      if (_closed) return;
      _sessionData.receiveData(
        topic: e.topic,
        payload: e.data,
        participantIdentity: e.participant?.identity,
      );
    });

    l.on<lk.ParticipantConnectedEvent>((e) {
      if (_isAgent(e.participant)) {
        _lifecycle.agentPresent(room.name ?? _mintedRoom ?? '');
      }
    });
    l.on<lk.ParticipantDisconnectedEvent>((e) {
      if (!_isAgent(e.participant) || _closed || _room != room) return;
      unawaited(_closeRoom(room));
      _safeEmit(
          _ended, const EndedEvent(cause: EndedCause.agentEnded), 'ended');
    });
    l.on<lk.RoomReconnectingEvent>((_) {
      _lifecycle.reconnecting(room.name ?? _mintedRoom ?? '');
    });
    l.on<lk.RoomReconnectedEvent>((_) {
      _lifecycle.reconnected(
        roomName: room.name ?? _mintedRoom ?? '',
        hasVideo: _tracks.containsKey('video'),
      );
    });
    l.on<lk.RoomDisconnectedEvent>((_) {
      if (_closed || _room != room) return;
      unawaited(_closeRoom(room));
      _safeEmit(
          _ended, const EndedEvent(cause: EndedCause.transportEnded), 'ended');
    });
  }

  void _attachVideo(lk.RemoteVideoTrack track) {
    _tracks['video'] = track;
    // Consumer's ValueNotifier — Flutter analogue of
    // `element.srcObject = new MediaStream([track])`.
    _media.videoSlot.value = track;
  }

  Future<void> _closeRoom(lk.Room room) async {
    if (_closed || _room != room) return;
    // `_closed` FIRST, before `room.disconnect()` below: disconnecting
    // fires this room's own Disconnected handler, which must find the
    // session already closed and stop. Do not reorder this method.
    _closed = true;
    _lifecycle.close();
    // state -> ended: teardown has begun; the session is not reusable.
    _state.value = EngineState.ended;
    _mintedRoom = null;
    _sessionData.reset();
    _tracks.clear();
    _media.videoSlot.value = null;
    _listener?.dispose();
    _listener = null;
    _room = null;
    _safeEmit(_speaking, const SpeakingActiveEvent(active: false), 'speaking');
    final future = room.disconnect();
    _disconnectFuture = future;
    await future;
  }

  void _safeEmit<T>(StreamController<T> ctrl, T event, String eventName) {
    if (ctrl.isClosed) return;
    try {
      ctrl.add(event);
    } catch (err) {
      try {
        _onHandlerError(err, eventName);
      } catch (_) {
        // Last line — nowhere left to report to.
      }
    }
  }
}
