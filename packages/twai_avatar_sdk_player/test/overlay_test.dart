import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

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
}

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TwaiAvatarPlayerController _makeController() {
  return TwaiAvatarPlayerController(
    sessionFactory: _FakeSession.new,
    config: const PlayerConfig(
      reconnectBaseBackoff: Duration(milliseconds: 10),
      reconnectMaxBackoff: Duration(milliseconds: 40),
      speakWatchdog: Duration(seconds: 30),
      livenessHeartbeat: Duration(seconds: 30),
      wsSilence: Duration(seconds: 30),
      resumeRecovery: Duration(seconds: 30),
    ),
  );
}

void main() {
  const avatar = Avatar(id: 'Fake', voiceId: 'v1');

  group('playOverlay + notifyOverlayEnded', () {
    test('playOverlay fires an event and sets isOverlayPlaying=true',
        () async {
      final c = _makeController();
      final events = <OverlayEvent>[];
      c.overlayEvents.listen(events.add);
      await c.connect(avatar);
      await _pump();
      expect(c.isOverlayPlaying, isFalse);
      c.playOverlay(
        kind: OverlayKind.gesture,
        url: 'https://cdn/wave.mp4',
        muteLive: true,
        id: 'g1',
        slug: 'wave',
      );
      await _pump();
      expect(events, hasLength(1));
      expect(events.first.url, 'https://cdn/wave.mp4');
      expect(events.first.kind, OverlayKind.gesture);
      expect(events.first.muteLive, isTrue);
      expect(events.first.slug, 'wave');
      expect(c.isOverlayPlaying, isTrue);
      await c.dispose();
    });

    test('notifyOverlayEnded clears isOverlayPlaying', () async {
      final c = _makeController();
      await c.connect(avatar);
      await _pump();
      c.playOverlay(
        kind: OverlayKind.gesture,
        url: 'https://cdn/kiss.mp4',
        muteLive: true,
      );
      expect(c.isOverlayPlaying, isTrue);
      c.notifyOverlayEnded();
      expect(c.isOverlayPlaying, isFalse);
      await c.dispose();
    });

    test('overlay events fire immediately even while speaking',
        () async {
      // Reference behavior: user tap → immediate overlay, no
      // deferral. Progression events queue; overlays don't.
      final s = _FakeSession();
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: const PlayerConfig(),
      );
      final events = <OverlayEvent>[];
      c.overlayEvents.listen(events.add);
      await c.connect(avatar);
      await _pump();
      s._speaking.add(const SpeakingEvent(value: SpeakingState.start, pts: 0));
      await _pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      c.playOverlay(
        kind: OverlayKind.gesture,
        url: 'https://cdn/hearthands.mp4',
        muteLive: true,
      );
      await _pump();
      expect(events, hasLength(1),
          reason: 'overlays must NOT be deferred while speaking');
      await c.dispose();
    });
  });

  group('extension helpers', () {
    test('playGesture forwards with muteLive=true', () async {
      final c = _makeController();
      final events = <OverlayEvent>[];
      c.overlayEvents.listen(events.add);
      await c.connect(avatar);
      await _pump();
      const gesture = PlayerGesture(
        id: 'g1',
        slug: 'wave',
        displayName: 'Wave',
        videoUrl: 'https://cdn/wave.mp4',
        isUnlocked: true,
      );
      c.playGesture(gesture);
      await _pump();
      expect(events, hasLength(1));
      expect(events.first.kind, OverlayKind.gesture);
      expect(events.first.url, 'https://cdn/wave.mp4');
      expect(events.first.muteLive, isTrue);
      expect(events.first.slug, 'wave');
      expect(events.first.id, 'g1');
      await c.dispose();
    });

    test('playFrame forwards with muteLive=false', () async {
      final c = _makeController();
      final events = <OverlayEvent>[];
      c.overlayEvents.listen(events.add);
      await c.connect(avatar);
      await _pump();
      const frame = PlayerFrame(
        id: 'f1',
        slug: 'beach-walk',
        frameNumber: 0,
        outfitSlug: 'casual',
        unlockLevel: 1,
        mainClipUrl: 'https://cdn/beach.mp4',
        isUnlocked: true,
      );
      c.playFrame(frame);
      await _pump();
      expect(events, hasLength(1));
      expect(events.first.kind, OverlayKind.frame);
      expect(events.first.url, 'https://cdn/beach.mp4');
      expect(events.first.muteLive, isFalse,
          reason: 'frames have their own audio; live is NOT muted');
      expect(events.first.slug, 'beach-walk');
      await c.dispose();
    });
  });

  group('disposal', () {
    test('playOverlay after dispose throws StateError', () async {
      final c = _makeController();
      await c.connect(avatar);
      await c.dispose();
      expect(
        () => c.playOverlay(
          kind: OverlayKind.gesture,
          url: 'x',
          muteLive: true,
        ),
        throwsStateError,
      );
    });

    test('notifyOverlayEnded after dispose is a silent no-op',
        () async {
      final c = _makeController();
      await c.connect(avatar);
      await c.dispose();
      // Should not throw.
      c.notifyOverlayEnded();
    });
  });
}
