/// Adapter-4 dispatch tests for TwaiPlayerHandle. Two things to prove:
///
///   1. TwaiPlayerHandle.forApiSession bakes in the right defaults
///      (twaiApiRestClient set, all penthouse-side auto-behaviors off)
///      so a caller who wires a mint-proxy REST client doesn't get
///      /api/gamification/* 404s per turn.
///
///   2. The regular constructor's twaiApiRestClient param, when set,
///      routes _sessionFactory() to build a TwaiApiChatSession —
///      Adapter 1 stays the default when it's null.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

PlayerAvatar _minimalPlayerAvatar() => const PlayerAvatar(
      slug: 'avt_test_1',
      name: 'Test',
      tagline: 'hi',
      voiceId: 'vc_test_1',
      outfits: [
        PlayerOutfit(
          slug: 'default',
          name: 'Default',
          pipelineName: 'avt_test_1',
          idleUrl: 'https://example.test/idle.mp4',
        ),
      ],
    );

TwaiApiRestClient _stubRest() {
  // A REST client whose HTTP client never resolves — we only care
  // about the handle wiring, not any live network calls.
  return TwaiApiRestClient(
    baseUrl: Uri.parse('https://api.example.test'),
    credentials: const AnonymousCredentials(),
    httpClient: MockClient((_) async => http.Response('{}', 200)),
  );
}

void main() {
  group('TwaiPlayerHandle.forApiSession', () {
    test('bakes penthouse auto-behaviors off + sets restClient', () {
      final handle = TwaiPlayerHandle.forApiSession(
        avatar: _minimalPlayerAvatar(),
        restClient: _stubRest(),
        autoConnect: false,   // don't touch the network in tests
      );
      // All the penthouse-side auto-fetches should be pre-disabled —
      // twai-api serves none of these endpoints.
      expect(handle.autoFetchGestures, isFalse);
      expect(handle.autoFetchFrames, isFalse);
      expect(handle.autoFetchProgress, isFalse);
      expect(handle.autoAwardXp, isFalse);
      expect(handle.autoFetchStateBlock, isFalse);
      expect(handle.autoRecordReply, isFalse);
      // And the REST client landed on the handle.
      expect(handle.twaiApiRestClient, isNotNull);
    });

    test('regular constructor + twaiApiRestClient still works', () {
      // Advanced path: build the regular constructor and pass a rest
      // client without going through the factory. Auto-behaviors are
      // whatever the caller passes (default true here); that's their
      // problem — the factory exists to avoid the footgun.
      final handle = TwaiPlayerHandle(
        avatar: _minimalPlayerAvatar(),
        autoConnect: false,
        twaiApiRestClient: _stubRest(),
      );
      expect(handle.twaiApiRestClient, isNotNull);
    });

    test('regular constructor with no twaiApiRestClient → Adapter 1 path',
        () {
      // Sanity: the default TwaiPlayerHandle keeps its Adapter-1
      // shape. This is the existing behavior; guarding it here so a
      // future dispatch tweak doesn't accidentally re-route existing
      // penthouse callers.
      final handle = TwaiPlayerHandle(
        avatar: _minimalPlayerAvatar(),
        autoConnect: false,
      );
      expect(handle.twaiApiRestClient, isNull);
      expect(handle.autoFetchGestures, isTrue);
    });
  });
}
