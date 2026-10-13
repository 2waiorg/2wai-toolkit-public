import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// Minimal ChatSession fake shared with other handle tests — kept
/// local so this file has no cross-test dependency.
class _FakeSession implements ChatSession {
  final _video = StreamController<Uint8List>.broadcast();
  final _speaking = StreamController<SpeakingEvent>.broadcast();
  final _reply = StreamController<String>.broadcast();
  final _done = Completer<ChatSessionEndReason>();
  bool _connected = false;
  bool _closed = false;

  @override
  Future<void> connect(Avatar avatar) async {
    if (_connected) throw const ChatSessionAlreadyConnectedException();
    _connected = true;
    Future.microtask(() {
      if (!_closed) _video.add(Uint8List(16));
    });
  }

  @override
  Future<void> sendMessage(String text,
      {num? gamificationLevel, Object? avatarStateBlock}) async {}

  @override
  Stream<String> get replyText => _reply.stream;
  @override
  Stream<SpeakingEvent> get speakingEvents => _speaking.stream;
  @override
  Stream<Uint8List> get videoBytes => _video.stream;
  @override
  Stream<void> get speakBoundaries => const Stream<void>.empty();
  @override
  Future<ChatSessionEndReason> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _video.close();
    await _speaking.close();
    await _reply.close();
    if (!_done.isCompleted) {
      _done.complete(const ChatSessionClosed('test'));
    }
  }
}

/// Records every request the resolver makes + returns whichever
/// response the test configured. Path → JSON body; missing paths 404.
MockClient _mockAvatarRoutes({
  Map<String, Object>? getJson,
  List<String>? capturePaths,
}) {
  return MockClient((request) async {
    if (request.method == 'GET') {
      capturePaths?.add(request.url.path);
      final body = getJson?[request.url.path];
      if (body == null) return http.Response('not found', 404);
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not implemented', 501);
  });
}

/// Full wire response the resolver ingests without any bundled
/// fallback — has outfits[0].pipelineName + outfits[0].idleUrl.
const _fullWireBody = {
  'slug': 'nova',
  'name': 'Nova',
  'tagline': 'Your cosmic guide',
  'voice': {'ttsSelection': 'tts5', 'avatarVoice': 'v-nova-uuid'},
  'outfits': [
    {
      'slug': 'default',
      'name': 'Default',
      'pipelineName': 'Gen_ab12cd_Talk1',
      'idleUrl': 'https://cdn/nova/idle.mp4',
      'posterUrl': 'https://cdn/nova/poster.jpg',
      'delivery': 'mse',
    },
  ],
};

/// Thin response the pipeline currently returns for muse-baked
/// avatars — slug/name only, no per-outfit pipelineName. Forces the
/// resolver to fall back to KnownAvatars.
const _thinWireBody = {
  'slug': 'krystal-harper',
  'name': 'Krystal Harper',
  'tagline': 'Sharp, intuitive, unapologetically herself',
  'outfits': [
    {'slug': 'casual', 'name': 'Casual'}, // no pipelineName / idle
  ],
};

void main() {
  group('TwaiPlayerHandle.fromSlug', () {
    test('resolves from full wire response — no KnownAvatars needed',
        () async {
      final paths = <String>[];
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockAvatarRoutes(
          getJson: {'/api/avatars/nova': _fullWireBody},
          capturePaths: paths,
        ),
      );
      final handle = await TwaiPlayerHandle.fromSlug(
        'nova',
        env: TwaiEnvironment.twaiStaging,
        apiClient: client,
        autoConnect: false, // don't actually start the session
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchProgress: false,
        autoFetchStateBlock: false,
        autoRecordReply: false,
        sessionFactory: _FakeSession.new,
      );

      expect(handle.avatar.slug, 'nova');
      expect(handle.avatar.name, 'Nova');
      expect(handle.avatar.voiceId, 'v-nova-uuid');
      expect(handle.avatar.outfits.first.pipelineName, 'Gen_ab12cd_Talk1');
      // Only the catalog fetch — no fallback needed.
      expect(paths, contains('/api/avatars/nova'));

      await handle.dispose();
    });

    test('falls back to KnownAvatars when wire response is thin',
        () async {
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockAvatarRoutes(getJson: {
          '/api/avatars/krystal-harper': _thinWireBody,
        }),
      );
      final handle = await TwaiPlayerHandle.fromSlug(
        'krystal-harper',
        env: TwaiEnvironment.twaiStaging,
        apiClient: client,
        autoConnect: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchProgress: false,
        autoFetchStateBlock: false,
        autoRecordReply: false,
        sessionFactory: _FakeSession.new,
      );
      // Bundled catalog wins — Krystal's real muse pipelineName.
      expect(handle.avatar.outfits.first.pipelineName,
          'KrystalHarperMuseTalk3');
      expect(handle.avatar.outfits, hasLength(3),
          reason: 'KnownAvatars ships Casual + Date + Swim');

      await handle.dispose();
    });

    test('falls back to KnownAvatars when wire 404s', () async {
      // Empty mock → every GET is 404.
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockAvatarRoutes(),
      );
      final handle = await TwaiPlayerHandle.fromSlug(
        'krystal-harper',
        env: TwaiEnvironment.twaiStaging,
        apiClient: client,
        autoConnect: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchProgress: false,
        autoFetchStateBlock: false,
        autoRecordReply: false,
        sessionFactory: _FakeSession.new,
      );
      expect(handle.avatar.slug, 'krystal-harper');
      expect(handle.avatar.outfits.first.pipelineName,
          'KrystalHarperMuseTalk3');

      await handle.dispose();
    });

    test('throws StateError with helpful message when both empty',
        () async {
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://staging.example.com'),
        httpClient: _mockAvatarRoutes(),
      );
      await expectLater(
        TwaiPlayerHandle.fromSlug(
          'never-heard-of-this-one',
          env: TwaiEnvironment.twaiStaging,
          apiClient: client,
          autoConnect: false,
          sessionFactory: _FakeSession.new,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('never-heard-of-this-one'),
            contains('KnownAvatars'),
            contains('backend'),
          ),
        )),
      );
    });

    test('owner/name slug dispatches to /api/gen/catalog/...', () async {
      final paths = <String>[];
      final client = TwaiApiClient(
        baseUrl: Uri.parse('https://gen.example.com'),
        httpClient: _mockAvatarRoutes(
          getJson: {'/api/gen/catalog/alice/nova': _fullWireBody},
          capturePaths: paths,
        ),
      );
      final handle = await TwaiPlayerHandle.fromSlug(
        'alice/nova',
        env: TwaiEnvironment.twaiStaging,
        apiClient: client,
        autoConnect: false,
        autoFetchGestures: false,
        autoFetchFrames: false,
        autoFetchProgress: false,
        autoFetchStateBlock: false,
        autoRecordReply: false,
        sessionFactory: _FakeSession.new,
      );
      expect(paths, contains('/api/gen/catalog/alice/nova'));
      expect(paths, isNot(contains('/api/avatars/alice/nova')),
          reason: 'gen-catalog route should be preferred for owner/name slugs');
      expect(handle.avatar.outfits.first.pipelineName, 'Gen_ab12cd_Talk1');

      await handle.dispose();
    });
  });

  group('AvatarCatalogResponse', () {
    test('toPlayerAvatar returns null when outfits empty', () {
      final r = AvatarCatalogResponse.fromJson({
        'slug': 'x',
        'name': 'X',
        'outfits': [],
      });
      expect(r.toPlayerAvatar(), isNull);
    });

    test('toPlayerAvatar returns null when first outfit has no pipelineName',
        () {
      final r = AvatarCatalogResponse.fromJson({
        'slug': 'x',
        'outfits': [
          {'slug': 'default', 'idleUrl': 'https://cdn/x.mp4'},
        ],
      });
      expect(r.toPlayerAvatar(), isNull);
    });

    test('AvatarDelivery.fromString handles known + unknown', () {
      expect(AvatarDelivery.fromString('mse'), AvatarDelivery.mse);
      expect(AvatarDelivery.fromString('wav2lip'), AvatarDelivery.wav2lip);
      expect(AvatarDelivery.fromString('v13'), isNull);
      expect(AvatarDelivery.fromString(null), isNull);
      expect(AvatarDelivery.mse.pathPrefix, '/ext-api-muse');
      expect(AvatarDelivery.wav2lip.pathPrefix, '/ext-api');
    });
  });

  group('KnownAvatars', () {
    test('lookup finds krystal-harper with 3 outfits', () {
      final k = KnownAvatars.lookup('krystal-harper');
      expect(k, isNotNull);
      expect(k!.outfits, hasLength(3));
      expect(k.outfits.map((o) => o.slug), ['casual', 'date', 'swim']);
      expect(k.outfits.first.pipelineName, 'KrystalHarperMuseTalk3');
    });

    test('lookup returns null for unknown slug', () {
      expect(KnownAvatars.lookup('does-not-exist'), isNull);
    });

    test('allSlugs matches what lookup can find', () {
      for (final slug in KnownAvatars.allSlugs) {
        expect(KnownAvatars.lookup(slug), isNotNull,
            reason: 'allSlugs advertises "$slug" but lookup returned null');
      }
    });

    test('Krystal ships 3 outfits × 3 pipelineNames × 3 idleUrls with '
        'IdleDefault anchor (Penthouse muse-bake convention)', () {
      // Krystal's shape is the fullest — three outfits, each a full
      // 3+3 rotation with a defaultIdleUrl anchor per Mason's bake
      // pipeline doc §3.3. Matches MUSE_DEFAULT_PIPELINES at
      // LeanChatPage.tsx:152-157.
      final k = KnownAvatars.lookup('krystal-harper')!;
      expect(k.outfits, hasLength(3));
      for (final o in k.outfits) {
        expect(o.pipelineNames, hasLength(3),
            reason: '${o.slug}: expected 3 talk substrates');
        expect(o.idleUrls, hasLength(3),
            reason: '${o.slug}: expected 3 idle takes');
        expect(o.defaultIdleUrl, isNotNull,
            reason: '${o.slug}: defaultIdleUrl anchor missing');
        expect(o.defaultIdleUrl, contains('IdleDefault'),
            reason: '${o.slug}: defaultIdleUrl not the IdleDefault take');
      }
    });

    test('every bundled avatar keeps pipelineName singleton in sync with '
        'pipelineNames[0]', () {
      // Invariant across the whole catalog: when an outfit ships a
      // rotation list, the singleton fallback must be its first
      // entry — a resolver that ignores the rotation list has to
      // land on the canonical base name, not a random suffix.
      for (final slug in KnownAvatars.allSlugs) {
        final a = KnownAvatars.lookup(slug)!;
        for (final o in a.outfits) {
          final names = o.pipelineNames;
          if (names != null && names.isNotEmpty) {
            expect(o.pipelineName, names.first,
                reason: '$slug/${o.slug}: pipelineName != pipelineNames[0]');
          }
          final idles = o.idleUrls;
          if (idles != null && idles.isNotEmpty) {
            expect(idles, contains(o.idleUrl),
                reason:
                    '$slug/${o.slug}: singleton idleUrl not in idleUrls list');
          }
        }
      }
    });

    test('2wai roster covers Jesus / Kenan / Calum / Rob with muse-served '
        'TalkN pipelineNames (matches avatar-player/src/avatars.ts)', () {
      // Wav2lip is retired (2026-07-20); these TalkN names now resolve
      // on the muse stack. Rotation counts follow the source-of-truth
      // catalog at 2waiorg/avatar-player:src/avatars.ts.
      final expected = {
        'jesus': (pipelineName: 'RedJesusTalk1', rotation: 4),
        'KenanAutoTrader': (pipelineName: 'RedKenanTalk1', rotation: 3),
        'calum-worthy': (pipelineName: 'CalumTalk1', rotation: 1),
        'RobRiggle': (pipelineName: 'RobRiggleTalk1', rotation: 3),
      };
      for (final entry in expected.entries) {
        final a = KnownAvatars.lookup(entry.key);
        expect(a, isNotNull,
            reason: '2wai roster slug "${entry.key}" missing from KnownAvatars');
        expect(a!.outfits.first.pipelineName, entry.value.pipelineName,
            reason: '${entry.key}: pipelineName mismatch vs avatar-player source');
        // rotation == 1 means the outfit ships singleton only, no
        // pipelineNames list — the reference frontend does the same
        // for Calum. rotation > 1 means the list must be present.
        if (entry.value.rotation == 1) {
          expect(a.outfits.first.pipelineNames, anyOf(isNull, hasLength(1)),
              reason: '${entry.key}: expected singleton (no rotation)');
        } else {
          expect(a.outfits.first.pipelineNames, hasLength(entry.value.rotation),
              reason:
                  '${entry.key}: expected ${entry.value.rotation}-substrate rotation');
        }
      }
    });

    test('Maradona is intentionally excluded (bake broken as of 2026-07-20)',
        () {
      expect(KnownAvatars.lookup('maradona'), isNull,
          reason: 'Maradona should not ship until Mason redoes the bake');
      expect(KnownAvatars.allSlugs, isNot(contains('maradona')));
    });

    test('resolveOutfit picks one variant per call from the rotation lists',
        () {
      final k = KnownAvatars.lookup('krystal-harper')!;
      final casual = k.outfits.first;
      final rng = Random(42);
      final resolved = resolveOutfit(casual, rng: rng);
      expect(casual.pipelineNames, contains(resolved.pipelineName));
      expect(casual.idleUrls, contains(resolved.idleUrl));
    });
  });
}
