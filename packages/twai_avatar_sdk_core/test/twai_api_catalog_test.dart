/// Tests for the catalog-hydrate surface shipped with
/// `TwaiApiRestClient.getAvatar()`. Covers the JSON parsers
/// ([TwaiApiAvatarResult], [TwaiApiAvatar], [TwaiApiGreetingPayload]),
/// the HTTP method's status-code branches, and the typed exception
/// mapping on 404.
///
/// Same `MockClient`-based pattern as `twai_api_test.dart`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

void main() {
  final baseUrl = Uri.parse('https://api.example.test');

  // ── Golden JSON fixtures ─────────────────────────────────────────────
  //
  // These mirror the shape documented in docs/catalog_hydrate_plan.md.
  // Updating a field here forces a conscious decision; the parser tests
  // + the HTTP flow tests both read from the same literal so a wire
  // change breaks the test suite in a visible way.

  final publicAvatarJson = <String, dynamic>{
    'avatar': {
      'owner': '2wai',
      'name': 'brian-alman',
      'display_name': 'Dr. Brian Alman',
      'avatar_id': 'avt_abc123',
      'listed': true,
      'idle_url': 'https://blob.example.test/BrianAlman/idle.mp4?sig=xyz',
      'poster_url': 'https://blob.example.test/BrianAlman/poster.jpg?sig=xyz',
      'greeting': {
        'id': 'grt_42',
        'video_url': 'https://blob.example.test/BrianAlman/grt_42.mp4?sig=xyz',
        'text': 'Welcome. Let me ask you something.',
        'kind': 'intro',
      },
    },
    'view_token': null,
  };

  final privateAvatarJson = <String, dynamic>{
    'avatar': {
      'owner': 'lumara-corp',
      'name': 'cody',
      'display_name': 'Cody',
      'avatar_id': 'avt_private_1',
      'listed': false,
      'idle_url': 'https://blob.example.test/Cody/idle.mp4?sig=xyz',
      'poster_url': null,
      'greeting': null,
    },
    'view_token': {
      'token': 'vt_cody_300s',
      'expires_at': '2026-10-04T12:30:00Z',
    },
  };

  final returnGreetingAvatarJson = <String, dynamic>{
    'avatar': {
      'owner': '2wai',
      'name': 'krystal-casual',
      'display_name': 'Krystal',
      'avatar_id': 'avt_krystal',
      'listed': true,
      'idle_url': 'https://blob.example.test/Krystal/idle.mp4?sig=xyz',
      'poster_url': 'https://blob.example.test/Krystal/poster.jpg?sig=xyz',
      'greeting': {
        'id': 'rg_7',
        'video_url': 'https://blob.example.test/Krystal/rg_7.mp4?sig=xyz',
        'text': "I've been thinking about what you said last time.",
        'kind': 'return',
        'consumption_key': 'rg-7-1727900000',
      },
    },
    'view_token': null,
  };

  group('TwaiApiAvatarResult.fromJson', () {
    test('public avatar — viewToken is null', () {
      final result = TwaiApiAvatarResult.fromJson(publicAvatarJson);
      expect(result.avatar.owner, '2wai');
      expect(result.avatar.name, 'brian-alman');
      expect(result.avatar.displayName, 'Dr. Brian Alman');
      expect(result.avatar.avatarId, 'avt_abc123');
      expect(result.avatar.listed, isTrue);
      expect(result.viewToken, isNull);
    });

    test('private tenant-owned avatar — viewToken is present', () {
      final result = TwaiApiAvatarResult.fromJson(privateAvatarJson);
      expect(result.avatar.listed, isFalse);
      expect(result.viewToken, isNotNull);
      // viewToken is Object? on the core type — any shape passes
      // through. Consumer casts to the typed credentials in the
      // sdk layer.
      expect(result.viewToken, isA<Map>());
    });
  });

  group('TwaiApiAvatar.fromJson', () {
    test('populates all fields when present', () {
      final json = (publicAvatarJson['avatar'] as Map).cast<String, dynamic>();
      final avatar = TwaiApiAvatar.fromJson(json);
      expect(avatar.owner, '2wai');
      expect(avatar.name, 'brian-alman');
      expect(avatar.displayName, 'Dr. Brian Alman');
      expect(avatar.avatarId, 'avt_abc123');
      expect(avatar.idleUrl.toString(),
          'https://blob.example.test/BrianAlman/idle.mp4?sig=xyz');
      expect(avatar.posterUrl.toString(),
          'https://blob.example.test/BrianAlman/poster.jpg?sig=xyz');
      expect(avatar.greeting, isNotNull);
    });

    test('null idle_url and poster_url pass through as null (gen-2wai nullable)',
        () {
      final json = (privateAvatarJson['avatar'] as Map).cast<String, dynamic>();
      final avatar = TwaiApiAvatar.fromJson(json);
      expect(avatar.posterUrl, isNull);
      expect(avatar.idleUrl, isNotNull);
    });

    test('empty idle_url string treated as null', () {
      final avatar = TwaiApiAvatar.fromJson({
        'owner': '2wai',
        'name': 'test',
        'display_name': 'Test',
        'avatar_id': 'avt_test',
        'listed': true,
        'idle_url': '',
        'poster_url': '',
      });
      expect(avatar.idleUrl, isNull);
      expect(avatar.posterUrl, isNull);
      expect(avatar.greeting, isNull);
    });

    test('greeting absent → greeting field is null', () {
      final json = (privateAvatarJson['avatar'] as Map).cast<String, dynamic>();
      final avatar = TwaiApiAvatar.fromJson(json);
      expect(avatar.greeting, isNull);
    });

    test('toJson roundtrip preserves fields', () {
      final avatar = TwaiApiAvatar.fromJson(
          (publicAvatarJson['avatar'] as Map).cast<String, dynamic>());
      final roundtripped = TwaiApiAvatar.fromJson(avatar.toJson());
      expect(roundtripped.owner, avatar.owner);
      expect(roundtripped.name, avatar.name);
      expect(roundtripped.avatarId, avatar.avatarId);
      expect(roundtripped.idleUrl, avatar.idleUrl);
      expect(roundtripped.greeting?.id, avatar.greeting?.id);
    });
  });

  group('TwaiApiGreetingPayload.fromJson', () {
    test('intro greeting — no consumption key', () {
      final avatar = TwaiApiAvatar.fromJson(
          (publicAvatarJson['avatar'] as Map).cast<String, dynamic>());
      final greeting = avatar.greeting!;
      expect(greeting.id, 'grt_42');
      expect(greeting.kind, 'intro');
      expect(greeting.consumptionKey, isNull);
      expect(greeting.text, 'Welcome. Let me ask you something.');
    });

    test('return greeting — carries consumption key', () {
      final avatar = TwaiApiAvatar.fromJson(
          (returnGreetingAvatarJson['avatar'] as Map).cast<String, dynamic>());
      final greeting = avatar.greeting!;
      expect(greeting.id, 'rg_7');
      expect(greeting.kind, 'return');
      expect(greeting.consumptionKey, 'rg-7-1727900000');
    });

    test('toJson preserves wire kind string', () {
      final avatar = TwaiApiAvatar.fromJson(
          (returnGreetingAvatarJson['avatar'] as Map).cast<String, dynamic>());
      final greeting = avatar.greeting!;
      expect(greeting.toJson()['kind'], 'return');
      expect(greeting.toJson()['consumption_key'], 'rg-7-1727900000');
    });
  });

  group('TwaiApiRestClient.getAvatar HTTP flow', () {
    test('200 → returns TwaiApiAvatarResult; URL + sk_ header correct',
        () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode(publicAvatarJson), 200,
            headers: {'content-type': 'application/json'});
      });

      final client = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_abc'),
        httpClient: mock,
      );
      final result =
          await client.getAvatar(owner: '2wai', name: 'brian-alman');

      expect(captured.method, 'GET');
      expect(captured.url.toString(),
          'https://api.example.test/v1/avatars/2wai/brian-alman');
      expect(captured.headers['Authorization'], 'Bearer sk_test_abc');
      expect(result.avatar.avatarId, 'avt_abc123');
      client.close();
    });

    test('404 with named detail → TwaiApiAvatarNotFoundException', () async {
      final mock = MockClient((req) async => http.Response(
            jsonEncode({'detail': 'no_such_avatar'}),
            404,
            headers: {'content-type': 'application/json'},
          ));
      final client = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_abc'),
        httpClient: mock,
      );

      try {
        await client.getAvatar(owner: '2wai', name: 'does-not-exist');
        fail('expected TwaiApiAvatarNotFoundException');
      } on TwaiApiAvatarNotFoundException catch (e) {
        expect(e.owner, '2wai');
        expect(e.name, 'does-not-exist');
        expect(e.detail, 'no_such_avatar');
      }
      client.close();
    });

    test('404 with non-JSON body → still throws TwaiApiAvatarNotFoundException '
        'with null detail', () async {
      final mock = MockClient((req) async =>
          http.Response('<html>404 Not Found</html>', 404));
      final client = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_abc'),
        httpClient: mock,
      );

      try {
        await client.getAvatar(owner: '2wai', name: 'x');
        fail('expected TwaiApiAvatarNotFoundException');
      } on TwaiApiAvatarNotFoundException catch (e) {
        expect(e.detail, isNull);
      }
      client.close();
    });

    test('401 → TwaiApiUnauthorizedException (standard ladder)', () async {
      final mock = MockClient((req) async => http.Response('unauthorized', 401));
      final client = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_bad'),
        httpClient: mock,
      );

      expect(
        () => client.getAvatar(owner: '2wai', name: 'brian-alman'),
        throwsA(isA<TwaiApiUnauthorizedException>()),
      );
      client.close();
    });

    test('owner / name are URL-encoded', () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode(publicAvatarJson), 200);
      });
      final client = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_abc'),
        httpClient: mock,
      );
      await client.getAvatar(owner: 'my/space', name: 'has space');
      // Uri.encodeComponent encodes slash and space.
      expect(captured.url.path, '/v1/avatars/my%2Fspace/has%20space');
      client.close();
    });

    test('malformed JSON on 200 → TwaiApiTransportException', () async {
      final mock = MockClient((req) async => http.Response('not json', 200));
      final client = TwaiApiRestClient(
        baseUrl: baseUrl,
        credentials: const TwaiApiKeyCredentials.devOnly('sk_test_abc'),
        httpClient: mock,
      );
      expect(
        () => client.getAvatar(owner: '2wai', name: 'brian-alman'),
        throwsA(isA<TwaiApiTransportException>()),
      );
      client.close();
    });
  });

  group('TwaiApiAvatarNotFoundException', () {
    test('message carries owner/name', () {
      const e = TwaiApiAvatarNotFoundException(
        owner: '2wai',
        name: 'ghost',
      );
      expect(e.message, 'avatar not found: 2wai/ghost');
      expect(e.detail, isNull);
    });

    test('kind is unknown (not transport/unauthorized)', () {
      const e = TwaiApiAvatarNotFoundException(owner: '2wai', name: 'x');
      expect(e.kind, TwaiErrorKind.unknown);
    });
  });
}
