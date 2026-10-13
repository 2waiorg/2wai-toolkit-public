/// Tests for Adapter 4 — twai-api `/v1/*` REST client, WS client, and
/// ChatSession. Follows the same fake-WS-server pattern as the
/// MseStreamChatSession tests in twai_avatar_sdk_core_test.dart:
/// bind a real HttpServer on 127.0.0.1:0 and upgrade requests to
/// WebSocket in-process. Mocks the REST plane with `MockClient`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

void main() {
  final baseUrl = Uri.parse('https://api.example.test');

  group('TwaiApiSessionMint.fromJson', () {
    test('happy path', () {
      final mint = TwaiApiSessionMint.fromJson({
        'session_id': 'sess_abc',
        'client_token': 'eyJhbGc.eyJzaWQi.sig',
        'websocket_url': 'wss://api.example.test/v1/stream?token=eyJhbGc',
        'transport': 'ws_v1',
      });
      expect(mint.sessionId, 'sess_abc');
      expect(mint.clientToken, 'eyJhbGc.eyJzaWQi.sig');
      expect(mint.websocketUrl.toString(),
          'wss://api.example.test/v1/stream?token=eyJhbGc');
      expect(mint.transport, 'ws_v1');
    });

    test('missing websocket_url → FormatException', () {
      expect(
        () => TwaiApiSessionMint.fromJson({
          'session_id': 'sess_abc',
          'client_token': 'x',
        }),
        throwsFormatException,
      );
    });
  });

  group('TwaiApiRestClient', () {
    test('createSession: POSTs /v1/sessions with sk_ Bearer + json body',
        () async {
      late http.Request captured;
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_xyz'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({
              'session_id': 'sess_1',
              'client_token': 'ct_1',
              'websocket_url':
                  'wss://api.example.test/v1/stream?token=ct_1',
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final mint = await rest.createSession(const TwaiApiSessionRequest(
        avatarId: 'avt_x',
        voiceId: 'vc_y',
      ));
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://api.example.test/v1/sessions');
      expect(captured.headers['authorization'], 'Bearer sk_test_xyz');
      expect(captured.headers['content-type'], 'application/json');
      expect(jsonDecode(captured.body), {
        'avatar_id': 'avt_x',
        'mode': 'video',
        'voice_id': 'vc_y',
      });
      expect(mint.sessionId, 'sess_1');
    });

    test('createSession: maps 401 to TwaiApiUnauthorizedException',
        () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_bad'),
        httpClient:
            MockClient((_) async => http.Response('bad key', 401)),
      );
      await expectLater(
        rest.createSession(const TwaiApiSessionRequest(avatarId: 'a')),
        throwsA(isA<TwaiApiUnauthorizedException>()),
      );
    });

    test('createSession: maps 429 with Retry-After', () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: MockClient(
          (_) async => http.Response(
            'over',
            429,
            headers: {'retry-after': '17'},
          ),
        ),
      );
      try {
        await rest.createSession(const TwaiApiSessionRequest(avatarId: 'a'));
        fail('expected rate-limit throw');
      } on TwaiApiRateLimitedException catch (e) {
        expect(e.retryAfterSeconds, 17);
      }
    });

    test('speak: POSTs /v1/sessions/{sid}/speak with text body', () async {
      late http.Request captured;
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('{"status":"speaking"}', 200);
        }),
      );
      await rest.speak('sess_1', 'hello there', voiceId: 'vc_y');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/sessions/sess_1/speak');
      expect(jsonDecode(captured.body), {
        'text': 'hello there',
        'voice_id': 'vc_y',
      });
    });

    test('interrupt: POSTs /v1/sessions/{sid}/interrupt (no body)',
        () async {
      late http.Request captured;
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('{"status":"interrupted"}', 200);
        }),
      );
      await rest.interrupt('sess_1');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/sessions/sess_1/interrupt');
      // No body → no content-type header (we only set it when body != null).
      expect(captured.headers.containsKey('content-type'), isFalse);
    });

    test('prefixed baseUrl (mint-proxy at /twai) preserves the prefix',
        () async {
      late Uri capturedUrl;
      final rest = TwaiApiRestClient(
        baseUrl: Uri.parse('https://myapp.com/twai'),
        credentials: const AnonymousCredentials(),
        httpClient: MockClient((req) async {
          capturedUrl = req.url;
          return http.Response(
            jsonEncode({
              'session_id': 's',
              'client_token': 'ct',
              'websocket_url': 'wss://api.twai.ai/v1/stream?token=ct',
            }),
            201,
          );
        }),
      );
      await rest.createSession(const TwaiApiSessionRequest(avatarId: 'a'));
      expect(capturedUrl.toString(), 'https://myapp.com/twai/v1/sessions');
    });

    test('deleteSession: issues DELETE, accepts 204', () async {
      late http.BaseRequest captured;
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('', 204);
        }),
      );
      await rest.deleteSession('sess_1');
      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/v1/sessions/sess_1');
    });
  });

  group('TwaiApiChatSession (fake WS)', () {
    late HttpServer wsServer;
    late Completer<WebSocket> serverSocket;
    late Completer<Uri> serverHandshakeUri;
    late Uri wsBaseUrl;

    setUp(() async {
      serverSocket = Completer<WebSocket>();
      serverHandshakeUri = Completer<Uri>();
      wsServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // Server binds on http:// but WebSocketChannel requires ws:// — the
      // handshake protocol is identical, just a scheme rename.
      wsBaseUrl = Uri.parse('ws://${wsServer.address.host}:${wsServer.port}');
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

    // Build a MockClient that answers /v1/sessions with a mint pointing
    // at the local WS server, and /speak / /interrupt / DELETE with
    // stubbed 200s.
    http.Client mintClient({required String sessionId, required Uri wsUrl}) {
      return MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path == '/v1/sessions') {
          return http.Response(
            jsonEncode({
              'session_id': sessionId,
              'client_token': 'ct_$sessionId',
              'websocket_url': wsUrl.toString(),
              'transport': 'ws_v1',
            }),
            201,
          );
        }
        if (req.method == 'POST' && path.endsWith('/speak')) {
          return http.Response('{"status":"speaking"}', 200);
        }
        if (req.method == 'POST' && path.endsWith('/interrupt')) {
          return http.Response('{"status":"interrupted"}', 200);
        }
        if (req.method == 'DELETE') {
          return http.Response('', 204);
        }
        return http.Response('unexpected mock request: ${req.method} $path',
            500);
      });
    }

    test(
        'connect: mints session, opens WS at mint.websocket_url, awaits session.ready',
        () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: mintClient(sessionId: 'sess_1', wsUrl: wsBaseUrl),
      );
      final session = TwaiApiChatSession(restClient: rest);

      // Server side: as soon as WS connects, send session.ready.
      unawaited(serverSocket.future.then((ws) {
        ws.add(jsonEncode({'type': 'session.ready'}));
      }));

      await session.connect(const Avatar(id: 'avt_x'));
      expect(session.sessionId, 'sess_1');
      await session.close();
    });

    test(
        'sendMessage (no brain): echoes text via /speak, emits reply on replyText',
        () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: mintClient(sessionId: 'sess_1', wsUrl: wsBaseUrl),
      );
      final session = TwaiApiChatSession(restClient: rest);
      unawaited(serverSocket.future.then((ws) {
        ws.add(jsonEncode({'type': 'session.ready'}));
      }));
      await session.connect(const Avatar(id: 'avt_x'));

      final replies = <String>[];
      session.replyText.listen(replies.add);

      await session.sendMessage('hello');
      // give the microtask queue a beat to deliver the broadcast event
      await Future<void>.delayed(Duration.zero);
      expect(replies, ['hello']);
      await session.close();
    });

    test(
        'sendMessage (with brain): brain(text) → reply, reply goes to /speak, reply emits',
        () async {
      String? spokenText;
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: MockClient((req) async {
          if (req.method == 'POST' &&
              req.url.path == '/v1/sessions') {
            return http.Response(
              jsonEncode({
                'session_id': 'sess_1',
                'client_token': 'ct_1',
                'websocket_url': wsBaseUrl.toString(),
              }),
              201,
            );
          }
          if (req.method == 'POST' && req.url.path.endsWith('/speak')) {
            spokenText =
                (jsonDecode(req.body) as Map<String, dynamic>)['text']
                    as String?;
            return http.Response('{"status":"speaking"}', 200);
          }
          if (req.method == 'DELETE') {
            return http.Response('', 204);
          }
          return http.Response('unexpected', 500);
        }),
      );
      final session = TwaiApiChatSession(
        restClient: rest,
        brain: (userText) async => 'REPLY: $userText',
      );
      unawaited(serverSocket.future.then((ws) {
        ws.add(jsonEncode({'type': 'session.ready'}));
      }));
      await session.connect(const Avatar(id: 'avt_x'));

      final replies = <String>[];
      session.replyText.listen(replies.add);

      await session.sendMessage('hi there');
      await Future<void>.delayed(Duration.zero);
      expect(spokenText, 'REPLY: hi there');
      expect(replies, ['REPLY: hi there']);
      await session.close();
    });

    test(
        'WS binary frames flow through to videoBytes; speaking events surface',
        () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: mintClient(sessionId: 'sess_1', wsUrl: wsBaseUrl),
      );
      final session = TwaiApiChatSession(restClient: rest);
      unawaited(serverSocket.future.then((ws) async {
        ws.add(jsonEncode({'type': 'session.ready'}));
        // Simulate a tiny fMP4-shaped payload.
        ws.add(Uint8List.fromList([0x00, 0x01, 0x02, 0x03]));
        ws.add(jsonEncode(
            {'type': 'speaking', 'value': 'start', 'pts': 0.0}));
      }));
      await session.connect(const Avatar(id: 'avt_x'));

      final bytes = <Uint8List>[];
      final speakings = <SpeakingEvent>[];
      session.videoBytes.listen(bytes.add);
      session.speakingEvents.listen(speakings.add);
      // Poll briefly for the events to arrive.
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while ((bytes.isEmpty || speakings.isEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(bytes.length, greaterThanOrEqualTo(1));
      expect(bytes.first, [0x00, 0x01, 0x02, 0x03]);
      expect(speakings.length, 1);
      expect(speakings.first.value, SpeakingState.start);
      await session.close();
    });

    test('sendMessage before connect → NotConnected', () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: mintClient(sessionId: 's', wsUrl: wsBaseUrl),
      );
      final session = TwaiApiChatSession(restClient: rest);
      await expectLater(
        session.sendMessage('x'),
        throwsA(isA<ChatSessionNotConnectedException>()),
      );
    });

    test('connect twice → AlreadyConnected', () async {
      final rest = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: mintClient(sessionId: 's', wsUrl: wsBaseUrl),
      );
      final session = TwaiApiChatSession(restClient: rest);
      unawaited(serverSocket.future.then((ws) {
        ws.add(jsonEncode({'type': 'session.ready'}));
      }));
      await session.connect(const Avatar(id: 'a'));
      await expectLater(
        session.connect(const Avatar(id: 'b')),
        throwsA(isA<ChatSessionAlreadyConnectedException>()),
      );
      await session.close();
    });
  });

  group('TwaiClient.apiSession', () {
    test('throws without secretKey', () {
      final twai = TwaiClient(env: TwaiEnvironment.twaiApi);
      expect(twai.apiSession, throwsStateError);
      twai.close();
    });

    test('builds a TwaiApiChatSession with secretKey wired', () {
      final twai = TwaiClient(
        env: TwaiEnvironment.twaiApi,
        secretKey: 'sk_test_x',
      );
      final session = twai.apiSession();
      expect(session, isA<TwaiApiChatSession>());
      twai.close();
    });
  });
}
