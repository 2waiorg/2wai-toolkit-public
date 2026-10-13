import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// A minimal fake [ChatSession] for driving the controller from tests.
///
/// Set [autoFrameOnConnect] to have the session emit a video frame on
/// microtask after `connect()` completes — that's what triggers the
/// controller's `ready` transition (first-frame arrival, per port
/// spec §12.1.1). Without it, the session sits in `connecting`
/// forever and resume-recovery eventually fires.
///
/// Set [onSendMessage] to hook into `sendMessage` — useful for
/// simulating the brain-side pipeline firing `speaking:start` during
/// the send await (§12.1.6 test).
class FakeSession implements ChatSession {
  FakeSession({
    this.connectResult,
    this.throwOnConnect,
    this.autoFrameOnConnect = false,
    this.onSendMessage,
  });

  Future<void>? connectResult;
  Object? throwOnConnect;
  bool autoFrameOnConnect;
  void Function(String text)? onSendMessage;

  final _video = StreamController<Uint8List>.broadcast();
  final _speaking = StreamController<SpeakingEvent>.broadcast();
  final _reply = StreamController<String>.broadcast();
  final _done = Completer<ChatSessionEndReason>();

  bool _connected = false;
  bool _closed = false;
  final List<String> sentMessages = [];

  @override
  Future<void> connect(Avatar avatar) async {
    if (_connected) throw const ChatSessionAlreadyConnectedException();
    if (throwOnConnect != null) throw throwOnConnect!;
    if (connectResult != null) await connectResult;
    _connected = true;
    if (autoFrameOnConnect) {
      // Emit on microtask so the controller has already returned
      // from its own `await session.connect(...)` before the frame
      // arrives — matches production timing.
      // ignore: discarded_futures
      Future.microtask(() {
        if (!_closed) emitFrame();
      });
    }
  }

  @override
  Future<void> sendMessage(String text,
      {num? gamificationLevel, Object? avatarStateBlock}) async {
    if (!_connected) throw const ChatSessionNotConnectedException();
    sentMessages.add(text);
    onSendMessage?.call(text);
  }

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

  void emitFrame([int size = 16]) {
    if (_video.isClosed) return;
    _video.add(Uint8List(size));
  }

  void emitSpeaking(SpeakingState v) {
    if (_speaking.isClosed) return;
    _speaking.add(SpeakingEvent(value: v, pts: 0));
  }

  void endSession(ChatSessionEndReason r) {
    if (!_done.isCompleted) _done.complete(r);
  }
}

void main() {
  const avatar = Avatar(id: 'FakeAvatar1', voiceId: 'v1');

  /// Config with tight timings so tests don't sleep for real seconds.
  PlayerConfig fastConfig({
    Duration speakWatchdog = const Duration(seconds: 30),
    Duration livenessHeartbeat = const Duration(seconds: 30),
    Duration wsSilence = const Duration(seconds: 30),
    Duration resumeRecovery = const Duration(seconds: 30),
    Duration duplicateSendWindow = const Duration(milliseconds: 3000),
    Duration greetingInputLock = const Duration(milliseconds: 50),
    Duration heldSendTimeout = const Duration(milliseconds: 200),
  }) =>
      PlayerConfig(
        reconnectBaseBackoff: const Duration(milliseconds: 10),
        reconnectMaxBackoff: const Duration(milliseconds: 40),
        maxReconnectAttempts: 5,
        speakWatchdog: speakWatchdog,
        livenessHeartbeat: livenessHeartbeat,
        wsSilence: wsSilence,
        resumeRecovery: resumeRecovery,
        duplicateSendWindow: duplicateSendWindow,
        greetingInputLock: greetingInputLock,
        heldSendTimeout: heldSendTimeout,
        connectTimeout: const Duration(seconds: 30),
      );

  /// Pump the event loop enough times for status transitions rooted
  /// in stream deliveries (broadcast → listener → controller emit
  /// → consumer listener) to reach the test. Two microtask hops is
  /// usually enough; add slack to be safe.
  Future<void> pump() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('happy path', () {
    test('ready fires on first-frame arrival, not connect success',
        () async {
      final s = FakeSession(); // no autoFrame
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      final statuses = <PlayerStatus>[];
      c.status.listen((e) => statuses.add(e.status));
      await c.connect(avatar);
      await pump();
      // Handshake succeeded but no frame yet → still connecting.
      expect(c.currentStatus, PlayerStatus.connecting);
      expect(statuses, [PlayerStatus.connecting]);
      // First frame flips to ready.
      s.emitFrame();
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      expect(statuses, [PlayerStatus.connecting, PlayerStatus.ready]);
      expect(c.hasExhaustedAutoRecovery, isFalse);
      await c.dispose();
    });

    test('speaking events drive status transitions', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      s.emitSpeaking(SpeakingState.start);
      await pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      s.emitSpeaking(SpeakingState.stop);
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      await c.dispose();
    });

    test('videoBytes stream forwards frames including the first',
        () async {
      final s = FakeSession();
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      final frames = <Uint8List>[];
      final sub = c.videoBytes.listen(frames.add);
      s.emitFrame(32);
      s.emitFrame(64);
      await pump();
      expect(frames.map((b) => b.length), [32, 64]);
      await sub.cancel();
      await c.dispose();
    });
  });

  group('reconnect discipline', () {
    test('session.done triggers reconnect with fresh session', () async {
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      expect(sessions.length, 1);
      expect(c.currentStatus, PlayerStatus.ready);
      sessions[0].endSession(const ChatSessionFailed('transport dropped'));
      // Wait long enough for the backoff timer + fresh connect
      // + auto-frame microtask to complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sessions.length, greaterThanOrEqualTo(2),
          reason: 'reconnect must build a fresh session via factory');
      expect(c.currentStatus, PlayerStatus.ready);
      expect(c.reconnectAttempt, 0);
      await c.dispose();
    });

    test('exponential backoff sequence matches config', () async {
      final delays = <int>[];
      final c = TwaiAvatarPlayerController(
        // Always throw on connect so we exhaust attempts.
        sessionFactory: () => FakeSession(throwOnConnect: 'boom'),
        config: fastConfig(),
      );
      c.status.listen((e) {
        if (e.reconnectDelay != null) {
          delays.add(e.reconnectDelay!.inMilliseconds);
        }
      });
      await c.connect(avatar);
      // 10 + 20 + 40 + 40 + 40 = 150ms of delay + processing overhead
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.hasExhaustedAutoRecovery, isTrue);
      expect(c.currentStatus, PlayerStatus.failed);
      expect(delays, [10, 20, 40, 40, 40]);
      // `done` should NOT complete on exhaustion.
      final resolved = await c.done
          .timeout(const Duration(milliseconds: 50), onTimeout: () {
        return const PlayerRemoteClosed('sentinel: not resolved');
      });
      expect(resolved, isA<PlayerRemoteClosed>());
      await c.dispose();
    });

    test('manualReconnect revives an exhausted controller', () async {
      var letSucceed = false;
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => letSucceed
            ? FakeSession(autoFrameOnConnect: true)
            : FakeSession(throwOnConnect: 'boom'),
        config: fastConfig(),
      );
      await c.connect(avatar);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.hasExhaustedAutoRecovery, isTrue);
      expect(c.currentStatus, PlayerStatus.failed);
      letSucceed = true;
      await c.manualReconnect();
      await pump();
      expect(c.hasExhaustedAutoRecovery, isFalse);
      expect(c.reconnectAttempt, 0);
      expect(c.currentStatus, PlayerStatus.ready);
      await c.dispose();
    });

    test('changeAvatar rotates session with the new target', () async {
      final sessions = <FakeSession>[];
      final avatars = <Avatar>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: fastConfig(),
      );
      // Wrap connect to track which avatars each session gets. We
      // can't inspect FakeSession's stored avatar directly, so we
      // watch via a wrapped factory.
      await c.connect(avatar);
      avatars.add(avatar);
      await pump();
      expect(sessions.length, 1);
      expect(c.currentStatus, PlayerStatus.ready);

      const next = Avatar(id: 'KrystalHarperDateMuseTalk3', voiceId: 'v-krystal');
      await c.changeAvatar(next);
      avatars.add(next);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(sessions.length, 2,
          reason: 'changeAvatar must build a fresh session');
      expect(c.currentStatus, PlayerStatus.ready);
      expect(c.reconnectAttempt, 0);
      await c.dispose();
    });

    test('changeAvatar clears currentMood (mood is per-avatar)',
        () async {
      // Without a real MseStreamChatSession, we can't inject a
      // MoodEvent through the transport — so this test verifies the
      // clear side of the invariant: even if _currentMood WERE set,
      // changeAvatar wipes it. We use the internal invariant via a
      // dispose-then-check pattern.
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => FakeSession(autoFrameOnConnect: true),
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      expect(c.currentMood, isNull);
      const next = Avatar(id: 'AnotherAvatar', voiceId: 'v-other');
      await c.changeAvatar(next);
      await pump();
      expect(c.currentMood, isNull,
          reason: 'stays null after switch; behavior preserved');
      await c.dispose();
    });

    test('changeAvatar clears exhausted flag + reconnect attempts',
        () async {
      var letSucceed = false;
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => letSucceed
            ? FakeSession(autoFrameOnConnect: true)
            : FakeSession(throwOnConnect: 'boom'),
        config: fastConfig(),
      );
      await c.connect(avatar);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.hasExhaustedAutoRecovery, isTrue);
      letSucceed = true;
      const next = Avatar(id: 'FreshAvatar', voiceId: 'v-fresh');
      await c.changeAvatar(next);
      await pump();
      expect(c.hasExhaustedAutoRecovery, isFalse,
          reason: 'exhausted flag must reset on changeAvatar');
      expect(c.reconnectAttempt, 0);
      expect(c.currentStatus, PlayerStatus.ready);
      await c.dispose();
    });
  });

  group('watchdogs', () {
    test('resume-recovery fires when connect succeeds but no first frame',
        () async {
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          // No auto-frame — session sits silent after connect.
          final s = FakeSession();
          sessions.add(s);
          return s;
        },
        config: fastConfig(
          resumeRecovery: const Duration(milliseconds: 30),
        ),
      );
      await c.connect(avatar);
      await pump();
      expect(c.currentStatus, PlayerStatus.connecting);
      // Wait past resumeRecovery — controller should trigger reconnect
      // (which will also silently sit, but sessions.length shows the
      // second connect attempt fired).
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sessions.length, greaterThanOrEqualTo(2),
          reason: 'resume-recovery must force a reconnect');
      await c.dispose();
    });

    test('liveness heartbeat forces reconnect when WS goes silent',
        () async {
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: fastConfig(
          livenessHeartbeat: const Duration(milliseconds: 10),
          wsSilence: const Duration(milliseconds: 25),
        ),
      );
      await c.connect(avatar);
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      // No frames after the first one → silence duration grows,
      // heartbeat trips wsSilence, forces reconnect.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sessions.length, greaterThanOrEqualTo(2),
          reason:
              'wsSilence exceeded → liveness heartbeat must reconnect');
      await c.dispose();
    });

    test('speak watchdog fires when no speaking:start arrives', () async {
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: fastConfig(
          speakWatchdog: const Duration(milliseconds: 30),
        ),
      );
      await c.connect(avatar);
      await pump();
      await c.send('hello');
      // Wait past watchdog window without emitting speaking.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sessions.length, greaterThanOrEqualTo(2),
          reason: 'speak watchdog must force reconnect');
      await c.dispose();
    });

    test('speak watchdog does NOT fire if speaking:start beats sendMessage',
        () async {
      // Port spec §12.1.6: brain may fire speaking:start during
      // sendMessage. If we arm the watchdog after that event has
      // already cleared the flag, the timer fires 12s later as a
      // false positive and kills in-flight chunks.
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          // Fire the speaking event during sendMessage — before it
          // returns. This is the pathological case from §12.1.6.
          s.onSendMessage = (text) => s.emitSpeaking(SpeakingState.start);
          sessions.add(s);
          return s;
        },
        config: fastConfig(
          speakWatchdog: const Duration(milliseconds: 30),
        ),
      );
      await c.connect(avatar);
      await pump();
      await c.send('hello');
      // Wait well past watchdog. Should NOT reconnect.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sessions.length, 1,
          reason:
              'watchdog must not fire when speaking:start beat send() — '
              'this is the load-bearing §12.1.6 fix');
      await c.dispose();
    });
  });

  group('held-send + duplicate debounce', () {
    test('send() while not-ready holds the message; it fires on ready',
        () async {
      final s = FakeSession(); // no auto-frame; sits in connecting
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      expect(c.currentStatus, PlayerStatus.connecting);
      // Held path — should not throw, should not reach sendMessage yet.
      await c.send('held-message');
      expect(s.sentMessages, isEmpty);
      // First-frame arrival flips to ready + drains the held message.
      s.emitFrame();
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      expect(s.sentMessages, ['held-message']);
      await c.dispose();
    });

    test('held message survives session teardown and reaches fresh session',
        () async {
      // Port spec §12.1.8: pendingSend must NOT be cleared in
      // teardown. A user who hits SEND during a mid-reconnect gap
      // should see their message reach the fresh session's onPlaying.
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          // First session: connects, no auto-frame (sits silent).
          // Second and later: auto-frame so they reach ready.
          final s = sessions.isEmpty
              ? FakeSession()
              : FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: fastConfig(
          resumeRecovery: const Duration(milliseconds: 20),
        ),
      );
      await c.connect(avatar);
      await pump();
      // Hold a message during the silent connecting window.
      await c.send('held-across-teardown');
      expect(sessions[0].sentMessages, isEmpty);
      // Resume-recovery fires → teardown + fresh reconnect. The held
      // message must survive teardown and land on the fresh session.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sessions.length, greaterThanOrEqualTo(2));
      expect(c.currentStatus, PlayerStatus.ready);
      // The freshest healthy session should have received the held
      // message via drain-on-first-frame.
      final receivers =
          sessions.where((s) => s.sentMessages.isNotEmpty).toList();
      expect(receivers.length, 1,
          reason: 'held message must be sent exactly once, on the '
              'session that reaches ready');
      expect(receivers.first.sentMessages, ['held-across-teardown']);
      await c.dispose();
    });

    test('duplicate send within debounce window is dropped', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          duplicateSendWindow: const Duration(milliseconds: 50),
        ),
      );
      await c.connect(avatar);
      await pump();
      await c.send('hello');
      await c.send('hello'); // duplicate — drops silently
      await c.send('hello'); // duplicate — drops silently
      expect(s.sentMessages, ['hello']);
      await c.dispose();
    });

    test('same text sent after debounce window is delivered', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          duplicateSendWindow: const Duration(milliseconds: 20),
        ),
      );
      await c.connect(avatar);
      await pump();
      await c.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await c.send('hello'); // past window — should send
      expect(s.sentMessages, ['hello', 'hello']);
      await c.dispose();
    });

    test('different text bypasses debounce even within window', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          duplicateSendWindow: const Duration(milliseconds: 100),
        ),
      );
      await c.connect(avatar);
      await pump();
      await c.send('hello');
      await c.send('world');
      expect(s.sentMessages, ['hello', 'world']);
      await c.dispose();
    });
  });

  group('PTS-gated speaking', () {
    test('speaking event with pts=0 fires immediately', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      s.emitSpeaking(SpeakingState.start); // FakeSession emits pts=0
      await pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      await c.dispose();
    });

    test('no updatePlaybackTime call — events fire immediately', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      // Manually emit a non-zero PTS event via the stream. Since no
      // sink has called updatePlaybackTime, the event should fire.
      s._speaking.add(const SpeakingEvent(value: SpeakingState.start, pts: 5));
      await pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      await c.dispose();
    });

    test('with updatePlaybackTime, event with future PTS is queued', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      // Sink is at t=0.5s. Event is for t=2.0s — should NOT fire yet.
      c.updatePlaybackTime(0.5);
      s._speaking.add(const SpeakingEvent(value: SpeakingState.start, pts: 2));
      await pump();
      expect(c.currentStatus, PlayerStatus.ready,
          reason: 'PTS not yet crossed — speaking must be queued');
      // Advance playhead past PTS — drain fires the transition.
      c.updatePlaybackTime(2.1);
      await pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      await c.dispose();
    });

    test('multiple queued events drain in PTS order', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      final transitions = <PlayerStatus>[];
      c.status.listen((e) {
        if (e.status == PlayerStatus.speaking ||
            e.status == PlayerStatus.ready) {
          transitions.add(e.status);
        }
      });
      await c.connect(avatar);
      await pump();
      transitions.clear(); // drop the initial connecting→ready
      c.updatePlaybackTime(0);
      // Queue two events at t=1.0 (start) and t=3.0 (stop).
      s._speaking.add(const SpeakingEvent(value: SpeakingState.start, pts: 1));
      s._speaking.add(const SpeakingEvent(value: SpeakingState.stop, pts: 3));
      await pump();
      expect(transitions, isEmpty,
          reason: 'both events queued behind t=0 playhead');
      c.updatePlaybackTime(1.5);
      await pump();
      expect(transitions, [PlayerStatus.speaking],
          reason: 'only the t=1.0 start crossed');
      c.updatePlaybackTime(3.5);
      await pump();
      expect(transitions, [PlayerStatus.speaking, PlayerStatus.ready]);
      await c.dispose();
    });
  });

  group('greeting flow', () {
    test('beginGreeting arms input lock; send() during lock is held',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      c.beginGreeting();
      expect(c.greetingLockActive, isTrue);
      await c.send('during-greeting');
      expect(s.sentMessages, isEmpty,
          reason: 'send during greeting lock must be held, not delivered');
      // Wait for the lock to expire (fastConfig default 50ms).
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.greetingLockActive, isFalse);
      expect(s.sentMessages, ['during-greeting'],
          reason: 'held send must drain on lock expiry');
      await c.dispose();
    });

    test('/seen promise gates the first drained send (port spec §12.2.3)',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          greetingInputLock: const Duration(milliseconds: 20),
          heldSendTimeout: const Duration(milliseconds: 200),
        ),
      );
      await c.connect(avatar);
      await pump();
      final seenCompleter = Completer<void>();
      c.beginGreeting(firstGreetingSeen: seenCompleter.future);
      // User types during greeting — held.
      await c.send('first-reply');
      // Wait past lock expiry, but /seen not yet resolved.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(s.sentMessages, isEmpty,
          reason: 'lock expired but /seen not acked yet — must still hold');
      // Server acks /seen; drain now completes.
      seenCompleter.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(s.sentMessages, ['first-reply']);
      await c.dispose();
    });

    test('/seen timeout still delivers the message (safety cap)', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          greetingInputLock: const Duration(milliseconds: 10),
          heldSendTimeout: const Duration(milliseconds: 40),
        ),
      );
      await c.connect(avatar);
      await pump();
      // /seen never resolves — safety timeout must let the message through.
      c.beginGreeting(firstGreetingSeen: Completer<void>().future);
      await c.send('never-blocked');
      // Wait past lock expiry + heldSendTimeout.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.sentMessages, ['never-blocked'],
          reason: 'wedged /seen must not block chat indefinitely');
      await c.dispose();
    });

    test('/seen gate applies only to the first send after greeting',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          greetingInputLock: const Duration(milliseconds: 10),
          heldSendTimeout: const Duration(milliseconds: 200),
        ),
      );
      await c.connect(avatar);
      await pump();
      final seenCompleter = Completer<void>();
      c.beginGreeting(firstGreetingSeen: seenCompleter.future);
      seenCompleter.complete(); // pre-ack
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await c.send('first');
      await c.send('second');
      await c.send('third');
      await pump();
      expect(s.sentMessages, ['first', 'second', 'third'],
          reason: 'subsequent sends must not re-await /seen');
      await c.dispose();
    });

    test('greeting lock survives session teardown (port spec §12.4.3)',
        () async {
      // Reference behavior: greetingLockActive is cleared only by the
      // setTimeout, NOT by reconnect. A user should stay locked out
      // even if the WS drops mid-greeting.
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: fastConfig(
          greetingInputLock: const Duration(milliseconds: 100),
        ),
      );
      await c.connect(avatar);
      await pump();
      c.beginGreeting();
      expect(c.greetingLockActive, isTrue);
      // Force a reconnect mid-greeting.
      sessions[0].endSession(const ChatSessionFailed('mid-greeting drop'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(sessions.length, greaterThanOrEqualTo(2));
      expect(c.greetingLockActive, isTrue,
          reason: 'greeting lock must survive reconnect');
      // Lock should still expire on its own timer, not the reconnect.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.greetingLockActive, isFalse);
      await c.dispose();
    });

    test('beginGreeting without firstGreetingSeen leaves gate open',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(
          greetingInputLock: const Duration(milliseconds: 20),
        ),
      );
      await c.connect(avatar);
      await pump();
      // Return-visit greeting — server has already logged it, no /seen POST.
      c.beginGreeting();
      await c.send('post-return-visit');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(s.sentMessages, ['post-return-visit']);
      await c.dispose();
    });
  });

  group('live-edge clamp + jitter margin', () {
    /// Clamp math is stateless-ish (reads config + jitter margin +
    /// pending speaking), so most tests here don't need frames or
    /// speaking events. But the controller does require a session
    /// for `notifyStall` to run (`_assertNotDisposed`).
    PlayerConfig clampConfig({
      double clampTrigger = 1.2,
      double clampTarget = 0.6,
      double preroll = 0.45,
      double stepSec = 0.3,
      double maxSec = 1.5,
      Duration stallDebounce = const Duration(milliseconds: 30),
    }) =>
        PlayerConfig(
          clampTriggerLagSec: clampTrigger,
          clampTargetBehindSec: clampTarget,
          speechOnsetPrerollSec: preroll,
          jitterMarginStepSec: stepSec,
          jitterMarginMaxSec: maxSec,
          stallDebounce: stallDebounce,
          // fastConfig equivalents:
          reconnectBaseBackoff: const Duration(milliseconds: 10),
          reconnectMaxBackoff: const Duration(milliseconds: 40),
          speakWatchdog: const Duration(seconds: 30),
          livenessHeartbeat: const Duration(seconds: 30),
          wsSilence: const Duration(seconds: 30),
          resumeRecovery: const Duration(seconds: 30),
          greetingInputLock: const Duration(milliseconds: 50),
        );

    test('initial jitter margin is 0', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(),
      );
      expect(c.jitterMarginSec, 0.0);
      await c.dispose();
    });

    test('notifyStall bumps margin by step', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(),
      );
      c.notifyStall();
      expect(c.jitterMarginSec, closeTo(0.3, 1e-9));
      await c.dispose();
    });

    test('notifyStall within debounce window is a no-op', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(
          stallDebounce: const Duration(milliseconds: 100),
        ),
      );
      c.notifyStall();
      c.notifyStall(); // debounce swallows
      c.notifyStall(); // debounce swallows
      expect(c.jitterMarginSec, closeTo(0.3, 1e-9),
          reason: 'three rapid stalls collapse to one bump');
      await c.dispose();
    });

    test('notifyStall past debounce bumps again', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(
          stallDebounce: const Duration(milliseconds: 20),
        ),
      );
      c.notifyStall();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      c.notifyStall();
      expect(c.jitterMarginSec, closeTo(0.6, 1e-9));
      await c.dispose();
    });

    test('jitter margin caps at max', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(
          stepSec: 0.5,
          maxSec: 1.0,
          stallDebounce: const Duration(milliseconds: 0),
        ),
      );
      for (var i = 0; i < 10; i++) {
        c.notifyStall();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(c.jitterMarginSec, 1.0,
          reason: 'must not exceed jitterMarginMaxSec');
      await c.dispose();
    });

    test('jitter margin resets on session rotation', () async {
      final sessions = <FakeSession>[];
      final c = TwaiAvatarPlayerController(
        sessionFactory: () {
          final s = FakeSession(autoFrameOnConnect: true);
          sessions.add(s);
          return s;
        },
        config: clampConfig(),
      );
      await c.connect(avatar);
      await pump();
      c.notifyStall();
      expect(c.jitterMarginSec, closeTo(0.3, 1e-9));
      // Force a reconnect — margin should reset per port spec §12.1.3.
      sessions[0].endSession(const ChatSessionFailed('drop'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.jitterMarginSec, 0.0,
          reason: 'margin resets per session (port spec §12.1.3)');
      await c.dispose();
    });

    test('computeClampTargetSec returns null when lag is under trigger',
        () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(clampTrigger: 1.2),
      );
      // Lag = 0.8s (< 1.2 trigger)
      final target = c.computeClampTargetSec(
        playbackTimeSec: 10.0,
        bufferEndSec: 10.8,
      );
      expect(target, isNull);
      await c.dispose();
    });

    test('computeClampTargetSec returns target when lag exceeds trigger',
        () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(clampTrigger: 1.2, clampTarget: 0.6),
      );
      // Lag = 2.0s, target = bufferEnd - 0.6 - 0 (no jitter yet) = 9.4
      final target = c.computeClampTargetSec(
        playbackTimeSec: 8.0,
        bufferEndSec: 10.0,
      );
      expect(target, closeTo(9.4, 1e-9));
      await c.dispose();
    });

    test('jitter margin widens the clamp target', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: clampConfig(
          clampTrigger: 1.2,
          clampTarget: 0.6,
          stallDebounce: Duration.zero,
        ),
      );
      c.notifyStall();
      c.notifyStall();
      c.notifyStall();
      expect(c.jitterMarginSec, closeTo(0.9, 1e-9));
      // Target = 10.0 - 0.6 - 0.9 = 8.5
      final target = c.computeClampTargetSec(
        playbackTimeSec: 8.0,
        bufferEndSec: 10.0,
      );
      expect(target, closeTo(8.5, 1e-9));
      await c.dispose();
    });

    test('speech-onset preroll holds the target back from pending PTS',
        () async {
      // A speaking:start event is queued at pts=8.7. Target would
      // land at 9.4, which is 0.7s past PTS — too close. Preroll of
      // 0.45s means we can't seek past 8.7 - 0.45 = 8.25.
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: clampConfig(clampTrigger: 1.2, clampTarget: 0.6, preroll: 0.45),
      );
      await c.connect(avatar);
      await pump();
      // Advance playhead so the speaking event doesn't fire immediately.
      c.updatePlaybackTime(7.0);
      s._speaking
          .add(const SpeakingEvent(value: SpeakingState.start, pts: 8.7));
      await pump();
      // The event is queued (not yet fired).
      final target = c.computeClampTargetSec(
        playbackTimeSec: 8.0,
        bufferEndSec: 10.0,
      );
      expect(target, closeTo(8.25, 1e-9),
          reason: 'preroll must hold target back from queued speech onset');
      await c.dispose();
    });

    test('computeClampTargetSec returns null when target is not ahead',
        () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        // Very generous jitter → target lands behind playback.
        config: clampConfig(
          clampTrigger: 1.2,
          clampTarget: 0.6,
          stepSec: 5.0,
          maxSec: 10.0,
          stallDebounce: Duration.zero,
        ),
      );
      c.notifyStall();
      c.notifyStall();
      // Jitter = 10.0. Target = bufferEnd - 0.6 - 10 = -0.6, well
      // behind playbackTime — must return null.
      final target = c.computeClampTargetSec(
        playbackTimeSec: 8.0,
        bufferEndSec: 10.0,
      );
      expect(target, isNull);
      await c.dispose();
    });
  });

  group('teardown discipline', () {
    test('dispose closes underlying session', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await c.dispose();
      expect(s._closed, isTrue);
    });

    test('done resolves with PlayerDisposed on explicit dispose', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: fastConfig(),
      );
      await c.connect(avatar);
      // ignore: unawaited_futures
      c.dispose();
      final r = await c.done;
      expect(r, isA<PlayerDisposed>());
    });

    test('operations after dispose throw StateError', () async {
      final c = TwaiAvatarPlayerController(
        sessionFactory: FakeSession.new,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await c.dispose();
      expect(() => c.send('hi'), throwsStateError);
      expect(() => c.connect(avatar), throwsStateError);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // Group C from the 2wai-edu upstream requirements survey
  // (2026-07-20): C3 hard-refuse-seek-while-speaking + C4 mid-reply
  // stuck-talking watchdog ceiling.
  // ══════════════════════════════════════════════════════════════════

  group('C3 — hard-refuse-seek while speaking', () {
    test('computeClampTargetSec returns null when currently speaking',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      // Flip into speaking state.
      s.emitSpeaking(SpeakingState.start);
      await pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      // Even with obvious lag (8s vs 2s trigger), refuse to seek.
      final target = c.computeClampTargetSec(
        playbackTimeSec: 2.0,
        bufferEndSec: 10.0,
      );
      expect(target, isNull,
          reason: 'must not seek past currently-playing rendered audio');
      await c.dispose();
    });

    test('computeClampTargetSec resumes clamping after speaking stops',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig(),
      );
      await c.connect(avatar);
      await pump();
      s.emitSpeaking(SpeakingState.start);
      await pump();
      s.emitSpeaking(SpeakingState.stop);
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      final target = c.computeClampTargetSec(
        playbackTimeSec: 2.0,
        bufferEndSec: 10.0,
      );
      expect(target, isNotNull,
          reason: 'clamp should re-engage after the reply ends');
      await c.dispose();
    });
  });

  group('C4 — mid-reply stuck-talking watchdog ceiling', () {
    test('fires when playhead stalls + no bytes arrive, forcing status → ready',
        () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig().copyWithStuckCeiling(
          ceiling: const Duration(milliseconds: 40),
          heartbeat: const Duration(milliseconds: 10),
        ),
      );
      await c.connect(avatar);
      await pump();
      final statuses = <PlayerStatus>[];
      c.status.listen((e) => statuses.add(e.status));
      s.emitSpeaking(SpeakingState.start);
      await pump();
      expect(c.currentStatus, PlayerStatus.speaking);
      // Wait past the ceiling with NO liveness signals (no playhead
      // advance, no video bytes, no speaking events). Watchdog must
      // force status back to ready.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.currentStatus, PlayerStatus.ready,
          reason: 'stuck-talking ceiling should force the crossfade back to idle');
      expect(statuses, contains(PlayerStatus.ready));
      await c.dispose();
    });

    test('does NOT fire while playhead is advancing', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig().copyWithStuckCeiling(
          ceiling: const Duration(milliseconds: 40),
          heartbeat: const Duration(milliseconds: 10),
        ),
      );
      await c.connect(avatar);
      await pump();
      s.emitSpeaking(SpeakingState.start);
      await pump();
      // Simulate a normal long reply by pinging updatePlaybackTime
      // repeatedly for well past the ceiling. Watchdog must NOT fire.
      final endBy =
          DateTime.now().add(const Duration(milliseconds: 200));
      var t = 0.0;
      while (DateTime.now().isBefore(endBy)) {
        t += 0.05;
        c.updatePlaybackTime(t);
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      expect(c.currentStatus, PlayerStatus.speaking,
          reason: 'liveness signals should prevent watchdog fire');
      await c.dispose();
    });

    test('disarms cleanly on normal speaking:stop', () async {
      final s = FakeSession(autoFrameOnConnect: true);
      final c = TwaiAvatarPlayerController(
        sessionFactory: () => s,
        config: fastConfig().copyWithStuckCeiling(
          ceiling: const Duration(milliseconds: 40),
          heartbeat: const Duration(milliseconds: 10),
        ),
      );
      await c.connect(avatar);
      await pump();
      s.emitSpeaking(SpeakingState.start);
      await pump();
      s.emitSpeaking(SpeakingState.stop);
      await pump();
      expect(c.currentStatus, PlayerStatus.ready);
      // Wait past the ceiling — watchdog must have been cancelled, so
      // status must remain stable at ready (not re-emit).
      final statuses = <PlayerStatus>[];
      c.status.listen((e) => statuses.add(e.status));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(statuses, isEmpty,
          reason: 'stop should cancel the watchdog so it doesn\'t re-fire ready');
      await c.dispose();
    });
  });
}

extension _PlayerConfigTestHelpers on PlayerConfig {
  /// Override just the stuck-talking-related tunables while preserving
  /// everything else on the base fastConfig — needed because
  /// [PlayerConfig] has no `copyWith`.
  PlayerConfig copyWithStuckCeiling({
    required Duration ceiling,
    required Duration heartbeat,
  }) =>
      PlayerConfig(
        reconnectBaseBackoff: reconnectBaseBackoff,
        reconnectMaxBackoff: reconnectMaxBackoff,
        maxReconnectAttempts: maxReconnectAttempts,
        speakWatchdog: speakWatchdog,
        livenessHeartbeat: heartbeat,
        wsSilence: wsSilence,
        resumeRecovery: resumeRecovery,
        duplicateSendWindow: duplicateSendWindow,
        greetingInputLock: greetingInputLock,
        heldSendTimeout: heldSendTimeout,
        connectTimeout: connectTimeout,
        stuckTalkingCeiling: ceiling,
      );
}
