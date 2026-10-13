/// Tests for `PlayerAvatar.fromGenCatalog` — the SDK-side parser for
/// gen-2wai's `GET /api/gen/catalog/{owner}/{avatarname}` response.
///
/// The wire shape is defined by `c:\Dev\gen-2wai\app\api\catalog.py:55`
/// (`_hydrate`) and `app\domain\studio_state.py:395` (media manifest).
/// Fixtures below mirror actual gen-2wai output.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

// Full happy-path shape — matches _hydrate() with a live media block.
const _fullCatalogJson = '''
{
  "slug": "mason/mila",
  "name": "Mila",
  "tagline": "The reference avatar for the twai-api walkthrough.",
  "lipsync_engine": "musetalk",
  "voice": {
    "ttsSelection": "tts5",
    "avatarVoice": "vc_1763fe2cc73ee2cd45dba587"
  },
  "outfits": [
    {
      "slug": "default",
      "name": "Default",
      "pipelineName": "Gen_abcdef123456_Talk1",
      "idleUrl": "https://blob.example/gen/rid1/o1/c1/idle.mp4?sas=xxx",
      "posterUrl": "https://blob.example/gen/rid1/o1/c1/poster.jpg?sas=yyy",
      "delivery": "mse"
    }
  ],
  "actions": [],
  "gestures": [],
  "media": {
    "idle_urls": [
      "https://blob.example/gen/rid1/o1/c1/idle.mp4?sas=x1",
      "https://blob.example/gen/rid1/o1/c2/idle.mp4?sas=x2"
    ],
    "talking_variants": [
      "Gen_abcdef123456_Talk1",
      "Gen_abcdef123456_Talk2",
      "Gen_abcdef123456_Talk3"
    ],
    "emotes": [
      {"id": 42, "url": "https://blob.example/gen/rid1/o1/c9/emote.mp4?sas=e1"},
      {"id": 43, "url": "https://blob.example/gen/rid1/o1/c10/emote.mp4?sas=e2"}
    ],
    "frames": [
      "https://blob.example/gen/rid1/o1/c20/frame.jpg?sas=f1"
    ]
  }
}
''';

// Minimal shape — no media block (avatar has no persona / older bake).
const _minimalCatalogJson = '''
{
  "slug": "mason/basic",
  "name": "Basic",
  "tagline": "",
  "lipsync_engine": "wav2lip",
  "voice": {"ttsSelection": "tts5", "avatarVoice": "vc_basic"},
  "outfits": [
    {
      "slug": "default",
      "name": "Default",
      "pipelineName": "Gen_basic_Talk1",
      "idleUrl": "https://example.test/idle.mp4",
      "posterUrl": "",
      "delivery": "mse"
    }
  ],
  "actions": [],
  "gestures": []
}
''';

void main() {
  group('PlayerAvatar.fromGenCatalog', () {
    test('full catalog → hydrated avatar + folded media', () {
      final json = jsonDecode(_fullCatalogJson) as Map<String, dynamic>;
      final avatar = PlayerAvatar.fromGenCatalog(json);

      expect(avatar.slug, 'mason/mila');
      expect(avatar.name, 'Mila');
      expect(avatar.tagline, contains('walkthrough'));
      expect(avatar.voiceId, 'vc_1763fe2cc73ee2cd45dba587');
      expect(avatar.ttsSelection, 'tts5');
      expect(avatar.lipsyncEngine, 'musetalk');
      expect(avatar.outfits, hasLength(1));

      final o = avatar.outfits.first;
      expect(o.slug, 'default');
      expect(o.name, 'Default');
      expect(o.pipelineName, 'Gen_abcdef123456_Talk1');
      expect(o.idleUrl, contains('idle.mp4'));
      expect(o.posterUrl, contains('poster.jpg'));

      // media block folded into default outfit
      expect(o.pipelineNames, hasLength(3));
      expect(o.pipelineNames!.first, 'Gen_abcdef123456_Talk1');
      expect(o.idleUrls, hasLength(2));
      expect(o.emotes, hasLength(2));
      expect(o.emotes!.first.id, '42');
      expect(o.emotes!.first.url, contains('emote.mp4'));
      expect(o.frameUrls, hasLength(1));
      expect(o.frameUrls!.first, contains('frame.jpg'));

      // rotation resolution should pick from the pipelineNames set
      // (not just fall back to the pipelineName scalar).
      final resolved = resolveOutfit(o);
      expect(o.pipelineNames!.contains(resolved.pipelineName), isTrue);
    });

    test('minimal catalog (no media block) → outfit with only scalars', () {
      final json = jsonDecode(_minimalCatalogJson) as Map<String, dynamic>;
      final avatar = PlayerAvatar.fromGenCatalog(json);

      expect(avatar.lipsyncEngine, 'wav2lip');
      expect(avatar.outfits, hasLength(1));

      final o = avatar.outfits.first;
      expect(o.pipelineName, 'Gen_basic_Talk1');
      expect(o.idleUrl, 'https://example.test/idle.mp4');
      // No media block → rotation sets stay null, emotes/frames stay null.
      expect(o.pipelineNames, isNull);
      expect(o.idleUrls, isNull);
      expect(o.emotes, isNull);
      expect(o.frameUrls, isNull);

      // Rotation falls back to the scalar pipelineName / idleUrl.
      final resolved = resolveOutfit(o);
      expect(resolved.pipelineName, 'Gen_basic_Talk1');
      expect(resolved.idleUrl, 'https://example.test/idle.mp4');
    });

    test('empty outfits array throws FormatException', () {
      expect(
        () => PlayerAvatar.fromGenCatalog({
          'slug': 'x/y',
          'name': 'x',
          'tagline': '',
          'voice': {'ttsSelection': 'tts5', 'avatarVoice': ''},
          'outfits': [],
        }),
        throwsFormatException,
      );
    });

    test('lipsync_engine omitted → null (SDK downstream can default)', () {
      final avatar = PlayerAvatar.fromGenCatalog({
        'slug': 'x/y',
        'name': 'x',
        'tagline': '',
        'voice': {'ttsSelection': 'tts5', 'avatarVoice': 'v'},
        'outfits': [
          {
            'slug': 'default',
            'name': 'Default',
            'pipelineName': 'p',
            'idleUrl': 'https://x/y.mp4',
          },
        ],
      });
      expect(avatar.lipsyncEngine, isNull);
    });

    test('empty media arrays → fields stay null (not empty)', () {
      // Guards against `pipelineNames == []` accidentally falling
      // through to a "pick from empty list" bug in resolveOutfit.
      final avatar = PlayerAvatar.fromGenCatalog({
        'slug': 'x/y',
        'name': 'x',
        'tagline': '',
        'voice': {'ttsSelection': 'tts5', 'avatarVoice': 'v'},
        'outfits': [
          {
            'slug': 'default',
            'name': 'Default',
            'pipelineName': 'p',
            'idleUrl': 'https://x/y.mp4',
          }
        ],
        'media': {
          'idle_urls': [],
          'talking_variants': [],
          'emotes': [],
          'frames': [],
        },
      });
      final o = avatar.outfits.first;
      expect(o.pipelineNames, isNull);
      expect(o.idleUrls, isNull);
      expect(o.emotes, isNull);
      expect(o.frameUrls, isNull);
    });
  });

  group('PlayerEmote.fromJson', () {
    test('coerces integer id to string', () {
      final e = PlayerEmote.fromJson({'id': 42, 'url': 'https://x/e.mp4'});
      expect(e.id, '42');
      expect(e.url, 'https://x/e.mp4');
    });

    test('accepts string id as-is', () {
      final e = PlayerEmote.fromJson({'id': 'emote_x', 'url': 'https://x'});
      expect(e.id, 'emote_x');
    });

    test('missing url → empty string (does not throw)', () {
      final e = PlayerEmote.fromJson({'id': 1});
      expect(e.url, '');
    });
  });
}
