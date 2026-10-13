import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// Minimal ChatSession fake. Auto-emits a frame on connect so the
/// controller reaches `ready` and `send()` is not held. Records every
/// `sendMessage` call with its params for assertions.
class _FakeSession implements ChatSession {
  final _video = StreamController<Uint8List>.broadcast();
  final _speaking = StreamController<SpeakingEvent>.broadcast();
  final _reply = StreamController<String>.broadcast();
  final _done = Completer<ChatSessionEndReason>();
  bool _connected = false;
  bool _closed = false;

  final List<_SentMessage> sent = [];

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
      {num? gamificationLevel, Object? avatarStateBlock}) async {
    sent.add(_SentMessage(
      text: text,
      gamificationLevel: gamificationLevel,
      avatarStateBlock: avatarStateBlock,
    ));
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

  void emitReply(String text) => _reply.add(text);
}

class _SentMessage {
  const _SentMessage({
    required this.text,
    this.gamificationLevel,
    this.avatarStateBlock,
  });
  final String text;
  final num? gamificationLevel;
  final Object? avatarStateBlock;
}

/// Pump the event queue so stream deliveries + microtasks settle.
Future<void> _pump([int hops = 6]) async {
  for (var i = 0; i < hops; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A tiny fake HTTP client that captures every request and lets the
/// test decide the response. Uses `package:http/testing.dart`'s
/// `MockClient` so we don't need to hand-roll the interface. Response
/// bodies are typed `Object` so a route can return either a JSON map
/// (`/progress/*`) or a JSON list (`/gestures`, `/frames`).
MockClient _mockRoutes({
  Map<String, Object>? getJson,
  Map<String, Object>? postJson,
  List<String>? captureGetPaths,
  List<String>? capturePostPaths,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET') {
      captureGetPaths?.add(path);
      final body = getJson?[path];
      if (body == null) return http.Response('not found', 404);
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'POST') {
      capturePostPaths?.add(path);
      final body = postJson?[path];
      if (body == null) return http.Response('not found', 404);
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not implemented', 501);
  });
}

const _krystal = PlayerAvatar(
  slug: 'krystal-harper',
  name: 'Krystal Harper',
  tagline: 'Sharp, intuitive',
  voiceId: 'v-krystal',
  outfits: [
    PlayerOutfit(
      slug: 'casual',
      name: 'Casual',
      pipelineName: 'KrystalHarperMuseTalk3',
      idleUrl: 'https://cdn/idle.mp4',
    ),
  ],
);

void main() {
  group('TwaiApiClient', () {
    test('fetchProgress decodes PetProgress on 200', () async {
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        authToken: 'jwt-abc',
        httpClient: _mockRoutes(getJson: {
          '/api/gamification/progress/avatar/krystal-harper': {
            'pet': {
              'id': 'p1',
              'slug': 'krystal-harper',
              'name': 'Krystal',
              'thumbnail_url': null,
              'level_cap': 30,
              'sort_order': 0,
            },
            'current_level': 3,
            'current_xp_in_level': 15,
            'xp_required_to_next': 40,
            'lifetime_xp': 195,
            'messages_sent': 7,
            'at_cap': false,
            'streak_count': 2,
            'streak_longest': 5,
          },
        }),
      );
      final p = await client.fetchProgress('krystal-harper');
      expect(p, isNotNull);
      expect(p!.currentLevel, 3);
      expect(p.currentXpInLevel, 15);
      expect(p.xpRequiredToNext, 40);
      expect(p.lifetimeXp, 195);
      expect(p.streakCount, 2);
      client.close();
    });

    test('fetchProgress returns null on error', () async {
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockRoutes(), // 404 for everything
      );
      final p = await client.fetchProgress('krystal-harper');
      expect(p, isNull);
      client.close();
    });

    test('fetchGestures decodes into PlayerGesture list', () async {
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/avatars/krystal-harper/gestures') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'g1',
                  'slug': 'wave',
                  'display_name': 'Wave',
                  'video_url': 'https://cdn/wave.mp4',
                  'thumbnail_url': 'https://cdn/wave.jpg',
                  'is_unlocked': true,
                  'unlock_level': null,
                  'outfit_slug': null,
                },
                {
                  'id': 'g2',
                  'slug': 'kiss',
                  'display_name': 'Blows Kiss',
                  'video_url': '',
                  'thumbnail_url': null,
                  'is_unlocked': false,
                  'unlock_level': 5,
                  'outfit_slug': 'casual',
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('nf', 404);
        }),
      );
      final list = await client.fetchGestures('krystal-harper');
      expect(list, hasLength(2));
      expect(list[0].slug, 'wave');
      expect(list[0].isUnlocked, isTrue);
      expect(list[1].slug, 'kiss');
      expect(list[1].isUnlocked, isFalse);
      expect(list[1].unlockLevel, 5);
      expect(list[1].outfitSlug, 'casual');
      client.close();
    });

    test('awardMessage POSTs and decodes AwardMessageResponse', () async {
      final capturedPaths = <String>[];
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        authToken: 'jwt-abc',
        httpClient: _mockRoutes(
          capturePostPaths: capturedPaths,
          postJson: {
            '/api/gamification/award-message': {
              'pet': {
                'id': 'p1',
                'slug': 'krystal-harper',
                'name': 'K',
                'level_cap': 30,
              },
              'xp_awarded': 15,
              'band': 'medium',
              'quality_score': 0.72,
              'current_level': 4,
              'current_xp_in_level': 12,
              'xp_required_to_next': 60,
              'leveled_up': true,
              'level_before': 3,
              'level_after': 4,
              'rewards_unlocked': [
                {
                  'id': 'r1',
                  'type': 'outfit',
                  'name': 'Date',
                  'asset_reference': 'krystal-harper-date',
                  'level': 4,
                  'thumbnail_url': null,
                },
              ],
              'at_cap': false,
            },
          },
        ),
      );
      final r = await client.awardMessage(
        avatarSlug: 'krystal-harper',
        message: 'hi',
      );
      expect(r, isNotNull);
      expect(r!.xpAwarded, 15);
      expect(r.band, XpBand.medium);
      expect(r.leveledUp, isTrue);
      expect(r.currentLevel, 4);
      expect(r.rewardsUnlocked, hasLength(1));
      expect(r.rewardsUnlocked.first.name, 'Date');
      expect(capturedPaths, ['/api/gamification/award-message']);
      client.close();
    });

    test('fetchStateBlock returns null on 404', () async {
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockRoutes(),
      );
      expect(await client.fetchStateBlock('krystal-harper'), isNull);
      client.close();
    });
  });

  group('TwaiPlayerHandle skeleton', () {
    test('constructor kicks off auto-connect + auto-fetch when default',
        () async {
      final capturedGetPaths = <String>[];
      final apiClient = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockRoutes(
          captureGetPaths: capturedGetPaths,
          getJson: {
            '/api/gamification/progress/avatar/krystal-harper': {
              'pet': {
                'id': 'p1',
                'slug': 'krystal-harper',
                'name': 'K',
                'thumbnail_url': null,
                'level_cap': 30,
                'sort_order': 0,
              },
              'current_level': 3,
              'current_xp_in_level': 15,
              'xp_required_to_next': 40,
              'lifetime_xp': 195,
              'messages_sent': 7,
              'at_cap': false,
            },
            '/api/avatars/krystal-harper/gestures': [],
            '/api/avatars/krystal-harper/frames': [],
          },
        ),
      );

      final player = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        // Skip network for the pipeline WS — we're testing the facade
        // wiring, not real connect. autoConnect will still kick off
        // the /api/* fetch fanout.
        autoConnect: false,
        apiClient: apiClient,
      );

      // Manually kick the fetch fanout via connect() so we can await
      // it. The pipeline WS will fail against a real network but the
      // fanout runs regardless.
      // ignore: unawaited_futures
      player.connect().catchError((_) {});
      // Give the microtask queue time to run the fetches.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(capturedGetPaths, containsAll([
        '/api/gamification/progress/avatar/krystal-harper',
        '/api/avatars/krystal-harper/gestures',
        '/api/avatars/krystal-harper/frames',
      ]));
      expect(player.currentLevel, 3);

      await player.dispose();
    });

    test('explicit gestures/frames skip the auto-fetch', () async {
      final capturedGetPaths = <String>[];
      final apiClient = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockRoutes(captureGetPaths: capturedGetPaths),
      );

      final player = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        gestures: const [
          PlayerGesture(
            id: 'x1',
            slug: 'wave',
            displayName: 'Wave',
            videoUrl: 'https://custom/wave.mp4',
            isUnlocked: true,
          ),
        ],
        frames: const [],
        autoFetchProgress: false, // clean test — no fanout at all
        autoConnect: false,
        apiClient: apiClient,
      );

      // ignore: unawaited_futures
      player.connect().catchError((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(capturedGetPaths, isEmpty,
          reason: 'explicit gestures + explicit frames + '
              'autoFetchProgress:false → zero HTTP');
      expect(player.gestures, hasLength(1));
      expect(player.gestures.first.slug, 'wave');
      expect(player.frames, isEmpty);
      await player.dispose();
    });

    test('escape hatches expose controller + apiClient', () async {
      final apiClient = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockRoutes(),
      );
      final player = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        autoConnect: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchProgress: false,
        apiClient: apiClient,
      );
      expect(player.controller, isA<TwaiAvatarPlayerController>());
      expect(player.apiClient, same(apiClient));
      await player.dispose();
    });

    test('operations after dispose throw StateError', () async {
      final player = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        autoConnect: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchProgress: false,
      );
      await player.dispose();
      expect(() => player.send('hi'), throwsStateError);
      expect(() => player.connect(), throwsStateError);
    });
  });

  group('Phase 2 — send-time fanout', () {
    /// Boilerplate: build a handle with a captured API + fake session,
    /// connect it, wait for `ready`, and return the pieces.
    Future<
        ({
          TwaiPlayerHandle handle,
          _FakeSession session,
          List<String> gets,
          List<String> posts,
        })> makeReady({
      Map<String, Object>? getJson,
      Map<String, Object>? postJson,
      bool autoFetchGestures = false,
      bool autoFetchFrames = false,
      bool autoRecordReply = true,
    }) async {
      final gets = <String>[];
      final posts = <String>[];
      final session = _FakeSession();
      final handle = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        autoConnect: false, // subscribe before connect to avoid race
        autoFetchProgress: false,
        autoFetchGestures: autoFetchGestures,
        autoFetchFrames: autoFetchFrames,
        autoRecordReply: autoRecordReply,
        apiClient: TwaiApiClient(
          baseUrl: Uri.parse('https://staging.example.com'),
          httpClient: _mockRoutes(
            captureGetPaths: gets,
            capturePostPaths: posts,
            getJson: getJson,
            postJson: postJson,
          ),
        ),
        sessionFactory: () => session,
      );
      // Subscribe to the ready event BEFORE kicking off connect —
      // broadcast streams don't backfill missed events.
      final readyFuture = handle.status
          .firstWhere((e) => e.status == PlayerStatus.ready)
          .timeout(const Duration(milliseconds: 400));
      // ignore: unawaited_futures
      handle.connect();
      await readyFuture;
      return (handle: handle, session: session, gets: gets, posts: posts);
    }

    test('send fires state-block + award-message + controller.send',
        () async {
      final env = await makeReady(
        getJson: {
          '/api/avatars/krystal-harper/state-block': {
            'block': '## Avatar state\nmood: happy',
          },
        },
        postJson: {
          '/api/gamification/award-message': {
            'pet': {
              'id': 'p',
              'slug': 'krystal-harper',
              'name': 'K',
              'level_cap': 30,
            },
            'xp_awarded': 10,
            'band': 'low',
            'quality_score': 0.5,
            'current_level': 2,
            'current_xp_in_level': 20,
            'xp_required_to_next': 40,
            'leveled_up': false,
            'level_before': null,
            'level_after': null,
            'rewards_unlocked': [],
            'at_cap': false,
          },
        },
      );
      await env.handle.send('hi');
      await _pump();
      // Controller.send passed the fetched state-block inline.
      expect(env.session.sent, hasLength(1));
      expect(env.session.sent.first.text, 'hi');
      expect(env.session.sent.first.avatarStateBlock,
          '## Avatar state\nmood: happy');
      // Both auxiliary calls fired.
      expect(env.gets, contains('/api/avatars/krystal-harper/state-block'));
      expect(env.posts, contains('/api/gamification/award-message'));
      await env.handle.dispose();
    });

    test('autoFetchStateBlock:false skips state-block GET', () async {
      final gets = <String>[];
      final posts = <String>[];
      final session = _FakeSession();
      final handle = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        autoConnect: false,
        autoFetchProgress: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchStateBlock: false,
        apiClient: TwaiApiClient(
          baseUrl: Uri.parse('https://staging.example.com'),
          httpClient: _mockRoutes(
            captureGetPaths: gets,
            capturePostPaths: posts,
            postJson: {
              '/api/gamification/award-message': {
                'pet': {
                  'id': 'p',
                  'slug': 'krystal-harper',
                  'name': 'K',
                  'level_cap': 30,
                },
                'xp_awarded': 5,
                'band': 'low',
                'quality_score': 0.3,
                'current_level': 1,
                'current_xp_in_level': 0,
                'xp_required_to_next': 30,
                'leveled_up': false,
                'rewards_unlocked': [],
                'at_cap': false,
              },
            },
          ),
        ),
        sessionFactory: () => session,
      );
      final readyFuture = handle.status
          .firstWhere((e) => e.status == PlayerStatus.ready)
          .timeout(const Duration(milliseconds: 400));
      // ignore: unawaited_futures
      handle.connect();
      await readyFuture;
      await handle.send('hi');
      await _pump();
      expect(
          gets, isNot(contains('/api/avatars/krystal-harper/state-block')));
      await handle.dispose();
    });

    test('autoAwardXp:false skips award-message POST', () async {
      final gets = <String>[];
      final posts = <String>[];
      final session = _FakeSession();
      final handle = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        autoConnect: false,
        autoFetchProgress: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoAwardXp: false,
        apiClient: TwaiApiClient(
          baseUrl: Uri.parse('https://staging.example.com'),
          httpClient: _mockRoutes(
            captureGetPaths: gets,
            capturePostPaths: posts,
            getJson: {
              '/api/avatars/krystal-harper/state-block': {'block': 'x'},
            },
          ),
        ),
        sessionFactory: () => session,
      );
      final readyFuture = handle.status
          .firstWhere((e) => e.status == PlayerStatus.ready)
          .timeout(const Duration(milliseconds: 400));
      // ignore: unawaited_futures
      handle.connect();
      await readyFuture;
      await handle.send('hi');
      await _pump();
      expect(posts, isEmpty);
      await handle.dispose();
    });

    test('award-message response fires XpEvent on the handle',
        () async {
      final xpEvents = <XpEvent>[];
      final env = await makeReady(
        getJson: {
          '/api/avatars/krystal-harper/state-block': {'block': 'x'},
        },
        postJson: {
          '/api/gamification/award-message': {
            'pet': {
              'id': 'p',
              'slug': 'krystal-harper',
              'name': 'K',
              'level_cap': 30,
            },
            'xp_awarded': 25,
            'band': 'medium',
            'quality_score': 0.5,
            'current_level': 3,
            'current_xp_in_level': 10,
            'xp_required_to_next': 60,
            'leveled_up': false,
            'rewards_unlocked': [],
            'at_cap': false,
          },
        },
      );
      env.handle.xpEvents.listen(xpEvents.add);
      await env.handle.send('hi');
      // Let the awardFuture resolve + XP fire.
      await _pump(20);
      expect(xpEvents, hasLength(1));
      expect(xpEvents.first.amount, 25);
      expect(xpEvents.first.band, XpBand.medium);
      await env.handle.dispose();
    });

    test('leveled_up=true fires LevelUpEvent + refetches catalogs',
        () async {
      final env = await makeReady(
        autoFetchGestures: true,
        autoFetchFrames: true,
        getJson: {
          '/api/avatars/krystal-harper/state-block': {'block': 'x'},
          '/api/avatars/krystal-harper/gestures': [],
          '/api/avatars/krystal-harper/frames': [],
        },
        postJson: {
          '/api/gamification/award-message': {
            'pet': {
              'id': 'p',
              'slug': 'krystal-harper',
              'name': 'K',
              'level_cap': 30,
            },
            'xp_awarded': 40,
            'band': 'high',
            'quality_score': 0.9,
            'current_level': 4,
            'current_xp_in_level': 5,
            'xp_required_to_next': 60,
            'leveled_up': true,
            'level_before': 3,
            'level_after': 4,
            'rewards_unlocked': [
              {
                'id': 'r',
                'type': 'outfit',
                'name': 'Date',
                'asset_reference': 'krystal-harper-date',
                'level': 4,
                'thumbnail_url': null,
              },
            ],
            'at_cap': false,
          },
        },
      );
      final levelUps = <LevelUpEvent>[];
      env.handle.levelUpEvents.listen(levelUps.add);
      // Count baseline gesture/frame fetches from connect.
      final connectFetchCount = env.gets
          .where((p) =>
              p == '/api/avatars/krystal-harper/gestures' ||
              p == '/api/avatars/krystal-harper/frames')
          .length;
      await env.handle.send('hi');
      await _pump(30);
      expect(levelUps, hasLength(1));
      expect(levelUps.first.newLevel, 4);
      expect(levelUps.first.previousLevel, 3);
      expect(levelUps.first.rewardTitle, 'Date');
      expect(levelUps.first.sessionLevelUpIndex, 1);
      final refetchCount = env.gets
              .where((p) =>
                  p == '/api/avatars/krystal-harper/gestures' ||
                  p == '/api/avatars/krystal-harper/frames')
              .length -
          connectFetchCount;
      expect(refetchCount, 2,
          reason: 'level-up must refetch both gestures + frames');
      await env.handle.dispose();
    });

    test('reply text triggers record-assistant-message POST', () async {
      final env = await makeReady(
        getJson: {
          '/api/avatars/krystal-harper/state-block': {'block': 'x'},
        },
        postJson: {
          '/api/gamification/award-message': {
            'pet': {
              'id': 'p',
              'slug': 'krystal-harper',
              'name': 'K',
              'level_cap': 30,
            },
            'xp_awarded': 5,
            'band': 'low',
            'quality_score': 0.3,
            'current_level': 1,
            'current_xp_in_level': 0,
            'xp_required_to_next': 30,
            'leveled_up': false,
            'rewards_unlocked': [],
            'at_cap': false,
          },
          '/api/gamification/record-assistant-message': {'ok': true},
        },
      );
      await env.handle.send('hi');
      // Simulate the brain reply arriving on the wire.
      env.session.emitReply('Hi back!');
      await _pump(10);
      expect(env.posts,
          contains('/api/gamification/record-assistant-message'));
      await env.handle.dispose();
    });

    test('autoRecordReply:false skips record POST', () async {
      final gets = <String>[];
      final posts = <String>[];
      final session = _FakeSession();
      final handle = TwaiPlayerHandle(
        avatar: _krystal,
        env: TwaiEnvironment.twaiStaging,
        autoConnect: false,
        autoFetchProgress: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchStateBlock: false,
        autoAwardXp: false,
        autoRecordReply: false,
        apiClient: TwaiApiClient(
          baseUrl: Uri.parse('https://staging.example.com'),
          httpClient: _mockRoutes(
            captureGetPaths: gets,
            capturePostPaths: posts,
          ),
        ),
        sessionFactory: () => session,
      );
      final readyFuture = handle.status
          .firstWhere((e) => e.status == PlayerStatus.ready)
          .timeout(const Duration(milliseconds: 400));
      // ignore: unawaited_futures
      handle.connect();
      await readyFuture;
      await handle.send('hi');
      session.emitReply('reply');
      await _pump(10);
      expect(posts, isEmpty);
      await handle.dispose();
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // Regression 2026-07-21: staging /api/avatars/{slug}/state-block
  // stalled indefinitely, and TwaiPlayerHandle.send awaits it before
  // firing the chat POST — freezing the whole facade. Fix landed a
  // per-request timeout on TwaiApiClient (default 3s) so fail-open
  // means "fail within N seconds," not "wait forever hoping for a
  // response."
  // ══════════════════════════════════════════════════════════════════

  group('TwaiApiClient requestTimeout (facade send-hang regression)', () {
    test(
      'fetchStateBlock returns null (fail-open) when the server hangs '
      'past requestTimeout',
      () async {
        final client = TwaiApiClient(
          baseUrl: Uri.parse('https://staging.example.com'),
          requestTimeout: const Duration(milliseconds: 50),
          // MockClient that NEVER responds — completes a future the
          // test controls. Simulates the "endpoint accepts the
          // connection but never returns" wedge we hit on staging.
          httpClient: MockClient((req) {
            final never = Completer<http.Response>();
            return never.future;
          }),
        );
        final stopwatch = Stopwatch()..start();
        final result = await client.fetchStateBlock('krystal-harper');
        stopwatch.stop();
        expect(result, isNull,
            reason: 'timeout must return null, matching non-200 fail-open');
        expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(50));
        expect(stopwatch.elapsedMilliseconds, lessThan(500),
            reason: 'must not exceed requestTimeout by much');
        client.close();
      },
    );

    test(
      'TwaiPlayerHandle.send completes even when the state-block fetch '
      'hangs — reply from the underlying session still lands',
      () async {
        final session = _FakeSession();
        final client = TwaiApiClient(
          baseUrl: Uri.parse('https://staging.example.com'),
          requestTimeout: const Duration(milliseconds: 50),
          httpClient: MockClient((_) {
            final never = Completer<http.Response>();
            return never.future;
          }),
        );
        final handle = TwaiPlayerHandle(
          avatar: _krystal,
          env: TwaiEnvironment.twaiStaging,
          apiClient: client,
          autoFetchGestures: false,
          autoFetchFrames: false,
          autoFetchProgress: false,
          autoAwardXp: false,
          autoRecordReply: false,
          sessionFactory: () => session,
        );
        // Wait for the auto-connect + session to reach ready.
        await handle.status.firstWhere((e) => e.status == PlayerStatus.ready);
        await _pump();

        // Fire a send. If the timeout is broken, this future never
        // completes. With the timeout, it fires the chat POST after
        // ~50ms and returns.
        final sw = Stopwatch()..start();
        await handle.send('hello');
        sw.stop();
        expect(sw.elapsedMilliseconds, lessThan(500),
            reason:
                'send must not hang on a stalled state-block fetch');
        // Session got the send (proves the chain landed).
        expect(session.sent, isNotEmpty);
        expect(session.sent.last.text, 'hello');
        // Session's send call was passed a null avatarStateBlock
        // (fail-open from the timeout).
        expect(session.sent.last.avatarStateBlock, isNull);

        await handle.dispose();
      },
    );
  });
}
