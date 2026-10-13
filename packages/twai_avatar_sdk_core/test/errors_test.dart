import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

void main() {
  group('TwaiCodecError', () {
    test('kind is codec + toString includes message + cause', () {
      final err = TwaiCodecError('codec unsupported', 'inner');
      expect(err.kind, TwaiErrorKind.codec);
      expect(err.message, 'codec unsupported');
      expect(err.cause, 'inner');
      expect(err.toString(), contains('codec unsupported'));
      expect(err.toString(), contains('inner'));
    });

    test('is catchable as TwaiError', () {
      Object err;
      try {
        throw const TwaiCodecError('x');
      } catch (e) {
        err = e;
      }
      expect(err, isA<TwaiError>());
      expect((err as TwaiError).kind, TwaiErrorKind.codec);
    });
  });

  group('TwaiHandshakeError', () {
    test('captures close code in toString', () {
      const err = TwaiHandshakeError('bad handshake', closeCode: 1002);
      expect(err.kind, TwaiErrorKind.handshake);
      expect(err.closeCode, 1002);
      expect(err.toString(), contains('close=1002'));
    });

    test('null close code omits it from toString', () {
      const err = TwaiHandshakeError('timed out');
      expect(err.closeCode, isNull);
      expect(err.toString(), isNot(contains('close=')));
    });
  });

  group('TwaiTransportError', () {
    test('kind is transport', () {
      const err = TwaiTransportError('appendBuffer failed');
      expect(err.kind, TwaiErrorKind.transport);
    });
  });

  group('ChatSessionException implements TwaiError', () {
    test('ChatSessionConnectException.kind == connect', () {
      const err = ChatSessionConnectException('WS closed');
      expect(err, isA<TwaiError>());
      expect(err.kind, TwaiErrorKind.connect);
    });

    test('ChatSessionSendException.kind == chat', () {
      const err = ChatSessionSendException('500 server error');
      expect(err.kind, TwaiErrorKind.chat);
    });

    test('ChatSessionUnauthorizedException.kind == unauthorized', () {
      const err = ChatSessionUnauthorizedException();
      expect(err.kind, TwaiErrorKind.unauthorized);
    });

    test('ChatSessionForbiddenException.kind == unauthorized', () {
      // Forbidden shares kind with Unauthorized — both auth failures
      // that a retry with the same credential won't fix.
      const err = ChatSessionForbiddenException();
      expect(err.kind, TwaiErrorKind.unauthorized);
    });

    test('ChatSessionRateLimitedException.kind == chat', () {
      // Rate-limit is a backend rejection at chat layer, not auth.
      const err = ChatSessionRateLimitedException();
      expect(err.kind, TwaiErrorKind.chat);
    });

    test('ChatSessionNotConnectedException.kind == unknown', () {
      // Caller misuse; not a wire fault.
      const err = ChatSessionNotConnectedException();
      expect(err.kind, TwaiErrorKind.unknown);
    });
  });

  group('switch-on-kind pattern', () {
    test('handles all TwaiErrorKind values in one dispatch', () {
      // Simulates the cross-language pattern: catch base TwaiError,
      // switch on kind for a single error handler.
      String describe(TwaiError e) {
        switch (e.kind) {
          case TwaiErrorKind.codec:
            return 'browser cannot decode';
          case TwaiErrorKind.connect:
            return 'transport failed to open';
          case TwaiErrorKind.handshake:
            return 'handshake rejected';
          case TwaiErrorKind.transport:
            return 'mid-stream failure';
          case TwaiErrorKind.chat:
            return 'chat send rejected';
          case TwaiErrorKind.unauthorized:
            return 'rotate credentials';
          case TwaiErrorKind.unknown:
            return 'inspect further';
        }
      }

      expect(describe(const TwaiCodecError('x')), 'browser cannot decode');
      expect(describe(const TwaiHandshakeError('x')), 'handshake rejected');
      expect(describe(const TwaiTransportError('x')), 'mid-stream failure');
      expect(describe(const ChatSessionConnectException('x')),
          'transport failed to open');
      expect(describe(const ChatSessionUnauthorizedException()),
          'rotate credentials');
      expect(describe(const ChatSessionRateLimitedException()),
          'chat send rejected');
    });
  });
}
