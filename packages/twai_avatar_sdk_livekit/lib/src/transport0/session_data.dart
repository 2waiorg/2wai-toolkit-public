library;

import 'dart:convert';

import '../reply_stream.dart';
import 'engine_types.dart';

const String liveKitTopicSpeaking = 'livealman';
const String liveKitTopicReply = '2wai.reply';
const String liveKitTopicControl = '2wai.control';

/// Transport-independent handling for a live room's inbound protocol.
///
/// The real engine delegates every inbound data message and transcription
/// stream here, so headless conformance tests execute production behavior
/// without constructing a WebRTC room.
class LiveKitSessionDataDispatcher {
  LiveKitSessionDataDispatcher({
    required String agentIdentityPrefix,
    required bool Function() keepTags,
    required void Function(SpeakingActiveEvent event) onSpeaking,
    required void Function(ReplyStartEvent event) onReplyStart,
    required void Function(ReplyTextEvent event) onReplyText,
    required void Function(ReplyCompleteEvent event) onReplyComplete,
    required void Function(ControlEvent event) onControl,
    required void Function(TranscriptEvent event) onTranscript,
  })  : _agentIdentityPrefix = agentIdentityPrefix,
        _keepTags = keepTags,
        _onSpeaking = onSpeaking,
        _onReplyStart = onReplyStart,
        _onReplyText = onReplyText,
        _onReplyComplete = onReplyComplete,
        _onControl = onControl,
        _onTranscript = onTranscript {
    _replies = ReplyStreamReducer(
      keepTags: _keepTags,
      onStart: (id) => _onReplyStart(ReplyStartEvent(replyId: id)),
      onText: (text, id) =>
          _onReplyText(ReplyTextEvent(replyId: id, text: text)),
      onComplete: (text, kind, id) => _onReplyComplete(
        ReplyCompleteEvent(replyId: id, text: text, kind: kind),
      ),
    );
  }

  final String _agentIdentityPrefix;
  final bool Function() _keepTags;
  final void Function(SpeakingActiveEvent event) _onSpeaking;
  final void Function(ReplyStartEvent event) _onReplyStart;
  final void Function(ReplyTextEvent event) _onReplyText;
  final void Function(ReplyCompleteEvent event) _onReplyComplete;
  final void Function(ControlEvent event) _onControl;
  final void Function(TranscriptEvent event) _onTranscript;
  late final ReplyStreamReducer _replies;

  bool get sawReplyProtocol => _replies.sawProtocol;

  /// Starts a new outbound turn and deliberately reopens fallback delivery.
  void beginTurn() => _replies.reset();

  void reset() => _replies.reset();

  /// Consumes the exact UTF-8 payload delivered by LiveKit's data channel.
  void receiveData({
    required String? topic,
    required List<int> payload,
    String? participantIdentity,
  }) {
    if (participantIdentity != null &&
        !participantIdentity.startsWith(_agentIdentityPrefix)) {
      return;
    }

    Object? event;
    try {
      event = jsonDecode(utf8.decode(payload));
    } catch (_) {
      return;
    }

    if (topic == liveKitTopicSpeaking && event is Map) {
      if (event['type'] == 'speaking' && event['value'] == 'start') {
        _onSpeaking(const SpeakingActiveEvent(active: true));
      } else if (event['type'] == 'speaking' && event['value'] == 'stop') {
        _onSpeaking(const SpeakingActiveEvent(active: false));
      }
    } else if (topic == liveKitTopicReply) {
      final frame = ReplyFrame.tryParse(event);
      if (frame != null) _replies.apply(frame);
    } else if (topic == liveKitTopicControl && event is Map) {
      _onControl(ControlEvent(event: Map<String, Object?>.from(event)));
    }
  }

  /// Drains one `lk.transcription` stream into the same reply event surface.
  Future<void> consumeFallbackTranscription({
    required String id,
    required String participantIdentity,
    required String? localParticipantIdentity,
    required Stream<String> chunks,
    bool Function()? isClosed,
  }) async {
    if (participantIdentity == localParticipantIdentity) return;

    var text = '';
    var started = false;
    try {
      await for (final chunk in chunks) {
        if ((isClosed?.call() ?? false) || _replies.sawProtocol) return;
        if (!started) {
          started = true;
          _onReplyStart(ReplyStartEvent(replyId: id));
        }
        text += chunk;
        final display = _clean(text);
        _onReplyText(ReplyTextEvent(replyId: id, text: display));
        _onTranscript(TranscriptEvent(
          participant: participantIdentity,
          text: display,
          finalChunk: false,
        ));
      }
      if (started && !_replies.sawProtocol) {
        _finishFallback(id, participantIdentity, text, ReplyTerminalKind.end);
      }
    } catch (_) {
      if (started && !_replies.sawProtocol) {
        _finishFallback(id, participantIdentity, text, ReplyTerminalKind.error);
      }
    }
  }

  String _clean(String text) => _keepTags() ? text : stripExpressionTags(text);

  void _finishFallback(
    String id,
    String participantIdentity,
    String text,
    ReplyTerminalKind kind,
  ) {
    final display = _clean(text);
    _onReplyComplete(ReplyCompleteEvent(
      replyId: id,
      text: display,
      kind: kind,
    ));
    _onTranscript(TranscriptEvent(
      participant: participantIdentity,
      text: display,
      finalChunk: true,
    ));
  }
}
