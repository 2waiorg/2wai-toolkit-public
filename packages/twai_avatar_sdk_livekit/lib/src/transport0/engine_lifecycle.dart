library;

import 'dart:async';

import 'engine_types.dart';

const Duration liveKitAgentJoinTimeout = Duration(seconds: 10);
const Duration liveKitRendererTimeout = Duration(seconds: 45);
const Duration liveKitSendGrace = Duration(milliseconds: 1200);

abstract interface class LiveKitLifecycleTimer {
  void cancel();
}

typedef LiveKitLifecycleScheduler = LiveKitLifecycleTimer Function(
  Duration delay,
  void Function() callback,
);

class _DartLifecycleTimer implements LiveKitLifecycleTimer {
  _DartLifecycleTimer(Duration delay, void Function() callback)
      : _timer = Timer(delay, callback);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// Renderer-presence and readiness transitions shared by the live engine and
/// the headless lifecycle conformance runner.
class LiveKitEngineLifecycle {
  LiveKitEngineLifecycle({
    required bool Function() isClosed,
    required void Function(EngineState state) onState,
    required void Function(NoticeEvent event) onNotice,
    required void Function(WarmingEvent event) onWarming,
    required void Function(ReadyEvent event) onReady,
    required void Function(SpeakingActiveEvent event) onSpeaking,
    LiveKitLifecycleScheduler? schedule,
  })  : _isClosed = isClosed,
        _onState = onState,
        _onNotice = onNotice,
        _onWarming = onWarming,
        _onReady = onReady,
        _onSpeaking = onSpeaking,
        _schedule = schedule ??
            ((delay, callback) => _DartLifecycleTimer(delay, callback));

  final bool Function() _isClosed;
  final void Function(EngineState state) _onState;
  final void Function(NoticeEvent event) _onNotice;
  final void Function(WarmingEvent event) _onWarming;
  final void Function(ReadyEvent event) _onReady;
  final void Function(SpeakingActiveEvent event) _onSpeaking;
  final LiveKitLifecycleScheduler _schedule;

  LiveKitLifecycleTimer? _joinTimer;
  LiveKitLifecycleTimer? _rendererTimer;
  bool _ready = false;

  bool get ready => _ready;

  void joined({required bool agentAlreadyPresent, required String roomName}) {
    if (agentAlreadyPresent) {
      agentPresent(roomName);
      return;
    }
    _joinTimer = _schedule(liveKitAgentJoinTimeout, () {
      _joinTimer = null;
      if (!_ready && !_isClosed()) {
        _onNotice(const NoticeEvent(kind: NoticeKind.sessionsBusy));
      }
    });
  }

  void agentPresent(String roomName) {
    _clearJoinTimer();
    if (_ready || _rendererTimer != null) return;
    _onState(EngineState.warming);
    _rendererTimer = _schedule(liveKitRendererTimeout, () {
      _rendererTimer = null;
      if (!_ready && !_isClosed()) {
        _onNotice(const NoticeEvent(kind: NoticeKind.rendererTimeout));
      }
    });
  }

  void rendererReady(String roomName) {
    _rendererTimer?.cancel();
    _rendererTimer = null;
    _schedule(liveKitSendGrace, () {
      if (_isClosed() || _ready) return;
      _ready = true;
      _onState(EngineState.ready);
      _onReady(ReadyEvent(room: roomName));
    });
  }

  void reconnecting(String roomName) {
    _ready = false;
    _rendererTimer?.cancel();
    _rendererTimer = null;
    _onState(EngineState.joining);
    _onSpeaking(const SpeakingActiveEvent(active: false));
    _onWarming(WarmingEvent(room: roomName));
  }

  void reconnected({required String roomName, required bool hasVideo}) {
    if (_isClosed()) return;
    if (hasVideo) {
      rendererReady(roomName);
    } else {
      agentPresent(roomName);
    }
  }

  void close() {
    _ready = false;
    _clearJoinTimer();
    _rendererTimer?.cancel();
    _rendererTimer = null;
  }

  void _clearJoinTimer() {
    _joinTimer?.cancel();
    _joinTimer = null;
  }
}
