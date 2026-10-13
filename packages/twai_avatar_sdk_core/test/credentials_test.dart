import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

void main() {
  group('AnonymousCredentials', () {
    test('emits no headers and no WS params', () {
      const c = AnonymousCredentials();
      expect(c.httpHeaders(), isEmpty);
      expect(c.wsQueryParams(), isEmpty);
    });
  });

  group('PublicKeyCredentials', () {
    test(
        'emits BOTH Authorization: Bearer AND X-Twai-Key headers (parity with web-SDK)',
        () {
      const c = PublicKeyCredentials('pk_live_abc');
      final headers = c.httpHeaders();
      expect(headers['Authorization'], 'Bearer pk_live_abc');
      expect(headers['X-Twai-Key'], 'pk_live_abc');
      expect(headers, hasLength(2));
      expect(c.wsQueryParams(), {'key': 'pk_live_abc'});
    });

    test('empty key produces no headers / params', () {
      const c = PublicKeyCredentials('');
      expect(c.httpHeaders(), isEmpty);
      expect(c.wsQueryParams(), isEmpty);
    });
  });

  group('ViewTokenCredentials', () {
    test('emits X-View-Token header + view_token WS param', () {
      final c = ViewTokenCredentials('vt_initial');
      expect(c.httpHeaders(), {'X-View-Token': 'vt_initial'});
      expect(c.wsQueryParams(), {'view_token': 'vt_initial'});
    });

    test('setToken rotates the token in place', () {
      final c = ViewTokenCredentials('vt_old');
      expect(c.token, 'vt_old');
      c.setToken('vt_new');
      expect(c.token, 'vt_new');
      expect(c.httpHeaders(), {'X-View-Token': 'vt_new'});
      expect(c.wsQueryParams(), {'view_token': 'vt_new'});
    });

    test('empty token → no headers / params', () {
      final c = ViewTokenCredentials('');
      expect(c.httpHeaders(), isEmpty);
      c.setToken('vt_new');
      expect(c.httpHeaders(), {'X-View-Token': 'vt_new'});
      c.setToken('');
      expect(c.httpHeaders(), isEmpty);
    });
  });

  group('BearerJwtCredentials', () {
    test('emits Authorization: Bearer header + no WS param', () {
      const c = BearerJwtCredentials('eyJhbGc...');
      expect(c.httpHeaders(), {'Authorization': 'Bearer eyJhbGc...'});
      expect(c.wsQueryParams(), isEmpty);
    });
  });

  group('TwaiCredentials.resolve', () {
    test('explicit credentials win over publishableKey', () {
      final resolved = TwaiCredentials.resolve(
        credentials: ViewTokenCredentials('vt_wins'),
        publishableKey: 'pk_ignored',
      );
      expect(resolved, isA<ViewTokenCredentials>());
      expect((resolved as ViewTokenCredentials).token, 'vt_wins');
    });

    test('publishableKey alone → PublicKeyCredentials', () {
      final resolved = TwaiCredentials.resolve(publishableKey: 'pk_abc');
      expect(resolved, isA<PublicKeyCredentials>());
      expect(resolved.httpHeaders(), {
        'Authorization': 'Bearer pk_abc',
        'X-Twai-Key': 'pk_abc',
      });
    });

    test('empty publishableKey → AnonymousCredentials', () {
      final resolved = TwaiCredentials.resolve(publishableKey: '');
      expect(resolved, isA<AnonymousCredentials>());
    });

    test('neither → AnonymousCredentials', () {
      final resolved = TwaiCredentials.resolve();
      expect(resolved, isA<AnonymousCredentials>());
    });
  });

  group('TwaiClient credentials resolution', () {
    test('explicit credentials win over flat publishableKey', () {
      final c = TwaiClient(
        env: TwaiEnvironment.twaiStaging,
        publishableKey: 'pk_ignored',
        credentials: ViewTokenCredentials('vt_wins'),
      );
      expect(c.credentials, isA<ViewTokenCredentials>());
      expect(
          (c.credentials as ViewTokenCredentials).token, 'vt_wins');
      c.close();
    });

    test('flat publishableKey builds PublicKeyCredentials by default',
        () {
      final c = TwaiClient(
        env: TwaiEnvironment.twaiStaging,
        publishableKey: 'pk_abc',
      );
      expect(c.credentials, isA<PublicKeyCredentials>());
      expect(c.credentials.httpHeaders(), {
        'Authorization': 'Bearer pk_abc',
        'X-Twai-Key': 'pk_abc',
      });
      c.close();
    });

    test('no auth params → AnonymousCredentials', () {
      final c = TwaiClient(env: TwaiEnvironment.twaiStaging);
      expect(c.credentials, isA<AnonymousCredentials>());
      c.close();
    });
  });
}
