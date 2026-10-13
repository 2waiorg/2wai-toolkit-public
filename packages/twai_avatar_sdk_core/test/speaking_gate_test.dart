/// Unit tests for [SpeakingGate] plus a conformance harness that runs
/// the shared JSON vectors from twai-web-sdk (mirrored under
/// `test/conformance/`). If a scenario passes in TS and fails here (or
/// vice versa), one of the SDKs has drifted from the spec.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

void main() {
  group('SpeakingGate (stateful)', () {
    test('holds an event until playhead reaches pts, then fires', () {
      final fires = <SpeakingState>[];
      final gate = SpeakingGate(onFire: fires.add);
      gate.enqueue(value: SpeakingState.start, pts: 2.34);

      gate.tick(1.0);
      expect(fires, isEmpty);
      gate.tick(2.0);
      expect(fires, isEmpty);
      gate.tick(2.34);
      expect(fires, [SpeakingState.start]);
      gate.tick(3.0);
      expect(fires, [SpeakingState.start], reason: 'no double-fire');
    });

    test('drains queued events in order on a single tick', () {
      final fires = <SpeakingState>[];
      final gate = SpeakingGate(onFire: fires.add);
      gate.enqueue(value: SpeakingState.start, pts: 2.0);
      gate.enqueue(value: SpeakingState.stop, pts: 3.0);

      gate.tick(5.0); // playhead past both
      expect(fires, [SpeakingState.start, SpeakingState.stop]);
    });

    test('null pts (legacy) fires on the next tick regardless of time', () {
      final fires = <SpeakingState>[];
      final gate = SpeakingGate(onFire: fires.add);
      gate.enqueue(value: SpeakingState.start); // pts omitted

      gate.tick(0.4);
      expect(fires, [SpeakingState.start]);
    });

    test('onFire throw does not wedge the gate', () {
      final fires = <SpeakingState>[];
      var throwOnce = true;
      final gate = SpeakingGate(onFire: (v) {
        if (throwOnce) {
          throwOnce = false;
          throw StateError('boom');
        }
        fires.add(v);
      });
      gate.enqueue(value: SpeakingState.start, pts: 0.0);
      gate.enqueue(value: SpeakingState.stop, pts: 1.0);
      gate.tick(2.0);
      // First threw & was swallowed; second still fires.
      expect(fires, [SpeakingState.stop]);
    });

    test('reset clears pending', () {
      final fires = <SpeakingState>[];
      final gate = SpeakingGate(onFire: fires.add);
      gate.enqueue(value: SpeakingState.start, pts: 5.0);
      expect(gate.pending, 1);
      gate.reset();
      expect(gate.pending, 0);
      gate.tick(10.0);
      expect(fires, isEmpty);
    });

    test('enqueueEvent takes a parsed SpeakingEvent', () {
      final fires = <SpeakingState>[];
      final gate = SpeakingGate(onFire: fires.add);
      const ev = SpeakingEvent(value: SpeakingState.start, pts: 1.5);
      gate.enqueueEvent(ev);
      gate.tick(1.5);
      expect(fires, [SpeakingState.start]);
    });
  });

  group('gateSpeaking (pure reference) — conformance vectors', () {
    final vectorFile = File(
      'test/conformance/speaking-timeline.json',
    );
    final spec =
        jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;
    final scenarios = spec['scenarios'] as List;

    for (final s in scenarios) {
      final scenario = s as Map<String, dynamic>;
      final name = scenario['name'] as String;
      test('scenario: $name', () {
        final events = (scenario['events'] as List)
            .cast<Map<String, dynamic>>()
            .map((e) => <String, Object?>{
                  if (e.containsKey('seq')) 'seq': e['seq'],
                  'value': e['value'],
                  if (e.containsKey('pts')) 'pts': e['pts'],
                })
            .toList();
        final playback = (scenario['playback'] as List)
            .map((n) => (n as num).toDouble())
            .toList();

        final actualFires = gateSpeaking(events, playback);

        final expected = (scenario['expectedFires'] as List)
            .cast<Map<String, dynamic>>()
            .map((e) => {
                  'value': e['value'] as Object,
                  'firedAtCurrentTime':
                      (e['firedAtCurrentTime'] as num).toDouble(),
                })
            .toList();

        expect(actualFires, equals(expected));
      });
    }
  });
}
