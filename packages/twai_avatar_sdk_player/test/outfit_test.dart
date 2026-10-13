import 'dart:math';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// A deterministic RNG for reproducible rotation tests.
class _SeededRandom implements Random {
  _SeededRandom(int seed) : _inner = Random(seed);
  final Random _inner;

  @override
  bool nextBool() => _inner.nextBool();
  @override
  double nextDouble() => _inner.nextDouble();
  @override
  int nextInt(int max) => _inner.nextInt(max);
}

void main() {
  group('resolveOutfit — rotation utility', () {
    test('falls back to pipelineName + idleUrl singletons when no rotation',
        () {
      const outfit = PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        pipelineName: 'JesusTalk1',
        idleUrl: 'https://cdn/idle.mp4',
      );
      final resolved = resolveOutfit(outfit);
      expect(resolved.pipelineName, 'JesusTalk1');
      expect(resolved.idleUrl, 'https://cdn/idle.mp4');
      expect(resolved.spec, outfit);
    });

    test('picks from pipelineNames rotation when non-empty', () {
      const outfit = PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        pipelineName: 'KrystalCasualTalk1', // fallback
        pipelineNames: [
          'KrystalCasualTalk1',
          'KrystalCasualTalk2',
          'KrystalCasualTalk3',
        ],
        idleUrl: 'https://cdn/idle.mp4',
      );
      final picked = <String>{};
      for (var seed = 0; seed < 30; seed++) {
        final r = resolveOutfit(outfit, rng: _SeededRandom(seed));
        picked.add(r.pipelineName);
      }
      // With 30 seeds against 3 variants, we expect all three to
      // show up at least once.
      expect(picked, {
        'KrystalCasualTalk1',
        'KrystalCasualTalk2',
        'KrystalCasualTalk3',
      });
    });

    test('picks from idleUrls rotation when non-empty', () {
      const outfit = PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        pipelineName: 'X',
        idleUrl: 'https://cdn/fallback.mp4',
        idleUrls: [
          'https://cdn/idle1.mp4',
          'https://cdn/idle2.mp4',
          'https://cdn/idle3.mp4',
        ],
      );
      final picked = <String>{};
      for (var seed = 0; seed < 30; seed++) {
        final r = resolveOutfit(outfit, rng: _SeededRandom(seed));
        picked.add(r.idleUrl);
      }
      expect(picked, {
        'https://cdn/idle1.mp4',
        'https://cdn/idle2.mp4',
        'https://cdn/idle3.mp4',
      });
    });

    test('empty rotation array falls through to singleton', () {
      const outfit = PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        pipelineName: 'Fallback',
        pipelineNames: [], // empty, must fall through
        idleUrl: 'https://cdn/idle.mp4',
        idleUrls: [],
      );
      final r = resolveOutfit(outfit);
      expect(r.pipelineName, 'Fallback');
      expect(r.idleUrl, 'https://cdn/idle.mp4');
    });

    test('toAvatar composes pipeline name + voice UUID', () {
      const outfit = PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        pipelineName: 'JesusTalk1',
        idleUrl: 'https://cdn/idle.mp4',
      );
      final r = resolveOutfit(outfit);
      final a = r.toAvatar(voiceId: 'voice-abc');
      expect(a.id, 'JesusTalk1');
      expect(a.voiceId, 'voice-abc');
    });

    test('resolve is deterministic under a seeded RNG', () {
      const outfit = PlayerOutfit(
        slug: 'casual',
        name: 'Casual',
        pipelineName: 'X',
        pipelineNames: ['A', 'B', 'C'],
        idleUrl: 'x',
        idleUrls: ['i1', 'i2', 'i3'],
      );
      final a = resolveOutfit(outfit, rng: _SeededRandom(42));
      final b = resolveOutfit(outfit, rng: _SeededRandom(42));
      expect(a.pipelineName, b.pipelineName);
      expect(a.idleUrl, b.idleUrl);
    });
  });
}
