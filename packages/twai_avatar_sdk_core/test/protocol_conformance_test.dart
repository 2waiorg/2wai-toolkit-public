/// Dart port of twai-protocol's `conformance/harness/conformance.mjs`.
/// The P5 hand-off Mason assigned to me on 2026-07-27 — the
/// non-bypassable CI gate that proves this SDK is conformant to
/// twai-protocol v1.1.0.
///
/// Replays all three golden vectors from
/// `c:\Dev\twai-protocol\conformance\vectors\` (mirrored under
/// `test/conformance/`) against the SDK's own exports:
///
///   codec.json             → kMseCodecs + kAvccProfileCompatByte
///   handshake-cases.json   → classifyHandshake()
///   speaking-timeline.json → gateSpeaking()
///
/// A wire change that isn't reflected in the SDK fails here, loudly —
/// which is the whole point of the cross-language conformance gate
/// (see `spec/PROTOCOL.md:158` upstream).
///
/// Runs via standard `dart test`. Should also be a required CI job on
/// this repo per the P0-P4 implementation report at
/// `wiki/reports/architecture/2026-07-07-avatar-sdk-p0-p4-implementation.html`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

// Vector files live next to this test — keeps `dart test` hermetic
// (no filesystem walk out of the package, no network).
const String _vecDir = 'test/conformance';

Map<String, dynamic> _readJson(String name) => jsonDecode(
      File('$_vecDir/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  group('twai-protocol conformance — codec', () {
    final golden = _readJson('codec.json');

    test('kMseCodecs matches golden mseCodecs', () {
      expect(kMseCodecs, equals(golden['mseCodecs']));
    });

    test('kAvccProfileCompatByte matches golden byte (0xC0)', () {
      expect(kAvccProfileCompatByte, equals(golden['avccProfileCompatByte']));
    });
  });

  group('twai-protocol conformance — handshake-cases', () {
    final cases = (_readJson('handshake-cases.json')['cases'] as List)
        .cast<Map<String, dynamic>>();

    for (final c in cases) {
      final name = c['name'] as String;
      test('handshake:$name', () {
        final got = classifyHandshake(
          input: (c['input'] as Map?)?.cast<String, dynamic>(),
          raw: c['raw'] as String?,
          timedOut: c['timedOut'] as bool? ?? false,
        );
        final want = c['expect'] as Map<String, dynamic>;
        // Vector spec: only compare fields present in `want` (some
        // cases only assert `accept`, not the closeCode).
        expect(got.accept, equals(want['accept']),
            reason: 'accept mismatch for $name');
        if (want.containsKey('closeCode')) {
          expect(got.closeCode, equals(want['closeCode']),
              reason: 'closeCode mismatch for $name');
        }
      });
    }
  });

  group('twai-protocol conformance — speaking-timeline (pts-gate)', () {
    final scenarios = (_readJson('speaking-timeline.json')['scenarios'] as List)
        .cast<Map<String, dynamic>>();

    for (final s in scenarios) {
      final name = s['name'] as String;
      test('speaking:$name', () {
        final events = (s['events'] as List).cast<Map<String, dynamic>>().map(
              (e) => <String, Object?>{
                if (e.containsKey('seq')) 'seq': e['seq'],
                'value': e['value'],
                if (e.containsKey('pts')) 'pts': e['pts'],
              },
            ).toList();
        final playback =
            (s['playback'] as List).map((n) => (n as num).toDouble()).toList();

        final got = gateSpeaking(events, playback);
        final want = (s['expectedFires'] as List)
            .cast<Map<String, dynamic>>()
            .map((e) => {
                  'value': e['value'] as Object,
                  'firedAtCurrentTime':
                      (e['firedAtCurrentTime'] as num).toDouble(),
                })
            .toList();

        expect(got, equals(want),
            reason: 'gateSpeaking output mismatch for $name');
      });
    }
  });
}
