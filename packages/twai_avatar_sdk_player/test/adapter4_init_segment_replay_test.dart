/// Spot-check: Adapter 4 (twai-api /v1/*) flows video bytes through
/// TwaiAvatarPlayerController's init-segment cache the same way
/// Adapter 1 does. The cache lives on the controller (transport-
/// agnostic), so this is proving the wiring, not the mechanism.
///
/// Mason's diagnostic on 2026-07-27 asked whether Adapter 4 picked up
/// the init-segment replay fixes from commits 5bbbdbf / 69c5500
/// ("lips move, no audio, second reply fine" symptom on Mila) —
/// answer is yes; this test guards that answer from silent regression.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

void main() {
  group('Adapter 4 → TwaiAvatarPlayerController init-segment cache', () {
    late HttpServer wsServer;
    late Completer<WebSocket> serverSocket;
    late Uri wsBaseUrl;

    setUp(() async {
      serverSocket = Completer<WebSocket>();
      wsServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      wsBaseUrl = Uri.parse(
          'ws://${wsServer.address.host}:${wsServer.port}');
      wsServer.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        serverSocket.complete(ws);
      });
    });

    tearDown(() async {
      await wsServer.close(force: true);
    });

    test('cachedInitSegment captures first frame from Adapter 4 WS', () async {
      // A REST client whose mock answers /v1/sessions with a mint
      // pointing at our in-process WS server.
      final rest = TwaiApiRestClient(
        baseUrl: Uri.parse('https://api.example.test'),
        credentials: const TwaiApiKeyCredentials.devOnly('sk_x'),
        httpClient: MockClient((req) async {
          if (req.method == 'POST' && req.url.path == '/v1/sessions') {
            return http.Response(
              jsonEncode({
                'session_id': 'sess_1',
                'client_token': 'ct_1',
                'websocket_url': wsBaseUrl.toString(),
              }),
              201,
            );
          }
          if (req.method == 'DELETE') return http.Response('', 204);
          return http.Response('unexpected', 500);
        }),
      );

      final controller = TwaiAvatarPlayerController(
        sessionFactory: () => TwaiApiChatSession(restClient: rest),
      );

      // Server: on WS connect, send session.ready then a synthetic
      // fMP4 init-segment-shaped payload.
      final initSegment = Uint8List.fromList([
        // ftyp box header — nominal shape, doesn't have to parse.
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
        0x69, 0x73, 0x6F, 0x6D, 0x69, 0x73, 0x6F, 0x32,
      ]);
      unawaited(serverSocket.future.then((ws) async {
        ws.add(jsonEncode({'type': 'session.ready'}));
        // Wait a tick so the controller subscribes before the byte
        // arrives (the subscribe happens synchronously after ws.ready
        // completes; this is defensive).
        await Future<void>.delayed(Duration.zero);
        ws.add(initSegment);
      }));

      await controller.connect(const Avatar(id: 'avt_test'));

      // Poll briefly — the byte arrives async through the WS + gets
      // forwarded through the session's videoBytes stream + into the
      // controller's listener that populates the cache.
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (controller.cachedInitSegment == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(controller.cachedInitSegment, isNotNull,
          reason:
              'controller.cachedInitSegment should be populated from the '
              'first WS binary frame delivered via TwaiApiChatSession.videoBytes');
      expect(controller.cachedInitSegment, equals(initSegment));

      await controller.dispose();
    });
  });
}
