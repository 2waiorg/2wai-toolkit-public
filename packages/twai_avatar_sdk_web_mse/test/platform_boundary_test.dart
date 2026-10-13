// Non-web test — proves that constructing `WebMseStreamSink` on a
// non-web platform throws with a helpful message. Guards against a
// silent stub taking over the real impl.
//
// Web tests (real MediaSource integration) land in Phase 1b+ and
// require a browser runner (`flutter test --platform chrome`).

import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';
import 'package:twai_avatar_sdk_web_mse/twai_avatar_sdk_web_mse.dart';

void main() {
  group('WebMseStreamSink platform boundary', () {
    test('constructing on non-web throws UnsupportedError', () {
      // The sessionFactory is a no-op here: the sink constructor
      // fails inside the platform impl before the factory is ever
      // invoked, so we don't need a real ChatSession.
      final controller = TwaiAvatarPlayerController(
        sessionFactory: () => throw StateError('unreachable'),
      );
      addTearDown(controller.dispose);

      expect(
        () => WebMseStreamSink(controller: controller),
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('Flutter web only'),
        )),
      );
    });
  });
}
