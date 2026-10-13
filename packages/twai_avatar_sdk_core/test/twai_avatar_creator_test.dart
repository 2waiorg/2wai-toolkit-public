import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

/// Route-based MockClient for the gen-2wai endpoints. Records every
/// request so tests can assert order / headers / bodies.
MockClient _routes({
  Map<String, http.Response> getRoutes = const {},
  Map<String, http.Response Function(http.Request)> postRoutes = const {},
  Map<String, http.Response Function(http.Request)> putRoutes = const {},
  List<http.Request>? capture,
}) {
  return MockClient((request) async {
    capture?.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      final r = getRoutes[path];
      if (r != null) return r;
      return http.Response('{"detail":"unmapped GET $path"}', 404);
    }
    if (request.method == 'POST') {
      final builder = postRoutes[path];
      if (builder != null) return builder(request);
      return http.Response('{"detail":"unmapped POST $path"}', 404);
    }
    if (request.method == 'PUT') {
      // Match by absolute URL for Azure Blob PUTs since path doesn't
      // include the storage-account host discriminator.
      final builder = putRoutes[request.url.toString()] ?? putRoutes[path];
      if (builder != null) return builder(request);
      return http.Response('{"detail":"unmapped PUT $path"}', 404);
    }
    return http.Response('{"detail":"unmapped ${request.method}"}', 405);
  });
}

Uri _u(String s) => Uri.parse(s);

// Simple test env — no need to register globally, we just pass it
// straight into the creator.
TwaiEnvironment _testEnv() => TwaiEnvironment(
      name: 'gen-test',
      baseUrl: _u('https://gen.test.example'),
    );

void main() {
  group('GenAdminClient.mintViewToken', () {
    test('parses view_token + hydrated avatar map', () async {
      final client = GenAdminClient(
        baseUrl: _u('https://gen.test.example'),
        accessToken: 'jwt-abc',
        httpClient: _routes(getRoutes: {
          '/api/gen/view-token/alice/nova': http.Response(
            jsonEncode({
              'view_token': 'vt_short_lived_xxx',
              'avatar': {
                'slug': 'alice/nova',
                'name': 'Nova',
                'outfits': [
                  {
                    'slug': 'default',
                    'pipelineName': 'Gen_ab12_Talk1',
                    'idleUrl': 'https://cdn/idle.mp4',
                    'delivery': 'mse',
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        }),
      );
      final res = await client.mintViewToken(owner: 'alice', avatarname: 'nova');
      expect(res.viewToken, 'vt_short_lived_xxx');
      expect(res.avatar['slug'], 'alice/nova');
      expect(res.avatar['outfits'], isA<List<dynamic>>());
      client.close();
    });
  });

  group('GenAdminClient.requestReclips', () {
    test('POSTs to /api/gen/avatars/{rid}/reclips with empty body', () async {
      final captured = <http.Request>[];
      final client = GenAdminClient(
        baseUrl: _u('https://gen.test.example'),
        accessToken: 'jwt-abc',
        httpClient: _routes(
          capture: captured,
          postRoutes: {
            '/api/gen/avatars/gen-abc/reclips': (_) =>
                http.Response('{"ok":true}', 200),
          },
        ),
      );
      await client.requestReclips('gen-abc');
      expect(captured, hasLength(1));
      expect(captured.first.method, 'POST');
      expect(captured.first.body, '{}');
      expect(captured.first.headers['authorization'], 'Bearer jwt-abc');
      client.close();
    });
  });

  group('GenAdminClient.uploadBytes', () {
    test('PUTs raw bytes with x-ms-blob-type header (no bearer)', () async {
      final captured = <http.Request>[];
      final client = GenAdminClient(
        baseUrl: _u('https://gen.test.example'),
        accessToken: 'jwt-abc',
        httpClient: _routes(
          capture: captured,
          putRoutes: {
            'https://blob.example.com/gen/idle.mp4?sig=xxx': (_) =>
                http.Response('', 201),
          },
        ),
      );
      await client.uploadBytes(
        uploadUrl: _u('https://blob.example.com/gen/idle.mp4?sig=xxx'),
        bytes: const [1, 2, 3, 4],
        contentType: 'video/mp4',
      );
      expect(captured, hasLength(1));
      final req = captured.first;
      expect(req.method, 'PUT');
      expect(req.headers['x-ms-blob-type'], 'BlockBlob');
      expect(req.headers['content-type'], 'video/mp4');
      // No bearer on SAS PUT (SAS grant is the auth) — regression
      // guard on the client not accidentally attaching it.
      expect(req.headers.containsKey('authorization'), isFalse);
      expect(req.bodyBytes, [1, 2, 3, 4]);
      client.close();
    });

    test('throws GenApiTransportException on non-2xx', () async {
      final client = GenAdminClient(
        baseUrl: _u('https://gen.test.example'),
        httpClient: _routes(putRoutes: {
          'https://blob.example.com/x.mp4': (_) =>
              http.Response('<AzureError/>', 403),
        }),
      );
      await expectLater(
        client.uploadBytes(
          uploadUrl: _u('https://blob.example.com/x.mp4'),
          bytes: const [0],
        ),
        throwsA(isA<GenApiTransportException>()),
      );
      client.close();
    });
  });

  group('TwaiAvatarCreator facade', () {
    test('createAvatar drives SAS + 3 uploads + submit + poll to ready',
        () async {
      final captured = <http.Request>[];
      final creator = TwaiAvatarCreator(
        env: _testEnv(),
        accessToken: 'jwt-abc',
        pollInterval: Duration.zero,
        httpClient: _routes(
          capture: captured,
          getRoutes: {
            // Status polls: emit one 'running' then 'ready'.
            '/api/gen/avatars/gen-nova-123/status': http.Response(
              jsonEncode({
                'rid': 'gen-nova-123',
                'current_stage': 'validate',
                'stages': {},
                'overall_pct': 100,
                'status': 'ready',
                'avatar_status': 'ready',
                'brain_status': 'ready',
                'brain_configured': true,
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          },
          postRoutes: {
            '/api/gen/uploads/sas': (_) => http.Response(
                  jsonEncode({
                    'upload_url': 'https://blob.example.com/idle',
                    'blob_path': 'gen/idle.mp4',
                    'all': {
                      'idle_sas': 'https://blob.example.com/idle?sig=1',
                      'idle_path': 'gen/idle.mp4',
                      'talking_sas': 'https://blob.example.com/talking?sig=2',
                      'talking_path': 'gen/talking.mp4',
                      'voice_sas': 'https://blob.example.com/voice?sig=3',
                      'voice_path': 'gen/voice.wav',
                    },
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                ),
            '/api/gen/submissions': (_) => http.Response(
                  jsonEncode({'submission_id': 42, 'rid': 'gen-nova-123'}),
                  200,
                  headers: {'content-type': 'application/json'},
                ),
          },
          putRoutes: {
            'https://blob.example.com/idle?sig=1': (_) =>
                http.Response('', 201),
            'https://blob.example.com/talking?sig=2': (_) =>
                http.Response('', 201),
            'https://blob.example.com/voice?sig=3': (_) =>
                http.Response('', 201),
          },
        ),
      );

      final progress = <String>[];
      final result = await creator.createAvatar(
        avatarname: 'nova',
        idleBytes: const [1],
        talkingBytes: const [2],
        voiceBytes: const [3],
        form: const {'name': 'Nova'},
        onProgress: (s) => progress.add(s.status),
      );

      expect(result.rid, 'gen-nova-123');
      expect(result.submissionId, 42);
      expect(result.avatarname, 'nova');
      expect(result.terminalStatus.avatarStatus, GenAvatarStatus.ready);
      expect(progress, contains('ready'));

      // Verify request ordering: SAS → 3 uploads → submission → 1+ polls.
      final paths = captured.map((r) => r.url.path).toList();
      expect(paths[0], '/api/gen/uploads/sas');
      // The three uploads happen in parallel — order not guaranteed
      // — assert they're all present before the submission.
      final uploadIdx = [
        for (var i = 0; i < paths.length; i++)
          if (paths[i].contains('idle') ||
              paths[i].contains('talking') ||
              paths[i].contains('voice'))
            i
      ];
      expect(uploadIdx, hasLength(3));
      final submissionIdx = paths.indexOf('/api/gen/submissions');
      expect(submissionIdx, greaterThan(uploadIdx.reduce((a, b) => a > b ? a : b)));
      final statusIdx = paths.indexOf('/api/gen/avatars/gen-nova-123/status');
      expect(statusIdx, greaterThan(submissionIdx));

      creator.close();
    });

    test('createAvatar throws when pipeline reports failed', () async {
      final creator = TwaiAvatarCreator(
        env: _testEnv(),
        accessToken: 'jwt-abc',
        pollInterval: Duration.zero,
        httpClient: _routes(
          getRoutes: {
            '/api/gen/avatars/gen-nope/status': http.Response(
              jsonEncode({
                'rid': 'gen-nope',
                'current_stage': 'voice_clone',
                'stages': {},
                'overall_pct': 50,
                'status': 'failed',
                'avatar_status': 'failed',
                'brain_status': 'pending',
                'brain_configured': false,
                'error_message': 'voice-clone timeout',
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          },
          postRoutes: {
            '/api/gen/uploads/sas': (_) => http.Response(
                  jsonEncode({
                    'upload_url': 'https://blob.example.com/idle',
                    'blob_path': 'gen/idle.mp4',
                    'all': {
                      'idle_sas': 'https://blob.example.com/idle?sig=1',
                      'idle_path': 'gen/idle.mp4',
                      'talking_sas': 'https://blob.example.com/talking?sig=2',
                      'talking_path': 'gen/talking.mp4',
                      'voice_sas': 'https://blob.example.com/voice?sig=3',
                      'voice_path': 'gen/voice.wav',
                    },
                  }),
                  200,
                ),
            '/api/gen/submissions': (_) => http.Response(
                  jsonEncode({'submission_id': 7, 'rid': 'gen-nope'}),
                  200,
                ),
          },
          putRoutes: {
            'https://blob.example.com/idle?sig=1': (_) =>
                http.Response('', 201),
            'https://blob.example.com/talking?sig=2': (_) =>
                http.Response('', 201),
            'https://blob.example.com/voice?sig=3': (_) =>
                http.Response('', 201),
          },
        ),
      );

      await expectLater(
        creator.createAvatar(
          avatarname: 'nope',
          idleBytes: const [0],
          talkingBytes: const [0],
          voiceBytes: const [0],
        ),
        throwsA(isA<GenApiTransportException>().having(
          (e) => e.message,
          'message',
          contains('voice_clone'),
        )),
      );
      creator.close();
    });

    test('watchProgress emits polls + closes on ready', () async {
      final creator = TwaiAvatarCreator(
        env: _testEnv(),
        accessToken: 'jwt-abc',
        pollInterval: Duration.zero,
        httpClient: _routes(getRoutes: {
          '/api/gen/avatars/gen-x/status': http.Response(
            jsonEncode({
              'rid': 'gen-x',
              'current_stage': 'notify',
              'stages': {},
              'overall_pct': 100,
              'status': 'ready',
              'avatar_status': 'ready',
              'brain_status': 'ready',
              'brain_configured': true,
            }),
            200,
          ),
        }),
      );
      final all = await creator.watchProgress('gen-x').toList();
      expect(all, isNotEmpty);
      expect(all.last.avatarStatus, GenAvatarStatus.ready);
      creator.close();
    });

    test('verifyAndSignIn stashes the returned token on the client',
        () async {
      final creator = TwaiAvatarCreator(
        env: _testEnv(),
        httpClient: _routes(
          getRoutes: {
            '/api/auth/me': http.Response(
              jsonEncode({
                'id': 1,
                'email': 'me@example.com',
                'username': 'me',
                'credits': 100,
                'is_admin': false,
              }),
              200,
            ),
          },
          postRoutes: {
            '/api/auth/verify-otp': (_) => http.Response(
                  jsonEncode({'access_token': 'jwt-fresh'}),
                  200,
                ),
          },
        ),
      );
      expect(creator.isAuthenticated, isFalse);
      final me = await creator.verifyAndSignIn(
        email: 'me@example.com',
        code: '123456',
      );
      expect(me.email, 'me@example.com');
      expect(creator.isAuthenticated, isTrue);
      expect(creator.accessToken, 'jwt-fresh');
      creator.close();
    });
  });
}
