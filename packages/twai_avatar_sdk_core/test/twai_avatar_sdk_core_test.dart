import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_core/src/adapters/mse_stream/mse_stream_errors.dart'
    show mseStreamCloseFor;

void main() {
  group('MseStreamConfig', () {
    test('toJson uses the protocol field names', () {
      const cfg = MseStreamConfig(
        sessionId: 'mse-1-2',
        avatarId: 'RedJesusTalk2',
        ttsSelection: 'tts5',
        avatarVoice: 'voice-uuid',
        streamType: 'AV',
      );
      expect(cfg.toJson(), {
        'session_id': 'mse-1-2',
        'avatar_id': 'RedJesusTalk2',
        'ttsSelection': 'tts5',
        'avatarVoice': 'voice-uuid',
        'stream_type': 'AV',
        // twai-protocol v1.1.0 handshake tolerated field.
        'protocolVersion': '1.1.0',
      });
    });

    test('defaults match protocol.md', () {
      const cfg = MseStreamConfig(sessionId: 'mse-1-2');
      expect(cfg.avatarId, 'default');
      expect(cfg.ttsSelection, 'tts5');
      expect(cfg.avatarVoice, 'default');
      expect(cfg.streamType, 'AV');
    });

    test('newSessionId matches mse-<epoch>-<rand6> format', () {
      final id = MseStreamConfig.newSessionId();
      expect(
        RegExp(r'^mse-\d{10,}-\d{6}$').hasMatch(id),
        isTrue,
        reason: 'got $id',
      );
    });
  });

  group('SpeakingEvent', () {
    test('parses start/stop with float pts', () {
      final start = SpeakingEvent.fromJson({
        'type': 'speaking',
        'value': 'start',
        'pts': 2.34,
      });
      expect(start.value, SpeakingState.start);
      expect(start.pts, 2.34);

      final stop = SpeakingEvent.fromJson({
        'type': 'speaking',
        'value': 'stop',
        'pts': 7.81,
      });
      expect(stop.value, SpeakingState.stop);
      expect(stop.pts, 7.81);
    });

    test('coerces int pts to double', () {
      final ev = SpeakingEvent.fromJson({
        'type': 'speaking',
        'value': 'start',
        'pts': 3,
      });
      expect(ev.pts, 3.0);
    });

    test('throws on unknown value', () {
      expect(
        () => SpeakingEvent.fromJson({'value': 'pause', 'pts': 1.0}),
        throwsFormatException,
      );
    });

    test(
        'missing pts → null (legacy pre-2026-05 no-pts events per '
        'twai-protocol schema/speaking-event.schema.json:16-20)', () {
      final ev = SpeakingEvent.fromJson({'value': 'start'});
      expect(ev.value, SpeakingState.start);
      expect(ev.pts, isNull);
    });

    test('non-null non-numeric pts still throws', () {
      expect(
        () => SpeakingEvent.fromJson({'value': 'start', 'pts': 'noon'}),
        throwsFormatException,
      );
    });
  });

  group('mseStreamCloseFor', () {
    test('maps codes to typed reasons', () {
      expect(mseStreamCloseFor(1000, 'bye'), isA<NormalClose>());
      expect(mseStreamCloseFor(1002, 'no sid'), isA<ConfigError>());
      expect(mseStreamCloseFor(1008, 'bad key'), isA<Unauthorized>());
      expect(mseStreamCloseFor(4401, 'invalid'), isA<Unauthorized>());
      expect(mseStreamCloseFor(4403, 'forbidden'), isA<Unauthorized>());
      expect(mseStreamCloseFor(4429, 'too many'), isA<Unauthorized>());
      expect(mseStreamCloseFor(1011, 'codec'), isA<ServerError>());
      expect(mseStreamCloseFor(4000, 'app'), isA<OtherClose>());
      expect(mseStreamCloseFor(null, null), isA<OtherClose>());
    });

    test('canReconnect: false for config/auth/server bugs, true otherwise', () {
      expect(const NormalClose().canReconnect, isTrue);
      expect(const ConfigError('x').canReconnect, isFalse);
      expect(const Unauthorized(4401, 'x').canReconnect, isFalse);
      expect(const ServerError('x').canReconnect, isFalse);
      expect(const OtherClose(4000, '').canReconnect, isTrue);
      expect(const OtherClose(1002, '').canReconnect, isFalse);
      expect(const OtherClose(1008, '').canReconnect, isFalse);
    });
  });

  group('MseStreamClient (in-process server)', () {
    late HttpServer server;
    late Uri url;
    late Completer<WebSocket> serverSocket;

    setUp(() async {
      serverSocket = Completer<WebSocket>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = Uri.parse('ws://${server.address.host}:${server.port}/');
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        serverSocket.complete(ws);
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    MseStreamConfig cfg() => const MseStreamConfig(sessionId: 'mse-1-2');

    /// Collect server-side frames via an active subscription. Using
    /// `listen()` (rather than `.first`) keeps the server WS alive so
    /// the client's close handshake can complete.
    (List<dynamic>, StreamSubscription) collectServer(WebSocket ws) {
      final frames = <dynamic>[];
      final sub = ws.listen(frames.add);
      return (frames, sub);
    }

    test('sends the handshake JSON as the first text frame', () async {
      final client = MseStreamClient();
      await client.connect(url, cfg());

      final ws = await serverSocket.future;
      final (frames, _) = collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(frames, hasLength(1));
      expect(frames.first, isA<String>());
      expect(jsonDecode(frames.first as String), {
        'session_id': 'mse-1-2',
        'avatar_id': 'default',
        'ttsSelection': 'tts5',
        'avatarVoice': 'default',
        'stream_type': 'AV',
        // twai-protocol v1.1.0 handshake tolerated field.
        'protocolVersion': '1.1.0',
      });

      await client.close();
    });

    test('emits binary frames on binaryFrames stream', () async {
      final client = MseStreamClient();
      final received = <Uint8List>[];
      final clientSub = client.binaryFrames.listen(received.add);

      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      ws.add(Uint8List.fromList([0x66, 0x74, 0x79, 0x70])); // 'ftyp'
      ws.add(Uint8List.fromList([0x6d, 0x6f, 0x6f, 0x66])); // 'moof'

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(2));
      expect(received[0], equals([0x66, 0x74, 0x79, 0x70]));
      expect(received[1], equals([0x6d, 0x6f, 0x6f, 0x66]));

      await clientSub.cancel();
      await client.close();
    });

    test('parses speaking events from text frames', () async {
      final client = MseStreamClient();
      final received = <SpeakingEvent>[];
      final clientSub = client.speakingEvents.listen(received.add);

      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      ws.add(jsonEncode({'type': 'speaking', 'value': 'start', 'pts': 2.34}));
      ws.add(jsonEncode({'type': 'speaking', 'value': 'stop', 'pts': 7.81}));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(2));
      expect(received[0].value, SpeakingState.start);
      expect(received[0].pts, 2.34);
      expect(received[1].value, SpeakingState.stop);
      expect(received[1].pts, 7.81);

      await clientSub.cancel();
      await client.close();
    });

    test('drops non-speaking text frames silently', () async {
      final client = MseStreamClient();
      final received = <SpeakingEvent>[];
      final clientSub = client.speakingEvents.listen(received.add);

      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      ws.add(jsonEncode({'type': 'flush'}));
      ws.add(jsonEncode({'type': 'speak', 'text': 'hi'}));
      ws.add('not even json {');
      ws.add(jsonEncode({'type': 'speaking', 'value': 'start', 'pts': 1.0}));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(received[0].value, SpeakingState.start);

      await clientSub.cancel();
      await client.close();
    });

    test('done resolves with NormalClose on clean server close', () async {
      final client = MseStreamClient();
      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close(1000, 'bye');
      final reason = await client.done;
      expect(reason, isA<NormalClose>());
      expect(reason.code, 1000);
    });

    test('done resolves with ConfigError on close code 1002', () async {
      final client = MseStreamClient();
      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close(1002, 'session_id required');
      final reason = await client.done;
      expect(reason, isA<ConfigError>());
      expect(reason.canReconnect, isFalse);
    });

    test('done resolves with ServerError on close code 1011', () async {
      final client = MseStreamClient();
      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close(1011, 'codec error');
      final reason = await client.done;
      expect(reason, isA<ServerError>());
      expect(reason.canReconnect, isFalse);
    });

    test('double connect throws StateError', () async {
      final client = MseStreamClient();
      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await expectLater(
        client.connect(url, cfg()),
        throwsStateError,
      );
      await client.close();
    });

    test('close() shuts streams and resolves done', () async {
      final client = MseStreamClient();
      await client.connect(url, cfg());
      final ws = await serverSocket.future;
      collectServer(ws);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.close();
      final reason = await client.done;
      expect(reason, isA<NormalClose>());
    });
  });

  group('ChatGatewayConfig', () {
    test('bodyFor produces the documented field shape', () {
      const cfg = ChatGatewayConfig(
        sessionId: 'mse-1-2',
        avatarName: 'RedJesusTalk2',
        avatarVoice: 'voice-uuid',
        ttsSelection: 'tts5',
        userId: 'usr-9af2',
      );

      expect(cfg.bodyFor("what's a verse for today"), {
        'text': "what's a verse for today",
        'sessionid': 'mse-1-2',
        'avatarName': 'RedJesusTalk2',
        'avatarVoice': 'voice-uuid',
        'ttsSelection': 'tts5',
        'chunkSize': '10',
        'displayVoice': true,
        'interrupt': true,
        'type': 'chat',
        'userId': 'usr-9af2',
      });
    });

    test('userId may be null (anonymous)', () {
      const cfg = ChatGatewayConfig(
        sessionId: 'mse-1-2',
        avatarName: 'a',
        avatarVoice: 'v',
        ttsSelection: 'tts5',
        userId: null,
      );
      expect(cfg.bodyFor('hi')['userId'], isNull);
    });

    test('bodyFor: gamificationLevel + avatarStateBlock omitted when null',
        () {
      const cfg = ChatGatewayConfig(
        sessionId: 'mse-1-2',
        avatarName: 'a',
        avatarVoice: 'v',
        ttsSelection: 'tts5',
        userId: 'u',
      );
      final body = cfg.bodyFor('hi');
      expect(body.containsKey('gamificationLevel'), isFalse);
      expect(body.containsKey('avatarStateBlock'), isFalse);
    });

    test('bodyFor: gamificationLevel + avatarStateBlock included when set',
        () {
      const cfg = ChatGatewayConfig(
        sessionId: 'mse-1-2',
        avatarName: 'a',
        avatarVoice: 'v',
        ttsSelection: 'tts5',
        userId: 'u',
      );
      final body = cfg.bodyFor(
        'hi',
        gamificationLevel: 3,
        avatarStateBlock: {'mood': 'blissful'},
      );
      expect(body['gamificationLevel'], 3);
      expect(body['avatarStateBlock'], {'mood': 'blissful'});
    });
  });

  group('ChatResponse', () {
    test('parses res + data', () {
      final r = ChatResponse.fromJson({
        'code': 0,
        'data': 'ok',
        'res': 'Peace be with you.',
      });
      expect(r.replyText, 'Peace be with you.');
      expect(r.data, 'ok');
    });

    test('data defaults to empty string if missing', () {
      final r = ChatResponse.fromJson({'res': 'hi'});
      expect(r.data, '');
    });

    test('throws on missing res', () {
      expect(
        () => ChatResponse.fromJson({'code': 0, 'data': 'ok'}),
        throwsFormatException,
      );
    });

    test('mood defaults to null when factory called without it', () {
      final r = ChatResponse.fromJson({'res': 'hello'});
      expect(r.mood, isNull);
    });

    test('mood is set when passed to factory', () {
      final r = ChatResponse.fromJson({'res': 'hello'}, mood: 'blissful');
      expect(r.mood, 'blissful');
    });

    test('moodHumanized is captured from factory', () {
      final r = ChatResponse.fromJson(
        {'res': 'hello'},
        mood: 'homesick',
        moodHumanized: 'Sophi is feeling sad',
      );
      expect(r.mood, 'homesick');
      expect(r.moodHumanized, 'Sophi is feeling sad');
    });
  });

  group('Mood enum', () {
    test('parse round-trips every known slug', () {
      for (final m in Mood.values) {
        if (m == Mood.unknown) continue;
        expect(Mood.parse(m.slug), m,
            reason: 'slug "${m.slug}" should parse to $m');
      }
    });

    test('parse unknown slug → Mood.unknown (forward-compat, never throws)',
        () {
      expect(Mood.parse('totally-new-mood'), Mood.unknown);
      expect(Mood.parse(''), Mood.unknown);
    });

    test('slug vocabulary matches the brain roster exactly (2026-06-27 lock)',
        () {
      // Drift guard: if the brain ships a new slug, this test goes red
      // and reminds us to add it to the Mood enum. The 9-slug set is
      // shared across every avatar in the brain roster — see
      // avatar-brain/src/core/mood/roster.py.
      final slugs = Mood.values
          .where((m) => m != Mood.unknown)
          .map((m) => m.slug)
          .toSet();
      expect(slugs, {
        'warm-curious',
        'dry-teasing',
        'hyped',
        'frisky',
        'soft-quiet',
        'off-her-game',
        'homesick',
        'afterglow',
        'mad',
      });
    });
  });

  group('MoodEvent.fromHeaders', () {
    test('null / empty slug → null event (no mood for this turn)', () {
      expect(MoodEvent.fromHeaders(slug: null, humanized: 'whatever'), isNull);
      expect(MoodEvent.fromHeaders(slug: '', humanized: 'whatever'), isNull);
    });

    test('slug only → typed mood, humanized null', () {
      final ev = MoodEvent.fromHeaders(slug: 'frisky', humanized: null);
      expect(ev?.mood, Mood.frisky);
      expect(ev?.slug, 'frisky');
      expect(ev?.humanized, isNull);
    });

    test('slug + humanized → both populated', () {
      final ev = MoodEvent.fromHeaders(
        slug: 'homesick',
        humanized: 'Sophi is feeling sad',
      );
      expect(ev?.mood, Mood.homesick);
      expect(ev?.humanized, 'Sophi is feeling sad');
    });

    test('empty humanized normalized to null', () {
      final ev = MoodEvent.fromHeaders(slug: 'frisky', humanized: '');
      expect(ev?.humanized, isNull);
    });

    test('unknown slug → Mood.unknown but raw slug preserved', () {
      final ev = MoodEvent.fromHeaders(slug: 'cosmic-new-mood', humanized: null);
      expect(ev?.mood, Mood.unknown);
      expect(ev?.slug, 'cosmic-new-mood');
    });

    test('equality + hashCode use all three fields', () {
      const a = MoodEvent(
        mood: Mood.frisky,
        slug: 'frisky',
        humanized: 'Sophi is feeling frisky',
      );
      const b = MoodEvent(
        mood: Mood.frisky,
        slug: 'frisky',
        humanized: 'Sophi is feeling frisky',
      );
      const c = MoodEvent(mood: Mood.frisky, slug: 'frisky');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('ChatGateway', () {
    const cfg = ChatGatewayConfig(
      sessionId: 'mse-1-2',
      avatarName: 'RedJesusTalk2',
      avatarVoice: 'voice-uuid',
      ttsSelection: 'tts5',
      userId: 'usr-9af2',
    );
    final baseUrl = Uri.parse('https://example.test');

    test('resolves the endpoint as /ext-api/human', () {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(gateway.endpoint.toString(),
          'https://example.test/ext-api/human');
    });

    test('success: POSTs JSON body and parses res', () async {
      late http.Request captured;
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'reply text'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final response = await gateway.sendMessage('hello');

      expect(response.replyText, 'reply text');
      expect(response.data, 'ok');

      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://example.test/ext-api/human');
      expect(captured.headers['content-type'], 'application/json');
      expect(jsonDecode(captured.body), {
        'text': 'hello',
        'sessionid': 'mse-1-2',
        'avatarName': 'RedJesusTalk2',
        'avatarVoice': 'voice-uuid',
        'ttsSelection': 'tts5',
        'chunkSize': '10',
        'displayVoice': true,
        'interrupt': true,
        'type': 'chat',
        'userId': 'usr-9af2',
      });
    });

    test('sends Authorization: Bearer when publishableKey is set', () async {
      late http.Request captured;
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        publishableKey: 'pk_test_xyz',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'ok'}),
            200,
          );
        }),
      );
      await gateway.sendMessage('hi');
      expect(captured.headers['authorization'], 'Bearer pk_test_xyz');
    });

    test('no Authorization header when publishableKey is null', () async {
      late http.Request captured;
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'ok'}),
            200,
          );
        }),
      );
      await gateway.sendMessage('hi');
      expect(captured.headers.containsKey('authorization'), isFalse);
    });

    test('credentials arg overrides publishableKey', () async {
      late http.Request captured;
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        publishableKey: 'pk_ignored',
        credentials: ViewTokenCredentials('vt_wins'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'ok'}),
            200,
          );
        }),
      );
      await gateway.sendMessage('hi');
      expect(captured.headers['x-view-token'], 'vt_wins');
      expect(captured.headers.containsKey('authorization'), isFalse);
    });

    test('throws ChatProtocolException on code != 0', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': 42, 'data': 'avatar not ready'}),
              200,
            )),
      );

      try {
        await gateway.sendMessage('hi');
        fail('Expected ChatProtocolException');
      } on ChatProtocolException catch (e) {
        expect(e.code, 42);
        expect(e.data, 'avatar not ready');
      }
    });

    test('throws ChatHttpException on HTTP 500', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );

      try {
        await gateway.sendMessage('hi');
        fail('Expected ChatHttpException');
      } on ChatHttpException catch (e) {
        expect(e.statusCode, 500);
        expect(e.body, 'boom');
      }
    });

    test('throws ChatUnauthorizedException on HTTP 401', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
            (_) async => http.Response('invalid api key', 401)),
      );
      try {
        await gateway.sendMessage('hi');
        fail('Expected ChatUnauthorizedException');
      } on ChatUnauthorizedException catch (e) {
        expect(e.statusCode, 401);
        expect(e.body, 'invalid api key');
      }
    });

    test('throws ChatForbiddenException on HTTP 403', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
            (_) async => http.Response('key not scoped for this avatar', 403)),
      );
      try {
        await gateway.sendMessage('hi');
        fail('Expected ChatForbiddenException');
      } on ChatForbiddenException catch (e) {
        expect(e.statusCode, 403);
      }
    });

    test('throws ChatRateLimitedException on HTTP 429', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
            (_) async => http.Response('over quota', 429)),
      );
      try {
        await gateway.sendMessage('hi');
        fail('Expected ChatRateLimitedException');
      } on ChatRateLimitedException catch (e) {
        expect(e.statusCode, 429);
      }
    });

    test('throws ChatTransportException on bad JSON body', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response('not json', 200),
        ),
      );

      await expectLater(
        gateway.sendMessage('hi'),
        throwsA(isA<ChatTransportException>()),
      );
    });

    test('throws ChatTransportException on network failure', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async {
          throw const SocketException('Network unreachable');
        }),
      );

      try {
        await gateway.sendMessage('hi');
        fail('Expected ChatTransportException');
      } on ChatTransportException catch (e) {
        expect(e.cause, isA<SocketException>());
      }
    });

    test('throws ChatTransportException when res field is missing', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 0, 'data': 'ok'}),
            200,
          ),
        ),
      );

      await expectLater(
        gateway.sendMessage('hi'),
        throwsA(isA<ChatTransportException>()),
      );
    });

    test('captures X-Mood response header into ChatResponse.mood',
        () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
            headers: {'x-mood': 'blissful'},
          ),
        ),
      );
      final r = await gateway.sendMessage('hi');
      expect(r.mood, 'blissful');
    });

    test('captures X-Mood-Humanized response header into ChatResponse.moodHumanized',
        () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
            headers: {
              'x-mood': 'homesick',
              'x-mood-humanized': 'Sophi is feeling sad',
            },
          ),
        ),
      );
      final r = await gateway.sendMessage('hi');
      expect(r.mood, 'homesick');
      expect(r.moodHumanized, 'Sophi is feeling sad');
    });

    test('X-Mood-Humanized absent → moodHumanized is null even when mood present',
        () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
            headers: {'x-mood': 'frisky'},
          ),
        ),
      );
      final r = await gateway.sendMessage('hi');
      expect(r.mood, 'frisky');
      expect(r.moodHumanized, isNull);
    });

    test('absent X-Mood header → mood is null', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
          ),
        ),
      );
      final r = await gateway.sendMessage('hi');
      expect(r.mood, isNull);
    });

    test('empty X-Mood header → mood is null (not empty string)', () async {
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
            headers: {'x-mood': ''},
          ),
        ),
      );
      final r = await gateway.sendMessage('hi');
      expect(r.mood, isNull);
    });

    test('forwards gamificationLevel + avatarStateBlock into request body',
        () async {
      late http.Request captured;
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
          );
        }),
      );
      await gateway.sendMessage(
        'hi',
        gamificationLevel: 4,
        avatarStateBlock: {'pose': 'standing'},
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['gamificationLevel'], 4);
      expect(body['avatarStateBlock'], {'pose': 'standing'});
    });

    test('omits gamificationLevel + avatarStateBlock when null', () async {
      late http.Request captured;
      final gateway = ChatGateway(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hello'}),
            200,
          );
        }),
      );
      await gateway.sendMessage('hi');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body.containsKey('gamificationLevel'), isFalse);
      expect(body.containsKey('avatarStateBlock'), isFalse);
    });
  });

  group('PipelineV13Config', () {
    test('bodyFor includes avatar + message; voice + history optional', () {
      const cfg = PipelineV13Config(avatar: 'sophi');
      expect(cfg.bodyFor('hi'), {'avatar': 'sophi', 'message': 'hi'});

      const cfgWithVoice = PipelineV13Config(avatar: 'sophi', voiceId: 'v-1');
      expect(cfgWithVoice.bodyFor('hi'), {
        'avatar': 'sophi',
        'message': 'hi',
        'voice_id': 'v-1',
      });

      expect(
        cfgWithVoice.bodyFor('hi', history: [
          {'role': 'user', 'content': 'prev'}
        ]),
        {
          'avatar': 'sophi',
          'message': 'hi',
          'voice_id': 'v-1',
          'history': [
            {'role': 'user', 'content': 'prev'}
          ],
        },
      );
    });
  });

  group('PipelineV13Client', () {
    const cfg = PipelineV13Config(avatar: 'sophi', voiceId: 'v-1');
    final baseUrl = Uri.parse('https://example.test');
    final mp4Bytes = Uint8List.fromList(List.generate(64, (i) => i & 0xff));

    test('endpoints resolve under baseUrl', () {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(client.chatEndpoint.toString(), 'https://example.test/chat');
      expect(client.healthEndpoint.toString(), 'https://example.test/health');
    });

    test('chat: POSTs JSON body and parses MP4 + X-Response-Text', () async {
      late http.Request captured;
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response.bytes(
            mp4Bytes,
            200,
            headers: {
              'content-type': 'video/mp4',
              // Server JSON-encodes the reply text:
              'x-response-text': '"Peace be with you."',
            },
          );
        }),
      );

      final response = await client.chat('hi');

      expect(response.videoBytes, equals(mp4Bytes));
      expect(response.replyText, 'Peace be with you.');

      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://example.test/chat');
      expect(captured.headers['content-type'], 'application/json');
      expect(jsonDecode(captured.body), {
        'avatar': 'sophi',
        'message': 'hi',
        'voice_id': 'v-1',
      });
    });

    test('chat: sends Authorization: Bearer when publishableKey is set', () async {
      late http.Request captured;
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        publishableKey: 'sekret',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response.bytes(
            mp4Bytes,
            200,
            headers: {'x-response-text': '"ok"'},
          );
        }),
      );

      await client.chat('hi');
      expect(captured.headers['authorization'], 'Bearer sekret');
    });

    test('chat: no Authorization header when publishableKey is null', () async {
      late http.Request captured;
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response.bytes(
            mp4Bytes,
            200,
            headers: {'x-response-text': '"ok"'},
          );
        }),
      );

      await client.chat('hi');
      expect(captured.headers.containsKey('authorization'), isFalse);
    });

    test('chat: credentials arg overrides publishableKey', () async {
      late http.Request captured;
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        publishableKey: 'pk_ignored',
        credentials: ViewTokenCredentials('vt_wins'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response.bytes(
            mp4Bytes,
            200,
            headers: {'x-response-text': '"ok"'},
          );
        }),
      );

      await client.chat('hi');
      expect(captured.headers['x-view-token'], 'vt_wins');
      expect(captured.headers.containsKey('authorization'), isFalse);
    });

    test('chat: falls back to raw header if not JSON-encoded', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            mp4Bytes,
            200,
            headers: {'x-response-text': 'bare text no quotes'},
          ),
        ),
      );

      final response = await client.chat('hi');
      expect(response.replyText, 'bare text no quotes');
    });

    test('chat: throws PipelineV13HttpException on HTTP 500', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );

      try {
        await client.chat('hi');
        fail('Expected PipelineV13HttpException');
      } on PipelineV13HttpException catch (e) {
        expect(e.statusCode, 500);
        expect(e.body, 'boom');
      }
    });

    test('chat: throws PipelineV13UnauthorizedException on HTTP 401', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('bad key', 401)),
      );
      await expectLater(
        client.chat('hi'),
        throwsA(isA<PipelineV13UnauthorizedException>()),
      );
    });

    test('chat: throws PipelineV13ForbiddenException on HTTP 403', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('not scoped', 403)),
      );
      await expectLater(
        client.chat('hi'),
        throwsA(isA<PipelineV13ForbiddenException>()),
      );
    });

    test('chat: throws PipelineV13RateLimitedException on HTTP 429', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('over', 429)),
      );
      await expectLater(
        client.chat('hi'),
        throwsA(isA<PipelineV13RateLimitedException>()),
      );
    });

    test('chat: throws PipelineV13TransportException on empty body', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            Uint8List(0),
            200,
            headers: {'x-response-text': '"hi"'},
          ),
        ),
      );

      await expectLater(
        client.chat('hi'),
        throwsA(isA<PipelineV13TransportException>()),
      );
    });

    test('chat: throws PipelineV13TransportException on missing X-Response-Text',
        () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response.bytes(mp4Bytes, 200),
        ),
      );

      await expectLater(
        client.chat('hi'),
        throwsA(isA<PipelineV13TransportException>()),
      );
    });

    test('chat: throws PipelineV13TransportException on network failure',
        () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async {
          throw const SocketException('Network unreachable');
        }),
      );

      await expectLater(
        client.chat('hi'),
        throwsA(isA<PipelineV13TransportException>()),
      );
    });

    test('health: parses JSON map on 200', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'status': 'ok', 'cached_frames': 950, 'device': 'cuda'}),
            200,
          ),
        ),
      );

      final h = await client.health();
      expect(h['status'], 'ok');
      expect(h['cached_frames'], 950);
      expect(h['device'], 'cuda');
    });

    test('health: throws PipelineV13HttpException on non-2xx', () async {
      final client = PipelineV13Client(
        baseUrl: baseUrl,
        config: cfg,
        httpClient: MockClient((_) async => http.Response('down', 503)),
      );

      await expectLater(
        client.health(),
        throwsA(isA<PipelineV13HttpException>()),
      );
    });
  });

  group('MseStreamChatSession', () {
    late HttpServer wsServer;
    late Uri wsBaseUrl;
    late Completer<WebSocket> serverSocket;
    late Completer<Uri> serverHandshakeUri;

    setUp(() async {
      serverSocket = Completer<WebSocket>();
      serverHandshakeUri = Completer<Uri>();
      wsServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      wsBaseUrl = Uri.parse('http://${wsServer.address.host}:${wsServer.port}');
      wsServer.listen((req) async {
        if (!serverHandshakeUri.isCompleted) {
          serverHandshakeUri.complete(req.uri);
        }
        final ws = await WebSocketTransformer.upgrade(req);
        serverSocket.complete(ws);
      });
    });

    tearDown(() async {
      await wsServer.close(force: true);
    });

    test('sendMessage before connect throws NotConnected', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
      );
      await expectLater(
        session.sendMessage('hi'),
        throwsA(isA<ChatSessionNotConnectedException>()),
      );
    });

    test('connect twice throws AlreadyConnected', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future;

      await expectLater(
        session.connect(const Avatar(id: 'b')),
        throwsA(isA<ChatSessionAlreadyConnectedException>()),
      );
      await session.close();
    });

    test('publishableKey: WS URL gets ?key= query param, POST gets Authorization header',
        () async {
      late http.Request capturedPost;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        publishableKey: 'pk_test_abc',
        httpClient: MockClient((req) async {
          capturedPost = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'r'}),
            200,
          );
        }),
      );
      await session.connect(const Avatar(id: 'a'));
      final uri = await serverHandshakeUri.future;
      expect(uri.queryParameters['key'], 'pk_test_abc');

      await session.sendMessage('hi');
      expect(capturedPost.headers['authorization'], 'Bearer pk_test_abc');
      await session.close();
    });

    test('no publishableKey: WS URL has no key, POST has no Authorization',
        () async {
      late http.Request capturedPost;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((req) async {
          capturedPost = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'r'}),
            200,
          );
        }),
      );
      await session.connect(const Avatar(id: 'a'));
      final uri = await serverHandshakeUri.future;
      expect(uri.queryParameters.containsKey('key'), isFalse);

      await session.sendMessage('hi');
      expect(capturedPost.headers.containsKey('authorization'), isFalse);
      await session.close();
    });

    test(
        'credentials: ViewToken sets X-View-Token header + view_token WS param',
        () async {
      late http.Request capturedPost;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        credentials: ViewTokenCredentials('vt_abc'),
        httpClient: MockClient((req) async {
          capturedPost = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'r'}),
            200,
          );
        }),
      );
      await session.connect(const Avatar(id: 'a'));
      final uri = await serverHandshakeUri.future;
      expect(uri.queryParameters['view_token'], 'vt_abc');
      expect(uri.queryParameters.containsKey('key'), isFalse);

      await session.sendMessage('hi');
      expect(capturedPost.headers['x-view-token'], 'vt_abc');
      expect(capturedPost.headers.containsKey('authorization'), isFalse);
      await session.close();
    });

    test('credentials wins over publishableKey when both are passed',
        () async {
      late http.Request capturedPost;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        publishableKey: 'pk_ignored',
        credentials: ViewTokenCredentials('vt_wins'),
        httpClient: MockClient((req) async {
          capturedPost = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': '', 'res': 'r'}),
            200,
          );
        }),
      );
      await session.connect(const Avatar(id: 'a'));
      final uri = await serverHandshakeUri.future;
      expect(uri.queryParameters['view_token'], 'vt_wins');
      expect(uri.queryParameters.containsKey('key'), isFalse);

      await session.sendMessage('hi');
      expect(capturedPost.headers['x-view-token'], 'vt_wins');
      expect(capturedPost.headers.containsKey('authorization'), isFalse);
      await session.close();
    });

    test('handshake + POST share sessionId and avatar config', () async {
      late http.Request capturedPost;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-9',
        sessionId: 'mse-fixed-123456',
        httpClient: MockClient((req) async {
          capturedPost = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hi back'}),
            200,
          );
        }),
      );
      await session.connect(
        const Avatar(id: 'RedJesusTalk2', voiceId: 'v-uuid'),
      );

      final ws = await serverSocket.future;
      final frames = <dynamic>[];
      ws.listen(frames.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // WS handshake carries avatar + session id.
      final handshake = jsonDecode(frames.first as String) as Map<String, dynamic>;
      expect(handshake['session_id'], 'mse-fixed-123456');
      expect(handshake['avatar_id'], 'RedJesusTalk2');
      expect(handshake['avatarVoice'], 'v-uuid');
      expect(handshake['ttsSelection'], 'tts5');

      // POST shares the same session id + avatar config.
      await session.sendMessage('hello');
      final postBody = jsonDecode(capturedPost.body) as Map<String, dynamic>;
      expect(postBody['sessionid'], 'mse-fixed-123456');
      expect(postBody['avatarName'], 'RedJesusTalk2');
      expect(postBody['avatarVoice'], 'v-uuid');
      expect(postBody['ttsSelection'], 'tts5');
      expect(postBody['userId'], 'u-9');

      await session.close();
    });

    test('successful sendMessage emits on replyText', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': 0, 'data': 'ok', 'res': 'peace'}),
              200,
            )),
      );
      final replies = <String>[];
      final sub = session.replyText.listen(replies.add);

      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));
      await session.sendMessage('hi');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(replies, ['peace']);

      await sub.cancel();
      await session.close();
    });

    test('WS binary frames flow into videoBytes', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final bytes = <Uint8List>[];
      final sub = session.videoBytes.listen(bytes.add);

      await session.connect(const Avatar(id: 'a'));
      final ws = await serverSocket.future;
      ws.listen((_) {}); // consume handshake

      await Future<void>.delayed(const Duration(milliseconds: 50));
      ws.add(Uint8List.fromList([1, 2, 3]));
      ws.add(Uint8List.fromList([4, 5, 6]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bytes, [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
      ]);

      await sub.cancel();
      await session.close();
    });

    test('WS speaking events propagate to speakingEvents stream', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final events = <SpeakingEvent>[];
      final sub = session.speakingEvents.listen(events.add);

      await session.connect(const Avatar(id: 'a'));
      final ws = await serverSocket.future;
      ws.listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 50));
      ws.add(jsonEncode({'type': 'speaking', 'value': 'start', 'pts': 1.5}));
      ws.add(jsonEncode({'type': 'speaking', 'value': 'stop', 'pts': 3.2}));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, hasLength(2));
      expect(events[0].value, SpeakingState.start);
      expect(events[0].pts, 1.5);
      expect(events[1].value, SpeakingState.stop);

      await sub.cancel();
      await session.close();
    });

    test('gateway error wraps as ChatSessionSendException; session stays open',
        () async {
      var hits = 0;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((req) async {
          hits++;
          if (hits == 1) return http.Response('boom', 500);
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'retry ok'}),
            200,
          );
        }),
      );
      final replies = <String>[];
      session.replyText.listen(replies.add);

      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      await expectLater(
        session.sendMessage('hi'),
        throwsA(isA<ChatSessionSendException>()),
      );
      // Session still works after a failed send.
      await session.sendMessage('try again');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(replies, ['retry ok']);

      await session.close();
    });

    test('gateway 401 wraps as ChatSessionUnauthorizedException', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        publishableKey: 'pk_bad',
        httpClient:
            MockClient((_) async => http.Response('invalid api key', 401)),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      await expectLater(
        session.sendMessage('hi'),
        throwsA(isA<ChatSessionUnauthorizedException>()),
      );
      await session.close();
    });

    test('gateway 429 wraps as ChatSessionRateLimitedException', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((_) async => http.Response('over quota', 429)),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      await expectLater(
        session.sendMessage('hi'),
        throwsA(isA<ChatSessionRateLimitedException>()),
      );
      await session.close();
    });

    test('WS close 1002 → done is ChatSessionFailed(isPermanent: true)',
        () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );

      await session.connect(const Avatar(id: 'a'));
      final ws = await serverSocket.future;
      ws.listen((_) {});

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close(1002, 'session_id required');

      final reason = await session.done;
      expect(reason, isA<ChatSessionFailed>());
      expect((reason as ChatSessionFailed).isPermanent, isTrue);
      expect(reason.canReconnect, isFalse);
    });

    test('close() → done resolves with ChatSessionClosed', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: null,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );

      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      await session.close();
      final reason = await session.done;
      expect(reason, isA<ChatSessionClosed>());
      expect(reason.canReconnect, isTrue);
    });

    test('moodEvents emits typed MoodEvent with X-Mood + X-Mood-Humanized',
        () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': 0, 'data': 'ok', 'res': 'hi'}),
              200,
              headers: {
                'x-mood': 'homesick',
                'x-mood-humanized': 'Sophi is feeling sad',
              },
            )),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      final moodFuture = session.moodEvents.first;
      await session.sendMessage('hi');
      final ev = await moodFuture;
      expect(ev.mood, Mood.homesick);
      expect(ev.slug, 'homesick');
      expect(ev.humanized, 'Sophi is feeling sad');

      await session.close();
    });

    test('moodEvents: unknown slug → Mood.unknown but slug preserved',
        () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': 0, 'data': 'ok', 'res': 'hi'}),
              200,
              headers: {'x-mood': 'brand-new-mood-not-in-sdk-yet'},
            )),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      final ev = await () async {
        final f = session.moodEvents.first;
        await session.sendMessage('hi');
        return f;
      }();
      expect(ev.mood, Mood.unknown);
      expect(ev.slug, 'brand-new-mood-not-in-sdk-yet');
      expect(ev.humanized, isNull);

      await session.close();
    });

    test('moodEvents: humanized absent → MoodEvent.humanized is null',
        () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': 0, 'data': 'ok', 'res': 'hi'}),
              200,
              headers: {'x-mood': 'frisky'}, // humanized header omitted
            )),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      final ev = await () async {
        final f = session.moodEvents.first;
        await session.sendMessage('hi');
        return f;
      }();
      expect(ev.mood, Mood.frisky);
      expect(ev.humanized, isNull);

      await session.close();
    });

    test('moodEvents does NOT emit when X-Mood header is absent', () async {
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'code': 0, 'data': 'ok', 'res': 'hi'}),
              200,
            )),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      final moods = <MoodEvent>[];
      final sub = session.moodEvents.listen(moods.add);
      await session.sendMessage('hi');
      // Give the stream a microtask to fire if it were going to.
      await Future<void>.delayed(Duration.zero);
      expect(moods, isEmpty);

      await sub.cancel();
      await session.close();
    });

    test('sendMessage forwards gamificationLevel + avatarStateBlock to POST body',
        () async {
      late http.Request capturedPost;
      final session = MseStreamChatSession(
        baseUrl: wsBaseUrl,
        ttsSelection: 'tts5',
        userId: 'u-1',
        httpClient: MockClient((req) async {
          capturedPost = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok', 'res': 'hi'}),
            200,
          );
        }),
      );
      await session.connect(const Avatar(id: 'a'));
      await serverSocket.future.then((ws) => ws.listen((_) {}));

      await session.sendMessage(
        'hi',
        gamificationLevel: 7,
        avatarStateBlock: {'pose': 'standing'},
      );
      final body = jsonDecode(capturedPost.body) as Map<String, dynamic>;
      expect(body['gamificationLevel'], 7);
      expect(body['avatarStateBlock'], {'pose': 'standing'});

      await session.close();
    });
  });

  group('PipelineV13ChatSession', () {
    final baseUrl = Uri.parse('https://example.test');
    final mp4 = Uint8List.fromList([1, 2, 3, 4]);

    PipelineV13ChatSession buildSession({required http.Client httpClient}) =>
        PipelineV13ChatSession(baseUrl: baseUrl, httpClient: httpClient);

    test('sendMessage before connect throws NotConnected', () async {
      final session = buildSession(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        session.sendMessage('hi'),
        throwsA(isA<ChatSessionNotConnectedException>()),
      );
    });

    test('connect twice throws AlreadyConnected', () async {
      final session = buildSession(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await session.connect(const Avatar(id: 'sophi'));
      await expectLater(
        session.connect(const Avatar(id: 'krystal')),
        throwsA(isA<ChatSessionAlreadyConnectedException>()),
      );
    });

    test('successful sendMessage emits on replyText AND videoBytes', () async {
      final session = buildSession(
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            mp4,
            200,
            headers: {'x-response-text': '"hello"'},
          ),
        ),
      );
      final replies = <String>[];
      final videos = <Uint8List>[];
      session.replyText.listen(replies.add);
      session.videoBytes.listen(videos.add);

      await session.connect(const Avatar(id: 'sophi'));
      await session.sendMessage('hi');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(replies, ['hello']);
      expect(videos, [mp4]);

      await session.close();
    });

    test('speakingEvents stays empty (Adapter 2 has none)', () async {
      final session = buildSession(
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            mp4,
            200,
            headers: {'x-response-text': '"hi"'},
          ),
        ),
      );
      final events = <SpeakingEvent>[];
      session.speakingEvents.listen(events.add);

      await session.connect(const Avatar(id: 'sophi'));
      await session.sendMessage('hi');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, isEmpty);
      await session.close();
    });

    test('history accumulates user + assistant turns and rides subsequent POSTs',
        () async {
      final captured = <Map<String, dynamic>>[];
      final session = buildSession(
        httpClient: MockClient((req) async {
          captured.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response.bytes(
            mp4,
            200,
            headers: {'x-response-text': '"reply ${captured.length}"'},
          );
        }),
      );

      await session.connect(const Avatar(id: 'sophi'));
      await session.sendMessage('first');
      await session.sendMessage('second');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // First POST: no history yet.
      expect(captured[0]['history'], isEmpty);

      // Second POST: history contains the first round-trip.
      expect(captured[1]['history'], [
        {'role': 'user', 'content': 'first'},
        {'role': 'assistant', 'content': 'reply 1'},
      ]);

      // Session-level history exposes both turns.
      expect(session.history, hasLength(4));
      expect(session.history.last['role'], 'assistant');

      await session.close();
    });

    test('client error wraps as ChatSessionSendException; session stays open',
        () async {
      var hits = 0;
      final session = buildSession(
        httpClient: MockClient((req) async {
          hits++;
          if (hits == 1) return http.Response('boom', 500);
          return http.Response.bytes(
            mp4,
            200,
            headers: {'x-response-text': '"ok now"'},
          );
        }),
      );
      final replies = <String>[];
      session.replyText.listen(replies.add);

      await session.connect(const Avatar(id: 'sophi'));
      await expectLater(
        session.sendMessage('hi'),
        throwsA(isA<ChatSessionSendException>()),
      );
      await session.sendMessage('retry');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(replies, ['ok now']);

      await session.close();
    });

    test('close() → done resolves with ChatSessionClosed', () async {
      final session = buildSession(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await session.connect(const Avatar(id: 'sophi'));
      await session.close();
      final reason = await session.done;
      expect(reason, isA<ChatSessionClosed>());
      expect(reason.canReconnect, isTrue);
    });
  });

  group('TwaiEnvironment', () {
    test(
        'named() finds builtins without prior static-field reference '
        '(registry self-initializes on first access)', () {
      // Regression: an earlier impl used per-field _register() lazy
      // calls, leaving the registry empty if no static field was ever
      // dereferenced. App boot calling fromDartDefine() → named() with
      // a fresh isolate hit this and threw ArgumentError.
      // This test must run before any other TwaiEnvironment.* access to
      // guarantee the cold-start path is what we exercise — keep it
      // first in the group.
      expect(TwaiEnvironment.named('2wai-staging').baseUrl.toString(),
          'https://staging.coreledgergroup.com');
      expect(TwaiEnvironment.named('2wai-prod').baseUrl.toString(),
          'https://www.penthousepets.com');
      expect(TwaiEnvironment.named('local-dev').baseUrl.toString(),
          'http://localhost:8000');
    });

    test('predefined envs are registered with the expected URLs', () {
      expect(TwaiEnvironment.localDev.name, 'local-dev');
      expect(TwaiEnvironment.localDev.baseUrl.toString(),
          'http://localhost:8000');

      expect(TwaiEnvironment.twaiStaging.name, '2wai-staging');
      expect(TwaiEnvironment.twaiStaging.baseUrl.toString(),
          'https://staging.coreledgergroup.com');

      expect(TwaiEnvironment.twaiProd.name, '2wai-prod');
      expect(TwaiEnvironment.twaiProd.baseUrl.toString(),
          'https://www.penthousepets.com');
    });

    test('named() looks up by string', () {
      expect(TwaiEnvironment.named('2wai-staging'),
          same(TwaiEnvironment.twaiStaging));
      expect(TwaiEnvironment.named('local-dev'),
          same(TwaiEnvironment.localDev));
    });

    test('named() throws ArgumentError on unknown name', () {
      expect(() => TwaiEnvironment.named('does-not-exist'),
          throwsArgumentError);
    });

    test('register() adds a custom env retrievable by name', () {
      final acme = TwaiEnvironment(
        name: 'acme-prod-test',
        baseUrl: Uri.parse('https://avatars.acme-test.example'),
      );
      TwaiEnvironment.register(acme);

      expect(TwaiEnvironment.named('acme-prod-test'), same(acme));
      expect(TwaiEnvironment.all, contains(acme));
    });

    test('fromDartDefine() falls back to defaultName when flag unset', () {
      // No --dart-define means String.fromEnvironment returns ''.
      // Fallback chain: provided default → 'local-dev'.
      expect(
        TwaiEnvironment.fromDartDefine(defaultName: '2wai-staging'),
        same(TwaiEnvironment.twaiStaging),
      );
      expect(
        TwaiEnvironment.fromDartDefine(),
        same(TwaiEnvironment.localDev),
      );
    });
  });

  group('AvatarAdminClient', () {
    final baseUrl = Uri.parse('https://staging.example');

    test('constructor throws if developerMode is not acknowledged', () {
      expect(
        () => AvatarAdminClient(baseUrl: baseUrl, developerMode: false),
        throwsStateError,
      );
    });

    test('sends Authorization: Bearer on GET when secretKey is set', () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        secretKey: 'sk_test_xyz',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'data': <String>[]}), 200);
        }),
      );
      await admin.readyAvatars();
      expect(captured.headers['authorization'], 'Bearer sk_test_xyz');
    });

    test('sends Authorization: Bearer on POST when secretKey is set', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        secretKey: 'sk_test_xyz',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'chatPrompt': ''}), 200);
        }),
      );
      await admin.getPrompt('RedJesusTalk1');
      expect(captured.headers['authorization'], 'Bearer sk_test_xyz');
      expect(captured.headers['content-type'], 'application/json');
    });

    test('no Authorization header when secretKey is null', () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'data': <String>[]}), 200);
        }),
      );
      await admin.readyAvatars();
      expect(captured.headers.containsKey('authorization'), isFalse);
    });

    test('readyAvatars: GET /ext-api/query_avatar_list, parses list', () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': ['RedJesusTalk1', 'sophi']}),
            200,
          );
        }),
      );

      final list = await admin.readyAvatars();
      expect(list, ['RedJesusTalk1', 'sophi']);
      expect(captured.method, 'GET');
      expect(captured.url.toString(),
          'https://staging.example/ext-api/query_avatar_list');
    });

    test('allAvatars: GET /ext-api/query_avatar, parses metadata', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'code': 0,
              'data': [
                {
                  'avatar_name': 'RedJesusTalk1',
                  'prompt': 'You are Jesus',
                  'create_at': 1700000000000,
                  'update_at': 1700001000000,
                },
              ],
            }),
            200,
          ),
        ),
      );

      final list = await admin.allAvatars();
      expect(list, hasLength(1));
      expect(list[0].avatarName, 'RedJesusTalk1');
      expect(list[0].prompt, 'You are Jesus');
      expect(list[0].createAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('getPrompt: POST with {avatarName}, returns chatPrompt', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': 'success!',
              'chatPrompt': 'You are ...',
            }),
            200,
          );
        }),
      );

      final prompt = await admin.getPrompt('RedJesusTalk1');
      expect(prompt, 'You are ...');
      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'https://staging.example/ext-api/query_prompt');
      expect(jsonDecode(captured.body), {'avatarName': 'RedJesusTalk1'});
    });

    test('addAvatar: POSTs documented body shape, parses result', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': 'ok',
              'webrtcReleased': false,
              'clearAvatarCache': true,
              'cacheBust': 1234,
            }),
            200,
          );
        }),
      );

      final result = await admin.addAvatar(
        avatarId: 'RedJesusTalk1',
        prompt: 'You are Jesus',
        voiceId: 'voice-uuid',
      );

      expect(result.code, 0);
      expect(result.data, 'ok');
      expect(result.webrtcReleased, isFalse);
      expect(result.clearAvatarCache, isTrue);
      expect(result.cacheBust, 1234);

      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'https://staging.example/ext-api/add_avatar');
      expect(jsonDecode(captured.body), {
        'avatar_id': 'RedJesusTalk1',
        'prompt': 'You are Jesus',
        'voice_id': 'voice-uuid',
        'green_bg': true,
        'need_middles': false,
        'handle': 'add',
      });
    });

    test('deleteAvatar: POST with right body', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': 'ok'}),
            200,
          );
        }),
      );

      await admin.deleteAvatar(
        avatarName: 'RedJesusTalk1',
        deletePermanent: true,
        sessionId: 'mse-1-2',
      );

      expect(jsonDecode(captured.body), {
        'avatarName': 'RedJesusTalk1',
        'deletePermanent': true,
        'sessionid': 'mse-1-2',
      });
    });

    test('changePrompt: POST with right body', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'msg': 'success!'}),
            200,
          );
        }),
      );

      await admin.changePrompt(
        avatarName: 'RedJesusTalk1',
        chatPrompt: 'You are the Jesus of Nazareth',
      );

      expect(jsonDecode(captured.body), {
        'avatarName': 'RedJesusTalk1',
        'chatPrompt': 'You are the Jesus of Nazareth',
      });
    });

    test('changeVoiceList: posts the map directly as the body', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'msg': 'options updated successfully'}),
            200,
          );
        }),
      );

      await admin.changeVoiceList({
        'RedJesusTalk1': 'voice-a',
        'sophi': 'voice-b',
      });

      expect(jsonDecode(captured.body), {
        'RedJesusTalk1': 'voice-a',
        'sophi': 'voice-b',
      });
    });

    test('AvatarAdminProtocolException on code != 0', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 2, 'data': 'already exists'}),
            200,
          ),
        ),
      );

      try {
        await admin.addAvatar(
          avatarId: 'x',
          prompt: 'p',
          voiceId: 'v',
        );
        fail('Expected AvatarAdminProtocolException');
      } on AvatarAdminProtocolException catch (e) {
        expect(e.code, 2);
        expect(e.data, 'already exists');
      }
    });

    test('AvatarAdminHttpException on HTTP 500', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );

      await expectLater(
        admin.readyAvatars(),
        throwsA(isA<AvatarAdminHttpException>()),
      );
    });

    test('AvatarAdminUnauthorizedException on HTTP 401', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient(
            (_) async => http.Response('invalid secret', 401)),
      );
      await expectLater(
        admin.readyAvatars(),
        throwsA(isA<AvatarAdminUnauthorizedException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('AvatarAdminForbiddenException on HTTP 403', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient(
            (_) async => http.Response('publishable key cannot admin', 403)),
      );
      await expectLater(
        admin.readyAvatars(),
        throwsA(isA<AvatarAdminForbiddenException>()),
      );
    });

    test('AvatarAdminRateLimitedException on HTTP 429', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient(
            (_) async => http.Response('over quota', 429)),
      );
      await expectLater(
        admin.readyAvatars(),
        throwsA(isA<AvatarAdminRateLimitedException>()),
      );
    });

    test('AvatarAdminTransportException on network failure', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((_) async {
          throw const SocketException('Network unreachable');
        }),
      );

      await expectLater(
        admin.readyAvatars(),
        throwsA(isA<AvatarAdminTransportException>()),
      );
    });

    test('custom pathPrefix overrides /ext-api', () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        pathPrefix: '',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'code': 0, 'data': []}),
            200,
          );
        }),
      );

      await admin.readyAvatars();
      expect(captured.url.toString(),
          'https://staging.example/query_avatar_list');
    });
  });

  group('TtsRuleScope', () {
    test('global is a const singleton', () {
      expect(TtsRuleScope.global.value, 'global');
      expect(identical(TtsRuleScope.global, TtsRuleScope.global), isTrue);
    });

    test('app + avatar produce the right wire format', () {
      expect(TtsRuleScope.app('candy-ai').value, 'app:candy-ai');
      expect(TtsRuleScope.avatar('krystal-harper').value,
          'avatar:krystal-harper');
    });

    test('rejects empty id', () {
      expect(() => TtsRuleScope.app(''), throwsArgumentError);
      expect(() => TtsRuleScope.avatar(''), throwsArgumentError);
    });

    test('rejects colon in id (avoids ambiguity)', () {
      expect(() => TtsRuleScope.app('foo:bar'), throwsArgumentError);
    });

    test('parse round-trips all three forms', () {
      expect(TtsRuleScope.parse('global'), TtsRuleScope.global);
      expect(TtsRuleScope.parse('app:foo'), TtsRuleScope.app('foo'));
      expect(TtsRuleScope.parse('avatar:bar'), TtsRuleScope.avatar('bar'));
    });

    test('parse throws on unrecognized shape', () {
      expect(() => TtsRuleScope.parse('whatever'), throwsFormatException);
    });
  });

  group('TtsRule', () {
    test('toJson includes optional fields only when set', () {
      final r = TtsRule(
        scope: TtsRuleScope.app('candy-ai'),
        stage: TtsRuleStage.brainNormalize,
        kind: TtsRuleKind.substringSubs,
        body: {
          'rules': [
            {'find': 'amazon', 'replace': 'ammazon'},
          ],
        },
        note: 'Reported 2026-06-27',
      );
      final json = r.toJson();
      expect(json['id'], isNull);
      expect(json.containsKey('id'), isFalse);
      expect(json.containsKey('lang'), isFalse);
      expect(json['scope'], 'app:candy-ai');
      expect(json['stage'], 'brain_normalize');
      expect(json['kind'], 'substring_subs');
      expect(json['note'], 'Reported 2026-06-27');
    });

    test('fromJson + toJson round-trip', () {
      final original = TtsRule(
        id: 'rule_abc123',
        scope: TtsRuleScope.avatar('jesus'),
        stage: TtsRuleStage.ttsPrepass,
        kind: TtsRuleKind.regexSubs,
        body: {
          'rules': [
            {'pattern': r"\by'all\b", 'replace': 'you all'},
          ],
        },
        note: 'y\'all -> you all',
        lang: ['en'],
      );
      final restored = TtsRule.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.scope, original.scope);
      expect(restored.stage, original.stage);
      expect(restored.kind, original.kind);
      expect(restored.note, original.note);
      expect(restored.lang, ['en']);
    });

    test('fromJson tolerates Map (not Map<String, dynamic>) body', () {
      // Some JSON decoders hand back Map<dynamic, dynamic> for nested objects.
      final json = {
        'id': 'r1',
        'scope': 'global',
        'stage': 'tts_prepass',
        'kind': 'lowercase',
        'body': <dynamic, dynamic>{},
        'note': 'just lowercase',
      };
      final r = TtsRule.fromJson(json);
      expect(r.body, isEmpty);
    });

    test('fromJson throws on unknown stage / kind / scope', () {
      final base = {
        'id': 'r1',
        'scope': 'global',
        'stage': 'tts_prepass',
        'kind': 'lowercase',
        'body': <String, dynamic>{},
        'note': '',
      };
      expect(
        () => TtsRule.fromJson({...base, 'stage': 'bogus_stage'}),
        throwsFormatException,
      );
      expect(
        () => TtsRule.fromJson({...base, 'kind': 'bogus_kind'}),
        throwsFormatException,
      );
      expect(
        () => TtsRule.fromJson({...base, 'scope': 'tenant?foo'}),
        throwsFormatException,
      );
    });
  });

  group('TtsAuditionResult', () {
    test('decodes base64 audio + optional divergence', () {
      final r = TtsAuditionResult.fromJson({
        'audioBytes': base64Encode(<int>[0, 1, 2, 3]),
        'audioMimeType': 'audio/wav',
        'transcript': 'amazon',
        'divergence': 0.12,
      });
      expect(r.audioBytes, [0, 1, 2, 3]);
      expect(r.audioMimeType, 'audio/wav');
      expect(r.transcript, 'amazon');
      expect(r.divergence, 0.12);
    });

    test('divergence defaults to null when missing', () {
      final r = TtsAuditionResult.fromJson({
        'audioBytes': base64Encode(<int>[]),
        'audioMimeType': 'audio/mpeg',
        'transcript': '',
      });
      expect(r.divergence, isNull);
      expect(r.audioMimeType, 'audio/mpeg');
    });
  });

  group('AvatarAdminClient — TTS rules', () {
    final baseUrl = Uri.parse('https://staging.example');

    test('listRules: GET /ext-api/tts/rules with no filters → no query',
        () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'data': <dynamic>[]}),
              200);
        }),
      );

      final rules = await admin.listRules();
      expect(rules, isEmpty);
      expect(captured.method, 'GET');
      expect(captured.url.toString(),
          'https://staging.example/ext-api/tts/rules');
      expect(captured.url.queryParameters, isEmpty);
    });

    test('listRules: GET with scope + stage query params', () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'data': <dynamic>[]}),
              200);
        }),
      );

      await admin.listRules(
        scope: TtsRuleScope.app('candy-ai'),
        stage: TtsRuleStage.brainNormalize,
      );
      expect(captured.url.queryParameters, {
        'scope': 'app:candy-ai',
        'stage': 'brain_normalize',
      });
    });

    test('listRules: parses returned rule list', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': [
                {
                  'id': 'r1',
                  'scope': 'global',
                  'stage': 'tts_prepass',
                  'kind': 'substring_subs',
                  'body': {
                    'rules': [
                      {'find': 'a', 'replace': 'b'},
                    ],
                  },
                  'note': 'tiny',
                },
              ],
            }),
            200,
          );
        }),
      );
      final rules = await admin.listRules();
      expect(rules, hasLength(1));
      expect(rules.first.id, 'r1');
      expect(rules.first.kind, TtsRuleKind.substringSubs);
    });

    test('addRule: POSTs JSON + parses server-assigned id back', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          final inbound = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {...inbound, 'id': 'rule_assigned_42'},
            }),
            200,
          );
        }),
      );

      final created = await admin.addRule(TtsRule(
        scope: TtsRuleScope.app('candy-ai'),
        stage: TtsRuleStage.brainNormalize,
        kind: TtsRuleKind.lowercase,
        body: {},
        note: 'first rule',
      ));
      expect(created.id, 'rule_assigned_42');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/ext-api/tts/rules');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['scope'], 'app:candy-ai');
      expect(body.containsKey('id'), isFalse);
    });

    test('updateRule: PUTs to /ext-api/tts/rules/<id>', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'id': 'r1',
                'scope': 'global',
                'stage': 'tts_prepass',
                'kind': 'lowercase',
                'body': <String, dynamic>{},
                'note': 'updated',
              },
            }),
            200,
          );
        }),
      );

      await admin.updateRule(
        'r1',
        TtsRule(
          scope: TtsRuleScope.global,
          stage: TtsRuleStage.ttsPrepass,
          kind: TtsRuleKind.lowercase,
          body: {},
          note: 'updated',
        ),
      );
      expect(captured.method, 'PUT');
      expect(captured.url.path, '/ext-api/tts/rules/r1');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['id'], 'r1'); // server-side id stamped in even though
      // the caller's TtsRule had id=null.
    });

    test('updateRule: throws on empty id', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(
        () => admin.updateRule(
            '',
            TtsRule(
              scope: TtsRuleScope.global,
              stage: TtsRuleStage.ttsPrepass,
              kind: TtsRuleKind.lowercase,
              body: {},
              note: '',
            )),
        throwsArgumentError,
      );
    });

    test('deleteRule: DELETEs /ext-api/tts/rules/<id>', () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
              jsonEncode({'code': 0, 'data': 'ok'}), 200);
        }),
      );
      await admin.deleteRule('r1');
      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/ext-api/tts/rules/r1');
    });

    test('deleteRule: throws on empty id', () async {
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      expect(() => admin.deleteRule(''), throwsArgumentError);
    });

    test('auditionPhrase: POSTs phrase + parses audio result', () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'audioBytes': base64Encode(<int>[1, 2, 3]),
                'audioMimeType': 'audio/mpeg',
                'transcript': 'amazon',
                'divergence': 0.08,
              },
            }),
            200,
          );
        }),
      );

      final result = await admin.auditionPhrase(
        phrase: 'amazon',
        voiceId: 'voice-uuid',
        ttsSelection: 'tts5',
      );
      expect(result.audioBytes, [1, 2, 3]);
      expect(result.transcript, 'amazon');
      expect(result.divergence, 0.08);
      expect(captured.method, 'POST');
      expect(captured.url.path, '/ext-api/tts/audition');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['phrase'], 'amazon');
      expect(body['voiceId'], 'voice-uuid');
      expect(body['ttsSelection'], 'tts5');
      expect(body.containsKey('candidateRules'), isFalse);
    });

    test('auditionPhrase: candidateRules overlay serializes correctly',
        () async {
      late http.Request captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'audioBytes': base64Encode(<int>[]),
                'audioMimeType': 'audio/mpeg',
                'transcript': '',
              },
            }),
            200,
          );
        }),
      );
      await admin.auditionPhrase(
        phrase: 'test',
        candidateRules: [
          TtsRule(
            scope: TtsRuleScope.app('candy-ai'),
            stage: TtsRuleStage.brainNormalize,
            kind: TtsRuleKind.lowercase,
            body: {},
            note: 'candidate',
          ),
        ],
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final candidates = body['candidateRules'] as List;
      expect(candidates, hasLength(1));
      expect((candidates.first as Map)['scope'], 'app:candy-ai');
    });

    test('TTS rules calls send Authorization: Bearer when secretKey is set',
        () async {
      late http.BaseRequest captured;
      final admin = AvatarAdminClient(
        baseUrl: baseUrl,
        developerMode: true,
        secretKey: 'sk_tts_test',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'data': []}), 200);
        }),
      );
      await admin.listRules();
      expect(captured.headers['authorization'], 'Bearer sk_tts_test');
    });
  });

  group('TwaiClient', () {
    final testEnv = TwaiEnvironment(
      name: 'twai-test',
      baseUrl: Uri.parse('https://example.test'),
    );

    test('mseStreamSession inherits env + publishableKey + sessionId default',
        () {
      final twai = TwaiClient(
        env: testEnv,
        publishableKey: 'pk_test_xyz',
      );
      final session = twai.mseStreamSession(ttsSelection: 'tts5');
      expect(session, isA<MseStreamChatSession>());
      expect(session.baseUrl.toString(), 'https://example.test');
      expect(session.publishableKey, 'pk_test_xyz');
      expect(session.ttsSelection, 'tts5');
      expect(session.sessionId, startsWith('mse-'));
      twai.close();
    });

    test('mseStreamSession honors explicit sessionId override', () {
      final twai = TwaiClient(env: testEnv);
      final session = twai.mseStreamSession(
        ttsSelection: 'tts5',
        sessionId: 'mse-fixed-abc',
      );
      expect(session.sessionId, 'mse-fixed-abc');
      twai.close();
    });

    test('pipelineV13Session inherits publishableKey + env', () {
      final twai = TwaiClient(
        env: testEnv,
        publishableKey: 'pk_v13',
        httpClient: MockClient(
            (_) async => http.Response('not used in this test', 200)),
      );
      final session = twai.pipelineV13Session();
      expect(session.publishableKey, 'pk_v13');
      expect(session.baseUrl.toString(), 'https://example.test');
      twai.close();
    });

    test('admin throws when secretKey was not provided', () {
      final twai = TwaiClient(
        env: testEnv,
        publishableKey: 'pk_only',
      );
      expect(() => twai.admin(developerMode: true), throwsStateError);
      twai.close();
    });

    test('admin returns AvatarAdminClient when secretKey is set', () async {
      late http.BaseRequest captured;
      final twai = TwaiClient(
        env: testEnv,
        secretKey: 'sk_admin_xyz',
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'code': 0, 'data': <String>[]}), 200);
        }),
      );
      final admin = twai.admin(developerMode: true);
      expect(admin, isA<AvatarAdminClient>());
      await admin.readyAvatars();
      expect(captured.headers['authorization'], 'Bearer sk_admin_xyz');
      expect(captured.url.toString(),
          'https://example.test/ext-api/query_avatar_list');
      twai.close();
    });

    test('close() makes future factory calls throw StateError', () {
      final twai = TwaiClient(env: testEnv, publishableKey: 'pk_x');
      twai.close();
      expect(
        () => twai.mseStreamSession(ttsSelection: 'tts5'),
        throwsStateError,
      );
      expect(() => twai.admin(developerMode: true), throwsStateError);
    });

    test('close() is idempotent', () {
      final twai = TwaiClient(env: testEnv);
      twai.close();
      expect(twai.close, returnsNormally);
    });

    test('caller-provided httpClient is NOT closed by twai.close()', () {
      var hostClosed = false;
      final hostClient = _ClosableMockClient(() => hostClosed = true);
      final twai = TwaiClient(env: testEnv, httpClient: hostClient);
      twai.close();
      expect(hostClosed, isFalse,
          reason: 'TwaiClient must not close a customer-owned http.Client');
    });
  });

  group('AvatarCatalog', () {
    AvatarMetadata meta(String name, {String prompt = ''}) => AvatarMetadata(
          avatarName: name,
          prompt: prompt,
          createAt: DateTime.fromMillisecondsSinceEpoch(0),
          updateAt: DateTime.fromMillisecondsSinceEpoch(0),
        );

    test('twaiDefault ships the five 2wai roster avatars', () {
      final catalog = AvatarCatalog.twaiDefault();
      expect(catalog.name, '2wai');
      expect(
        catalog.entries.map((e) => e.slug),
        [
          'KenanAutoTrader',
          'jesus',
          'calum-worthy',
          'RobRiggle',
          'maradona',
        ],
      );
    });

    test('twaiDefault jesus voiceId matches shipped apps/jesus Avatar', () {
      // Regression guard: `apps/jesus/lib/main.dart` hardcodes the Jesus
      // voiceId — the catalog value must stay in sync or the Jesus app
      // and the catalog will point at different Qwen refs.
      final catalog = AvatarCatalog.twaiDefault();
      final jesus = catalog.entries.firstWhere((e) => e.slug == 'jesus');
      expect(jesus.voiceId, '9c32e898-e99c-4287-89a1-57f5243aa454');
      expect(jesus.pipelineNames, contains('RedJesusTalk1'));
    });

    test('overlay preserves entry order + drops non-catalog registry rows',
        () {
      final catalog = AvatarCatalog(name: 'test', entries: [
        const AvatarCatalogEntry(
          slug: 'a',
          displayName: 'A',
          tagline: 't',
          voiceId: 'va',
          ttsSelection: 'tts5',
          pipelineNames: {'A1'},
        ),
        const AvatarCatalogEntry(
          slug: 'b',
          displayName: 'B',
          tagline: 't',
          voiceId: 'vb',
          ttsSelection: 'tts5',
          pipelineNames: {'B1'},
        ),
      ]);
      // Deliberately shuffled + polluted with Penthouse-style rows.
      final registry = [
        meta('Penthouse_Sophi'),
        meta('B1', prompt: 'B-prompt'),
        meta('A1', prompt: 'A-prompt'),
        meta('random_row'),
      ];
      final display = catalog.overlay(registry, {'A1', 'B1'});
      expect(display.map((c) => c.entry.slug), ['a', 'b']);
      expect(display[0].registrations.single.prompt, 'A-prompt');
      expect(display[1].registrations.single.prompt, 'B-prompt');
    });

    test('overlay joins multi-variant entries and reports ready subset', () {
      final catalog = AvatarCatalog(name: 'test', entries: [
        const AvatarCatalogEntry(
          slug: 'multi',
          displayName: 'Multi',
          tagline: 't',
          voiceId: 'v',
          ttsSelection: 'tts5',
          pipelineNames: {'Talk1', 'Talk2', 'Talk3', 'Talk4'},
        ),
      ]);
      final registry = [
        meta('Talk1', prompt: 'shared'),
        meta('Talk2', prompt: 'shared'),
        meta('Talk3'),
      ];
      final display = catalog.overlay(registry, {'Talk1', 'Talk3'});
      expect(display, hasLength(1));
      final c = display.single;
      expect(c.isRegistered, isTrue);
      expect(c.registrations.map((r) => r.avatarName),
          containsAll(['Talk1', 'Talk2', 'Talk3']));
      expect(c.readyPipelineNames, {'Talk1', 'Talk3'});
      expect(c.isReady, isTrue);
      expect(c.representativePrompt, 'shared');
    });

    test('overlay includes catalog entries with no matching registry rows',
        () {
      final catalog = AvatarCatalog(name: 'test', entries: [
        const AvatarCatalogEntry(
          slug: 'staged',
          displayName: 'Staged',
          tagline: 't',
          voiceId: 'v',
          ttsSelection: 'tts5',
          pipelineNames: {'NotYetRegistered'},
        ),
      ]);
      final display = catalog.overlay([meta('SomethingElse')], {});
      expect(display, hasLength(1));
      final c = display.single;
      expect(c.isRegistered, isFalse);
      expect(c.isReady, isFalse);
      expect(c.registrations, isEmpty);
      expect(c.readyPipelineNames, isEmpty);
      expect(c.representativePrompt, isEmpty);
    });

    test(
        'overlay marks entry ready when only one of several variants is ready',
        () {
      final catalog = AvatarCatalog(name: 'test', entries: [
        const AvatarCatalogEntry(
          slug: 'partial',
          displayName: 'Partial',
          tagline: 't',
          voiceId: 'v',
          ttsSelection: 'tts5',
          pipelineNames: {'X1', 'X2'},
        ),
      ]);
      final display = catalog.overlay(
        [meta('X1'), meta('X2')],
        {'X2'},
      );
      final c = display.single;
      expect(c.isReady, isTrue);
      expect(c.readyPipelineNames, {'X2'});
    });

    test('representativePrompt picks the first non-empty prompt', () {
      final catalog = AvatarCatalog(name: 'test', entries: [
        const AvatarCatalogEntry(
          slug: 'x',
          displayName: 'X',
          tagline: 't',
          voiceId: 'v',
          ttsSelection: 'tts5',
          pipelineNames: {'V1', 'V2', 'V3'},
        ),
      ]);
      final display = catalog.overlay(
        [meta('V1'), meta('V2', prompt: 'from-v2'), meta('V3', prompt: 'v3')],
        {},
      );
      expect(display.single.representativePrompt, 'from-v2');
    });
  });

  group('GenAdminClient', () {
    final baseUrl = Uri.parse('https://gen.test');

    GenAdminClient client({
      required Future<http.Response> Function(http.Request req) handler,
      String? accessToken,
    }) =>
        GenAdminClient(
          baseUrl: baseUrl,
          httpClient: MockClient((req) async => handler(req)),
          accessToken: accessToken,
        );

    test('authenticate sets token; clearAuth drops it', () {
      final c = GenAdminClient(baseUrl: baseUrl);
      expect(c.isAuthenticated, isFalse);
      c.authenticate('jwt-1');
      expect(c.isAuthenticated, isTrue);
      expect(c.accessToken, 'jwt-1');
      c.clearAuth();
      expect(c.isAuthenticated, isFalse);
      expect(c.accessToken, isNull);
      c.close();
    });

    test('authenticate rejects empty token', () {
      final c = GenAdminClient(baseUrl: baseUrl);
      expect(() => c.authenticate(''), throwsArgumentError);
      c.close();
    });

    test('authed call without token throws StateError before HTTP', () async {
      final c = client(handler: (_) async {
        fail('HTTP should not be attempted when no token is set');
      });
      expect(() => c.getMe(), throwsStateError);
      c.close();
    });

    test('requestOtp POSTs email without auth header', () async {
      late http.Request captured;
      final c = client(handler: (req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      await c.requestOtp('me@example.com');
      expect(captured.method, 'POST');
      expect(captured.url.toString(),
          'https://gen.test/api/auth/request-otp');
      expect(captured.headers['authorization'], isNull);
      expect(jsonDecode(captured.body), {'email': 'me@example.com'});
      c.close();
    });

    test('verifyOtp returns access_token from body', () async {
      final c = client(handler: (_) async => http.Response(
            jsonEncode({'access_token': 'jwt-xyz'}),
            200,
          ));
      final t = await c.verifyOtp(email: 'me@example.com', code: '123456');
      expect(t, 'jwt-xyz');
      c.close();
    });

    test('verifyOtp maps 401 to unauthorized', () async {
      final c = client(handler: (_) async => http.Response(
            jsonEncode({'detail': 'Invalid or expired code'}),
            401,
          ));
      expect(
        () => c.verifyOtp(email: 'me@example.com', code: '000000'),
        throwsA(isA<GenApiUnauthorizedException>().having(
            (e) => e.detail, 'detail', 'Invalid or expired code')),
      );
      c.close();
    });

    test('getMe sends Bearer + decodes user', () async {
      late http.BaseRequest captured;
      final c = client(
        accessToken: 'jwt-abc',
        handler: (req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'id': 42,
              'email': 'op@2wai.ai',
              'username': 'op',
              'display_name': 'Operator',
              'credits': 27,
              'subscription_tier': 'free',
              'level': 1,
            }),
            200,
          );
        },
      );
      final me = await c.getMe();
      expect(captured.headers['authorization'], 'Bearer jwt-abc');
      expect(captured.url.toString(), 'https://gen.test/api/auth/me');
      expect(me.id, 42);
      expect(me.email, 'op@2wai.ai');
      expect(me.credits, 27);
      c.close();
    });

    test('checkName appends query param', () async {
      late http.BaseRequest captured;
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          captured = req;
          return http.Response(
            jsonEncode({'available': true, 'normalized': 'my_avatar'}),
            200,
          );
        },
      );
      final r = await c.checkName('My Avatar!');
      expect(captured.url.queryParameters['avatarname'], 'My Avatar!');
      expect(r.available, isTrue);
      expect(r.normalized, 'my_avatar');
      c.close();
    });

    test('uploadSas passes kind and decodes upload url', () async {
      late http.Request captured;
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'upload_url': 'https://blob.test/idle?sig=x',
              'blob_path': 'gen/rid-abc/idle.mp4',
            }),
            200,
          );
        },
      );
      final r = await c.uploadSas(kind: GenAssetKind.idle);
      expect(jsonDecode(captured.body), {'kind': 'idle'});
      expect(r.uploadUrl, 'https://blob.test/idle?sig=x');
      expect(r.blobPath, 'gen/rid-abc/idle.mp4');
      expect(r.all, isNull);
      c.close();
    });

    test('uploadSas kind=all surfaces the all-map', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({
            'upload_url': 'https://blob.test/idle?sig=x',
            'blob_path': 'gen/rid-abc/idle.mp4',
            'all': {
              'idle_sas': 'https://blob.test/idle?sig=x',
              'idle_path': 'gen/rid-abc/idle.mp4',
              'talking_sas': 'https://blob.test/talking?sig=y',
              'talking_path': 'gen/rid-abc/talking.mp4',
              'voice_sas': 'https://blob.test/voice?sig=z',
              'voice_path': 'gen/rid-abc/voice.wav',
            },
          }),
          200,
        ),
      );
      final r = await c.uploadSas(kind: GenAssetKind.all);
      expect(r.all, isNotNull);
      expect(r.all!['voice_path'], 'gen/rid-abc/voice.wav');
      c.close();
    });

    test('createSubmission body shape + happy path', () async {
      late http.Request captured;
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          captured = req;
          return http.Response(
            jsonEncode({'submission_id': 88, 'rid': 'gen-xyz123'}),
            200,
          );
        },
      );
      final r = await c.createSubmission(
        avatarname: 'preacher',
        form: {'oneliner': 'Loves the mountains'},
        assetRefs: {'idle_blob': 'gen/rid/idle.mp4'},
      );
      expect(captured.url.toString(),
          'https://gen.test/api/gen/submissions');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['avatarname'], 'preacher');
      expect(body['form'], {'oneliner': 'Loves the mountains'});
      expect(body['asset_refs'], {'idle_blob': 'gen/rid/idle.mp4'});
      expect(body['consent_attested'], isTrue);
      expect(r.submissionId, 88);
      expect(r.rid, 'gen-xyz123');
      c.close();
    });

    test('createSubmission maps 402 to insufficient credits', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({'detail': 'Insufficient credits'}),
          402,
        ),
      );
      expect(
        () => c.createSubmission(avatarname: 'x'),
        throwsA(isA<GenApiInsufficientCreditsException>().having(
            (e) => e.detail, 'detail', 'Insufficient credits')),
      );
      c.close();
    });

    test('createSubmission maps 422 to validation error', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({'detail': 'consent_attested must be true'}),
          422,
        ),
      );
      expect(
        () => c.createSubmission(avatarname: 'x', consentAttested: false),
        throwsA(isA<GenApiValidationException>()),
      );
      c.close();
    });

    test('listAvatars decodes newest-first summaries', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({
            'avatars': [
              {
                'id': 2,
                'avatarname': 'newer',
                'rid': 'gen-2',
                'status': 'ready',
                'idle_url': 'https://blob/x/idle.mp4?s=1',
                'poster_url': 'https://blob/x/p.jpg?s=1',
                'created_at': '2026-07-06T12:00:00Z',
              },
              {
                'id': 1,
                'avatarname': 'older',
                'rid': 'gen-1',
                'status': 'processing',
                'idle_url': '',
                'poster_url': '',
                'created_at': '2026-07-05T09:00:00Z',
              },
            ],
          }),
          200,
        ),
      );
      final list = await c.listAvatars();
      expect(list, hasLength(2));
      expect(list[0].rid, 'gen-2');
      expect(list[0].status, GenAvatarStatus.ready);
      expect(list[1].status, GenAvatarStatus.processing);
      c.close();
    });

    test('submissionStatus decodes stage map with defaults', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          expect(req.url.toString(),
              'https://gen.test/api/gen/submission/88/status');
          return http.Response(
            jsonEncode({
              'current_stage': 'footage_wav2lip',
              // Server only sends stages that have progressed.
              'stages': {
                'validate': 'done',
                'reserve_credits': 'done',
                'voice_clone': 'done',
                'footage_wav2lip': 'running',
              },
              'overall_pct': 43,
              'status': 'running',
              'error_message': null,
              'avatar_status': 'processing',
              'brain_configured': false,
              'brain_status': 'none',
              'rid': 'gen-abc',
            }),
            200,
          );
        },
      );
      final s = await c.submissionStatus(88);
      expect(s.currentStage, GenStage.footageWav2lip);
      expect(s.overallPct, 43);
      expect(s.rid, 'gen-abc');
      expect(s.stages[GenStage.validate], GenStageState.done);
      expect(s.stages[GenStage.footageWav2lip], GenStageState.running);
      // Missing stages default to pending — forward-compat.
      expect(s.stages[GenStage.notify], GenStageState.pending);
      expect(s.brainStatus, GenBrainStatus.none);
      expect(s.brainConfigured, isFalse);
      expect(s.isReady, isFalse);
      c.close();
    });

    test('avatarStatus reports fully-ready when brain done + avatar ready',
        () async {
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          expect(req.url.toString(),
              'https://gen.test/api/gen/avatars/gen-xyz/status');
          return http.Response(
            jsonEncode({
              'current_stage': 'notify',
              'stages': {
                'validate': 'done',
                'reserve_credits': 'done',
                'voice_clone': 'done',
                'footage_wav2lip': 'done',
                'register': 'done',
                'smoke_verify': 'done',
                'notify': 'done',
              },
              'overall_pct': 100,
              'status': 'ready',
              'error_message': null,
              'avatar_status': 'ready',
              'brain_configured': true,
              'brain_status': 'ready',
              'rid': 'gen-xyz',
            }),
            200,
          );
        },
      );
      final s = await c.avatarStatus('gen-xyz');
      expect(s.isReady, isTrue);
      expect(s.avatarStatus, GenAvatarStatus.ready);
      expect(s.brainStatus, GenBrainStatus.ready);
      c.close();
    });

    test('avatarStatus surfaces error_message on failure', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({
            'current_stage': 'footage_wav2lip',
            'stages': {'footage_wav2lip': 'failed'},
            'overall_pct': 40,
            'status': 'failed',
            'error_message': 'GPU worker OOM',
            'avatar_status': 'failed',
            'brain_configured': false,
            'brain_status': 'none',
            'rid': 'gen-oom',
          }),
          200,
        ),
      );
      final s = await c.avatarStatus('gen-oom');
      expect(s.errorMessage, 'GPU worker OOM');
      expect(s.avatarStatus, GenAvatarStatus.failed);
      expect(s.avatarStatus.isTerminal, isTrue);
      c.close();
    });

    test('getBrain decodes persona + core fields', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({
            'persona': {'name': 'Preacher', 'oneliner': 'Kind words'},
            'configured': true,
            'brain_status': 'ready',
            'core_fields': ['name', 'oneliner', 'personality', 'greeting'],
          }),
          200,
        ),
      );
      final b = await c.getBrain('gen-x');
      expect(b.persona['name'], 'Preacher');
      expect(b.configured, isTrue);
      expect(b.brainStatus, GenBrainStatus.ready);
      expect(b.coreFields, containsAll(['name', 'greeting']));
      c.close();
    });

    test('putBrain PUTs persona wrapped in body', () async {
      late http.Request captured;
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'ok': true,
              'brain_status': 'configuring',
              'status': 'needs_personality'
            }),
            200,
          );
        },
      );
      await c.putBrain(
        rid: 'gen-x',
        persona: {'name': 'X', 'oneliner': 'y'},
      );
      expect(captured.method, 'PUT');
      expect(captured.url.toString(),
          'https://gen.test/api/gen/avatars/gen-x/brain');
      expect(jsonDecode(captured.body), {
        'persona': {'name': 'X', 'oneliner': 'y'},
      });
      c.close();
    });

    test('deleteAvatar issues DELETE', () async {
      late http.BaseRequest captured;
      final c = client(
        accessToken: 'jwt',
        handler: (req) async {
          captured = req;
          return http.Response(jsonEncode({'ok': true}), 200);
        },
      );
      await c.deleteAvatar('gen-x');
      expect(captured.method, 'DELETE');
      expect(captured.url.toString(),
          'https://gen.test/api/gen/avatars/gen-x');
      c.close();
    });

    test('deleteAvatar maps 404 to not-found', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response(
          jsonEncode({'detail': 'Avatar not found'}),
          404,
        ),
      );
      expect(
        () => c.deleteAvatar('gen-missing'),
        throwsA(isA<GenApiNotFoundException>()),
      );
      c.close();
    });

    test('unknown HTTP status falls through to GenApiHttpException',
        () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response('boom', 500),
      );
      expect(
        () => c.listAvatars(),
        throwsA(isA<GenApiHttpException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
      c.close();
    });

    test('transport exception wraps socket errors', () async {
      final c = client(handler: (_) async => throw const SocketException('x'));
      expect(
        () => c.requestOtp('me@example.com'),
        throwsA(isA<GenApiTransportException>()),
      );
      c.close();
    });

    test('detail extractor tolerates non-JSON bodies', () async {
      final c = client(
        accessToken: 'jwt',
        handler: (_) async => http.Response('not json', 500),
      );
      try {
        await c.listAvatars();
        fail('expected GenApiHttpException');
      } on GenApiHttpException catch (e) {
        expect(e.detail, isNull);
        expect(e.body, 'not json');
      }
      c.close();
    });

    test('close() releases owned http client only', () {
      var externalClosed = false;
      final external = _ClosableMockClient(() => externalClosed = true);
      final c = GenAdminClient(baseUrl: baseUrl, httpClient: external);
      c.close();
      expect(externalClosed, isFalse,
          reason: 'caller-provided http client must not be closed');
    });
  });
}

/// http.Client that runs a callback on close — used to verify ownership
/// semantics in the TwaiClient close test.
class _ClosableMockClient extends http.BaseClient {
  _ClosableMockClient(this._onClose);
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw UnimplementedError();
  }

  @override
  void close() {
    _onClose();
    super.close();
  }
}
