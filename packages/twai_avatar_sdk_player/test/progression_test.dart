import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// Minimal fake session (mirrors reconnect_test.dart's FakeSession but
/// kept local to avoid cross-file coupling). Auto-emits a frame on
/// connect so the controller reaches `ready`.
class _FakeSession implements ChatSession {
  final _video = StreamController<Uint8List>.broadcast();
  final _speaking = StreamController<SpeakingEvent>.broadcast();
  final _reply = StreamController<String>.broadcast();
  final _done = Completer<ChatSessionEndReason>();
  bool _connected = false;
  bool _closed = false;

  @override
  Future<void> connect(Avatar avatar) async {
    if (_connected) throw const ChatSessionAlreadyConnectedException();
    _connected = true;
    // ignore: discarded_futures
    Future.microtask(() {
      if (!_closed) _video.add(Uint8List(16));
    });
  }

  @override
  Future<void> sendMessage(String text,
      {num? gamificationLevel, Object? avatarStateBlock}) async {}

  @override
  Stream<String> get replyText => _reply.stream;
  @override
  Stream<SpeakingEvent> get speakingEvents => _speaking.stream;
  @override
  Stream<Uint8List> get videoBytes => _video.stream;
  @override
  Stream<void> get speakBoundaries => const Stream<void>.empty();
  @override
  Future<ChatSessionEndReason> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _video.close();
    await _speaking.close();
    await _reply.close();
    if (!_done.isCompleted) {
      _done.complete(const ChatSessionClosed('test close'));
    }
  }

  void emitSpeaking(SpeakingState v) =>
      _speaking.add(SpeakingEvent(value: v, pts: 0));
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TwaiAvatarPlayerController _makeController({
  Duration pendingLevelUpMaxDelay = const Duration(seconds: 30),
}) {
  return TwaiAvatarPlayerController(
    sessionFactory: _FakeSession.new,
    config: PlayerConfig(
      reconnectBaseBackoff: const Duration(milliseconds: 10),
      reconnectMaxBackoff: const Duration(milliseconds: 40),
      speakWatchdog: const Duration(seconds: 30),
      livenessHeartbeat: const Duration(seconds: 30),
      wsSilence: const Duration(seconds: 30),
      resumeRecovery: const Duration(seconds: 30),
      pendingLevelUpMaxDelay: pendingLevelUpMaxDelay,
    ),
  );
}

void main() {
  const avatar = Avatar(id: 'Fake', voiceId: 'v1');

  group('XP delivery', () {
    test('awardXp during ready fires immediately', () async {
      final c = _makeController();
      final xpEvents = <XpEvent>[];
      c.xpEvents.listen(xpEvents.add);
      await c.connect(avatar);
      await _pump();
      c.awardXp(10, band: XpBand.low, reason: 'message');
      await _pump();
      expect(xpEvents, hasLength(1));
      expect(xpEvents.first.amount, 10);
      expect(xpEvents.first.band, XpBand.low);
      expect(xpEvents.first.reason, 'message');
      await c.dispose();
    });

    test('awardXp during speaking is queued; drains on ready',
        () async {
      final s = _FakeSession();
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: const PlayerConfig(
          pendingLevelUpMaxDelay: Duration(seconds: 30),
        ),
      );
      final xpEvents = <XpEvent>[];
      c.xpEvents.listen(xpEvents.add);
      await c.connect(avatar);
      await _pump();
      // Enter speaking state via a real speaking event.
      s.emitSpeaking(SpeakingState.start);
      await _pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      // Award XP mid-speech — must NOT fire yet.
      c.awardXp(25, band: XpBand.medium);
      await _pump();
      expect(xpEvents, isEmpty,
          reason: 'XP awards must defer while speaking');
      // Return to ready — event drains.
      s.emitSpeaking(SpeakingState.stop);
      await _pump();
      expect(xpEvents, hasLength(1));
      expect(xpEvents.first.amount, 25);
      await c.dispose();
    });

    test('stale queued XP is dropped past pendingLevelUpMaxDelay',
        () async {
      final s = _FakeSession();
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: const PlayerConfig(
          pendingLevelUpMaxDelay: Duration(milliseconds: 50),
        ),
      );
      final xpEvents = <XpEvent>[];
      c.xpEvents.listen(xpEvents.add);
      await c.connect(avatar);
      await _pump();
      s.emitSpeaking(SpeakingState.start);
      await _pump();
      c.awardXp(5, band: XpBand.low);
      // Wait long enough for the event to go stale.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      s.emitSpeaking(SpeakingState.stop);
      await _pump();
      expect(xpEvents, isEmpty,
          reason: 'stale queued XP must be dropped, not fired');
      await c.dispose();
    });
  });

  group('Level-up delivery', () {
    test('notifyLevelUp during ready fires immediately', () async {
      final c = _makeController();
      final events = <LevelUpEvent>[];
      c.levelUpEvents.listen(events.add);
      await c.connect(avatar);
      await _pump();
      c.notifyLevelUp(
        5,
        previousLevel: 4,
        rewardTitle: 'Bikini outfit',
        sessionLevelUpIndex: 1,
        sessionLevelUpTotal: 3,
      );
      await _pump();
      expect(events, hasLength(1));
      expect(events.first.newLevel, 5);
      expect(events.first.previousLevel, 4);
      expect(events.first.rewardTitle, 'Bikini outfit');
      expect(events.first.sessionLevelUpIndex, 1);
      expect(events.first.sessionLevelUpTotal, 3);
      await c.dispose();
    });

    test('notifyLevelUp during speaking is queued; drains on ready',
        () async {
      final s = _FakeSession();
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: const PlayerConfig(
          pendingLevelUpMaxDelay: Duration(seconds: 30),
        ),
      );
      final events = <LevelUpEvent>[];
      c.levelUpEvents.listen(events.add);
      await c.connect(avatar);
      await _pump();
      s.emitSpeaking(SpeakingState.start);
      await _pump();
      c.notifyLevelUp(6);
      await _pump();
      expect(events, isEmpty);
      s.emitSpeaking(SpeakingState.stop);
      await _pump();
      expect(events, hasLength(1));
      expect(events.first.newLevel, 6);
      await c.dispose();
    });
  });

  group('Ordering + interleaving', () {
    test('multiple queued events all fire on drain (order preserved)',
        () async {
      final s = _FakeSession();
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: const PlayerConfig(
          pendingLevelUpMaxDelay: Duration(seconds: 30),
        ),
      );
      final xp = <XpEvent>[];
      final lvl = <LevelUpEvent>[];
      c.xpEvents.listen(xp.add);
      c.levelUpEvents.listen(lvl.add);
      await c.connect(avatar);
      await _pump();
      s.emitSpeaking(SpeakingState.start);
      await _pump();
      c.awardXp(10, band: XpBand.low);
      c.awardXp(20, band: XpBand.medium);
      c.notifyLevelUp(3);
      c.awardXp(50, band: XpBand.high);
      s.emitSpeaking(SpeakingState.stop);
      await _pump();
      expect(xp.map((e) => e.amount), [10, 20, 50]);
      expect(lvl.map((e) => e.newLevel), [3]);
      await c.dispose();
    });
  });
}
