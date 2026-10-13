import 'package:test/test.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

void main() {
  const shared = PlayerGesture(
    id: 'g1',
    slug: 'wave',
    displayName: 'Wave',
    videoUrl: 'https://cdn/wave.mp4',
    isUnlocked: true,
  );
  const casualLocked = PlayerGesture(
    id: 'g2',
    slug: 'kiss',
    displayName: 'Blows Kiss',
    videoUrl: 'https://cdn/kiss.casual.mp4',
    isUnlocked: false,
    unlockLevel: 5,
    outfitSlug: 'casual',
  );
  const casualUnlocked = PlayerGesture(
    id: 'g3',
    slug: 'heart-hands',
    displayName: 'Heart Hands',
    videoUrl: 'https://cdn/heart.casual.mp4',
    isUnlocked: true,
    outfitSlug: 'casual',
  );
  const dateUnlocked = PlayerGesture(
    id: 'g4',
    slug: 'cheer',
    displayName: 'Cheer',
    videoUrl: 'https://cdn/cheer.date.mp4',
    isUnlocked: true,
    outfitSlug: 'date',
  );

  const casualBeach = PlayerFrame(
    id: 'f1',
    slug: 'beach-walk',
    frameNumber: 0,
    outfitSlug: 'casual',
    unlockLevel: 1,
    mainClipUrl: 'https://cdn/beach.casual.mp4',
    isUnlocked: true,
  );
  const casualCoffeeLocked = PlayerFrame(
    id: 'f2',
    slug: 'coffee',
    frameNumber: 1,
    outfitSlug: 'casual',
    unlockLevel: 10,
    mainClipUrl: 'https://cdn/coffee.casual.mp4',
    isUnlocked: false,
  );
  const dateDinner = PlayerFrame(
    id: 'f3',
    slug: 'dinner',
    frameNumber: 0,
    outfitSlug: 'date',
    unlockLevel: 5,
    mainClipUrl: 'https://cdn/dinner.date.mp4',
    isUnlocked: true,
  );

  group('filterGestures', () {
    test('null outfitSlug matches only shared (outfit-neutral) gestures', () {
      final result = filterGestures(
        const [shared, casualLocked, casualUnlocked, dateUnlocked],
        outfitSlug: null,
      );
      expect(result.map((g) => g.slug), ['wave']);
    });

    test('outfit slug matches shared + own-outfit gestures', () {
      final result = filterGestures(
        const [shared, casualLocked, casualUnlocked, dateUnlocked],
        outfitSlug: 'casual',
      );
      expect(result.map((g) => g.slug), ['wave', 'kiss', 'heart-hands']);
    });

    test('unlockedOnly drops locked entries', () {
      final result = filterGestures(
        const [shared, casualLocked, casualUnlocked, dateUnlocked],
        outfitSlug: 'casual',
        unlockedOnly: true,
      );
      expect(result.map((g) => g.slug), ['wave', 'heart-hands']);
    });

    test('mismatched outfit + no shared → empty', () {
      final result = filterGestures(
        const [casualLocked, casualUnlocked],
        outfitSlug: 'swim',
      );
      expect(result, isEmpty);
    });
  });

  group('filterFrames', () {
    test('filters by outfitSlug (frames are outfit-scoped)', () {
      final result = filterFrames(
        const [casualBeach, casualCoffeeLocked, dateDinner],
        outfitSlug: 'casual',
      );
      expect(result.map((f) => f.slug), ['beach-walk', 'coffee']);
    });

    test('unlockedOnly drops locked frames', () {
      final result = filterFrames(
        const [casualBeach, casualCoffeeLocked, dateDinner],
        outfitSlug: 'casual',
        unlockedOnly: true,
      );
      expect(result.map((f) => f.slug), ['beach-walk']);
    });

    test('no frames for outfit → empty', () {
      final result = filterFrames(
        const [casualBeach, casualCoffeeLocked],
        outfitSlug: 'swim',
      );
      expect(result, isEmpty);
    });
  });
}
