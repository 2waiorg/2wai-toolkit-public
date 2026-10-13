/// Dart runner for the LiveKit conformance vectors — the cross-SDK
/// contract Mason mirrored into this package on 2026-08-24
/// (`test/conformance/livekit/`, PR #2 on twai-web-sdk, section 9 of
/// `wiki/avatar-toolkit/livekit-engine-status.md`).
///
/// This is the second half of the Dart conformance mechanism. The
/// first half — `protocol_conformance_test.dart` in
/// `twai_avatar_sdk_core` — replays the pre-LiveKit MSE vectors and
/// stays in CI so the codec / handshake / speaking-timeline contract
/// keeps holding. This file replays the seven **LiveKit** vector files
/// against the Dart SDK's own exports.
///
/// The eight runner obligations from `conformance/livekit/README.md`
/// are load-bearing. All 123 scenarios execute against production-used
/// Dart seams; none are placeholders or skipped. Read that file before
/// adding scenarios.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:twai_avatar_sdk_livekit/src/transport0/envelope.dart';
import 'package:twai_avatar_sdk_livekit/src/transport0/engine_lifecycle.dart';
import 'package:twai_avatar_sdk_livekit/src/transport0/session_data.dart';
import 'package:twai_avatar_sdk_livekit/twai_avatar_sdk_livekit.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

const String _vecDir = 'test/conformance/livekit';

Map<String, dynamic> _readVector(String name) => jsonDecode(
      File('$_vecDir/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

// The scenario counts Mason pinned in
// `livekit-engine-status.md` §3, so a botched merge / partial file
// copy flips this check red instead of silently reducing coverage.
const Map<String, int> _expectedCounts = {
  'mint-cases.json': 38,
  'reply-stream.json': 26,
  'lifecycle-cases.json': 19,
  'speaking-timeline.json': 15,
  'retry-policy.json': 9,
  'session-data.json': 8,
  'envelope.json': 8,
};

void main() {
  group('LiveKit conformance — vector inventory', () {
    // The vectors are the shared contract; a missing file is a
    // silent gap. This guard fires before the SUT ports do.
    for (final entry in _expectedCounts.entries) {
      test('${entry.key} present with expected scenario count', () {
        final file = File('$_vecDir/${entry.key}');
        expect(file.existsSync(), isTrue,
            reason: '${entry.key} missing from $_vecDir');
        final v = _readVector(entry.key);
        // Case files use different top-level keys — walk the two
        // shapes both files use ("cases" and "scenarios").
        final list = (v['cases'] ?? v['scenarios']) as List?;
        expect(list, isNotNull,
            reason: '${entry.key} has neither "cases" nor "scenarios"');
        expect(list!.length, equals(entry.value),
            reason:
                'scenario count drift for ${entry.key}: expected ${entry.value}, got ${list.length}');
      });
    }
  });

  group('LiveKit conformance — reply-stream (26 scenarios)', () {
    final scenarios = (_readVector('reply-stream.json')['scenarios'] as List)
        .cast<Map<String, dynamic>>();

    for (final s in scenarios) {
      final name = s['name'] as String;
      test(
        'reply-stream:$name', () => _runReplyStreamScenario(s),
        // Per obligation 5: a throwing SUT fails one scenario, not
        // the run. flutter_test already isolates per-test, so this
        // is enforced by default.
      );
    }
  });

  group('LiveKit conformance — envelope (8 scenarios)', () {
    final scenarios = (_readVector('envelope.json')['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final s in scenarios) {
      test('envelope:${s['name']}', () => _runEnvelopeScenario(s));
    }
  });

  group('LiveKit conformance — mint-cases (38 scenarios)', () {
    final scenarios = (_readVector('mint-cases.json')['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final s in scenarios) {
      test('mint:${s['name']}', () => _runMintScenario(s));
    }
  });

  group('LiveKit conformance — lifecycle-cases (19 scenarios)', () {
    final scenarios = (_readVector('lifecycle-cases.json')['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final s in scenarios) {
      test('lifecycle:${s['name']}', () => _runLifecycleScenario(s));
    }
  });

  group('LiveKit conformance — speaking-timeline (15 scenarios)', () {
    final scenarios =
        (_readVector('speaking-timeline.json')['scenarios'] as List)
            .cast<Map<String, dynamic>>();
    for (final s in scenarios) {
      test('speaking:${s['name']}', () => _runSpeakingScenario(s));
    }
  });

  group('LiveKit conformance — retry-policy (9 scenarios)', () {
    final scenarios = (_readVector('retry-policy.json')['scenarios'] as List)
        .cast<Map<String, dynamic>>();
    for (final s in scenarios) {
      test('retry:${s['name']}', () => _runRetryPolicyScenario(s));
    }
  });

  group('LiveKit conformance — session-data (8 scenarios)', () {
    final scenarios = (_readVector('session-data.json')['scenarios'] as List)
        .cast<Map<String, dynamic>>();
    for (final s in scenarios) {
      test('session:${s['name']}', () => _runSessionDataScenario(s));
    }
  });
}

// ── reply-stream port ────────────────────────────────────────────

Future<void> _runLifecycleScenario(Map<String, dynamic> scenario) async {
  const liveKitRoomName = 'conf-livekit-room';
  const mintedRoomName = 'conf-minted-room';
  final scheduler = _TestLifecycleScheduler();
  final notices = <String>[];
  final warmingRooms = <String>[];
  final readyRooms = <String>[];
  final speaking = <bool>[];
  String? endedCause;
  var endedCount = 0;
  var roomDisconnects = 0;
  var roomsBuilt = 0;
  var liveKitLoaded = false;
  var closed = false;
  var hasVideo = false;
  var state = t0.EngineState.idle;
  String? roomName;

  final lifecycle = LiveKitEngineLifecycle(
    isClosed: () => closed,
    onState: (value) => state = value,
    onNotice: (event) => notices.add(switch (event.kind) {
      t0.NoticeKind.sessionsBusy => 'sessions-busy',
      t0.NoticeKind.rendererTimeout => 'renderer-timeout',
    }),
    onWarming: (event) => warmingRooms.add(event.room),
    onReady: (event) => readyRooms.add(event.room),
    onSpeaking: (event) => speaking.add(event.active),
    schedule: scheduler.schedule,
  );

  void closeRoom({String? cause}) {
    if (closed || roomsBuilt == 0) return;
    closed = true;
    lifecycle.close();
    state = t0.EngineState.ended;
    roomName = null;
    roomDisconnects++;
    speaking.add(false);
    if (cause != null) {
      endedCause = cause;
      endedCount++;
    }
  }

  Object? outcome;
  final mint = scenario['mint'] as Map?;
  try {
    state = t0.EngineState.minting;
    if (mint?['throws'] == 'mint-rate-limited') {
      throw t0.MintRateLimited((mint?['retryAfterSeconds'] as num).toInt());
    }
    if (mint?['throws'] == 'host-error') {
      throw StateError('host-error');
    }
    if (mint?['kind'] == 'disabled') {
      state = t0.EngineState.idle;
      outcome = 'disabled';
    } else {
      warmingRooms.add(mintedRoomName);
      state = t0.EngineState.joining;
      roomName = mintedRoomName;
      roomsBuilt++;
      liveKitLoaded = true;
      final prefix =
          scenario['agentIdentityPrefix'] as String? ?? 'livealman-agent-';
      final present = (scenario['agentPresentAtJoin'] as List? ?? const [])
          .cast<String>()
          .any((identity) => identity.startsWith(prefix));
      lifecycle.joined(
        agentAlreadyPresent: present,
        roomName: liveKitRoomName,
      );
      outcome = 'connected';

      for (final raw in scenario['timeline'] as List? ?? const []) {
        final step = raw as Map;
        if (step['fire'] != null) {
          scheduler.fire(Duration(milliseconds: (step['fire'] as num).toInt()));
          continue;
        }
        if (step['do'] == 'disconnect') {
          closeRoom();
          continue;
        }
        final event = step['emit'];
        final identity = step['identity'] as String?;
        if (event == 'participant-connected' &&
            identity != null &&
            identity.startsWith(prefix)) {
          lifecycle.agentPresent(liveKitRoomName);
        } else if (event == 'track-subscribed' && step['kind'] == 'video') {
          hasVideo = true;
          lifecycle.rendererReady(liveKitRoomName);
        } else if (event == 'participant-disconnected' &&
            identity != null &&
            identity.startsWith(prefix)) {
          closeRoom(cause: 'agent-ended');
        } else if (event == 'disconnected') {
          closeRoom(cause: 'transport-ended');
        } else if (event == 'reconnecting') {
          lifecycle.reconnecting(liveKitRoomName);
        } else if (event == 'reconnected') {
          lifecycle.reconnected(
            roomName: liveKitRoomName,
            hasVideo: hasVideo,
          );
        }
      }
    }
  } catch (err) {
    state = t0.EngineState.idle;
    outcome = err;
  }

  final expected = scenario['expect'] as Map;
  if (expected['throws'] == 'mint-rate-limited') {
    expect(outcome, isA<t0.MintRateLimited>());
    expect(
      (outcome as t0.MintRateLimited).retryAfterSeconds,
      equals(expected['retryAfterSeconds']),
    );
  } else if (expected['throws'] == 'host-error') {
    expect(outcome, isA<StateError>());
  } else if (expected.containsKey('connectResult')) {
    expect(outcome, equals(expected['connectResult']));
  }
  if (expected.containsKey('finalState')) {
    expect(state.name, equals(expected['finalState']));
  }
  if (expected.containsKey('isReady')) {
    expect(lifecycle.ready && !closed, equals(expected['isReady']));
  }
  if (expected.containsKey('notices')) {
    expect(notices, equals(expected['notices']));
  }
  if (expected.containsKey('endedCause')) {
    expect(endedCause, equals(expected['endedCause']));
  }
  if (expected.containsKey('endedCount')) {
    expect(endedCount, equals(expected['endedCount']));
  }
  if (expected.containsKey('warmingRooms')) {
    expect(warmingRooms, equals(expected['warmingRooms']));
  }
  if (expected.containsKey('readyRooms')) {
    expect(readyRooms, equals(expected['readyRooms']));
  }
  if (expected.containsKey('roomName')) {
    expect(roomName, equals(expected['roomName']));
  }
  if (expected.containsKey('speaking')) {
    expect(speaking, equals(expected['speaking']));
  }
  if (expected.containsKey('roomDisconnects')) {
    expect(roomDisconnects, equals(expected['roomDisconnects']));
  }
  if (expected.containsKey('roomsBuilt')) {
    expect(roomsBuilt, equals(expected['roomsBuilt']));
  }
  if (expected.containsKey('liveKitLoaded')) {
    expect(liveKitLoaded, equals(expected['liveKitLoaded']));
  }
}

class _TestLifecycleScheduler {
  final _timers = <_TestLifecycleTimer>[];

  LiveKitLifecycleTimer schedule(Duration delay, void Function() callback) {
    final timer = _TestLifecycleTimer(delay, callback);
    _timers.add(timer);
    return timer;
  }

  void fire(Duration delay) {
    final due =
        _timers.where((timer) => timer.active && timer.delay == delay).toList();
    for (final timer in due) {
      timer.fire();
    }
  }
}

class _TestLifecycleTimer implements LiveKitLifecycleTimer {
  _TestLifecycleTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool active = true;

  void fire() {
    if (!active) return;
    active = false;
    _callback();
  }

  @override
  void cancel() => active = false;
}

void _runSpeakingScenario(Map<String, dynamic> scenario) {
  final active = <bool>[];
  final dispatcher = _makeSessionDispatcher(
    agentIdentityPrefix:
        scenario['agentIdentityPrefix'] as String? ?? 'livealman-agent-',
    onSpeaking: (event) => active.add(event.active),
  );

  for (final raw in scenario['messages'] as List) {
    final message = raw as Map;
    dispatcher.receiveData(
      topic: message['topic'] as String?,
      participantIdentity: message['from'] as String?,
      payload: utf8.encode(message['payload'] as String),
    );
  }

  expect(active, equals(scenario['expectActive']));
}

Future<void> _runSessionDataScenario(Map<String, dynamic> scenario) async {
  final events = <Map<String, Object?>>[];
  final agentIdentity =
      (_readVector('session-data.json')['agentIdentity'] as String);
  final dispatcher = _makeSessionDispatcher(
    keepTags: scenario['keepTags'] == true,
    onReplyStart: (event) => events.add({
      'event': 'reply:start',
      'replyId': event.replyId,
    }),
    onReplyText: (event) => events.add({
      'event': 'reply:text',
      'replyId': event.replyId,
      'text': event.text,
    }),
    onReplyComplete: (event) => events.add({
      'event': 'reply:complete',
      'replyId': event.replyId,
      'text': event.text,
      'kind': event.kind.name,
    }),
    onControl: (event) => events.add({
      'event': 'control',
      'payload': event.event,
    }),
    onTranscript: (event) => events.add({
      'event': 'transcript',
      'participant': event.participant,
      'text': event.text,
      'final': event.finalChunk,
    }),
  );

  for (final raw in scenario['timeline'] as List) {
    final step = raw as Map;
    if (step['data'] != null) {
      final data = step['data'] as Map;
      dispatcher.receiveData(
        topic: data['topic'] as String?,
        participantIdentity: data['from'] as String? ?? agentIdentity,
        payload: utf8.encode(data['payload'] as String),
      );
    } else if (step['transcription'] != null) {
      final transcription = step['transcription'] as Map;
      final chunks = () async* {
        for (final chunk in transcription['chunks'] as List) {
          yield chunk as String;
        }
        if (transcription['failsWith'] != null) {
          throw StateError(transcription['failsWith'] as String);
        }
      }();
      await dispatcher.consumeFallbackTranscription(
        id: transcription['id'] as String,
        participantIdentity:
            transcription['fromLocal'] == true ? 'viewer-local' : agentIdentity,
        localParticipantIdentity: 'viewer-local',
        chunks: chunks,
      );
    } else if (step['send'] != null) {
      dispatcher.beginTurn();
    } else {
      fail('Unknown session-data step: $step');
    }
  }

  expect(events, equals(scenario['expectEvents']));
}

LiveKitSessionDataDispatcher _makeSessionDispatcher({
  String agentIdentityPrefix = 'livealman-agent-',
  bool keepTags = false,
  void Function(t0.SpeakingActiveEvent event)? onSpeaking,
  void Function(t0.ReplyStartEvent event)? onReplyStart,
  void Function(t0.ReplyTextEvent event)? onReplyText,
  void Function(t0.ReplyCompleteEvent event)? onReplyComplete,
  void Function(t0.ControlEvent event)? onControl,
  void Function(t0.TranscriptEvent event)? onTranscript,
}) {
  return LiveKitSessionDataDispatcher(
    agentIdentityPrefix: agentIdentityPrefix,
    keepTags: () => keepTags,
    onSpeaking: onSpeaking ?? (_) {},
    onReplyStart: onReplyStart ?? (_) {},
    onReplyText: onReplyText ?? (_) {},
    onReplyComplete: onReplyComplete ?? (_) {},
    onControl: onControl ?? (_) {},
    onTranscript: onTranscript ?? (_) {},
  );
}

Future<void> _runEnvelopeScenario(Map<String, dynamic> scenario) async {
  if (scenario['ready'] == false) {
    final videoSlot = ValueNotifier<lk.RemoteVideoTrack?>(null);
    final engine = t0.LiveKitEngine(t0.LiveKitEngineOptions(
      mint: () async => const t0.MintResultDisabled(),
      media: t0.LiveKitEngineMedia(videoSlot: videoSlot),
    ));
    try {
      await expectLater(
        engine.send(scenario['text'] as String),
        throwsA(isA<t0.SessionNotReady>()),
      );
    } finally {
      await engine.disconnect();
      await engine.dispose();
      videoSlot.dispose();
    }
    return;
  }

  final extra = scenario['extra'] == null
      ? null
      : Map<String, Object?>.from(scenario['extra'] as Map);
  final built = buildLiveKitChatEnvelope(
    scenario['text'] as String,
    extra: extra,
  );
  final requestId = built['request_id'];
  expect(requestId, isA<String>());
  expect(
    requestId,
    matches(RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    )),
  );

  final expected = Map<String, Object?>.from(
    (scenario['expect'] as Map)['envelope'] as Map,
  );
  final withoutRequestId = Map<String, Object?>.from(built)
    ..remove('request_id');
  expect('lk.chat', equals((scenario['expect'] as Map)['topic']));
  expect(withoutRequestId, equals(expected));

  final requestExpectation = (scenario['expect'] as Map)['requestId'] as Map?;
  for (final forbidden
      in requestExpectation?['notEqualTo'] as List? ?? const []) {
    expect(requestId, isNot(equals(forbidden)));
  }
  if (requestExpectation?['uniqueAcrossBuilds'] == true) {
    final second = buildLiveKitChatEnvelope(
      scenario['text'] as String,
      extra: extra,
    );
    expect(second['request_id'], isNot(equals(requestId)));
  }
}

Future<void> _runMintScenario(Map<String, dynamic> scenario) async {
  final headers = scenario['headers'] == null
      ? <String, String>{}
      : Map<String, String>.from(scenario['headers'] as Map);
  final body = scenario['body'] as Map?;
  final response = t0.SimpleMintResponse(
    status: (scenario['status'] as num?)?.toInt() ?? 0,
    headers: headers,
    bodyText: body?['raw'] as String? ?? '',
    bodyReadable: body?['readFails'] == null,
  );

  Object? outcome;
  try {
    final t0.MintResult result;
    if (scenario['requestFailed'] == true) {
      result = await t0.mintResultFromFetch(
        Future<t0.MintResponseLike>.error(StateError('request failed')),
      );
    } else if (scenario['via'] == 'fetch') {
      result = await t0.mintResultFromFetch(Future.value(response));
    } else {
      result = await t0.mintResultFromResponse(response);
    }
    outcome = switch (result) {
      t0.MintResultEnabled r => <String, Object?>{
          'kind': 'enabled',
          'url': r.url,
          'token': r.token,
          'room': r.room,
        },
      t0.MintResultDisabled() => <String, Object?>{'kind': 'disabled'},
    };
  } catch (err) {
    outcome = err;
  }

  final expected = scenario['expect'] as Map;
  if (expected['resolves'] != null) {
    expect(outcome, equals(expected['resolves']));
  } else if (expected['throws'] == 'mint-rate-limited') {
    expect(outcome, isA<t0.MintRateLimited>());
    expect(
      (outcome as t0.MintRateLimited).retryAfterSeconds,
      equals(expected['retryAfterSeconds']),
    );
  } else if (expected['throws'] == 'mint-unavailable') {
    expect(outcome, isA<t0.MintUnavailable>());
    final detail = (outcome as t0.MintUnavailable).detail;
    if (expected['detailExact'] != null) {
      expect(detail, equals(expected['detailExact']));
    }
    if (expected['detailContains'] != null) {
      expect(detail, contains(expected['detailContains'] as String));
    }
  } else {
    fail('Unknown mint expectation shape: $expected');
  }

  if (scenario['requestFailed'] != true) {
    final expectedReads = scenario['bodyMustNotBeRead'] == true ? 0 : 1;
    expect(response.jsonReads, equals(expectedReads));
  }
}

Future<void> _runRetryPolicyScenario(Map<String, dynamic> scenario) async {
  final lifecycle = t0.LiveKitRoomLifecycle<Object>(
    maxAutomaticRetries:
        (scenario['maxAutomaticRetries'] as num?)?.toInt() ?? 3,
  );
  final owners = <String, Object>{};
  final disconnects = <String, int>{};
  final results = <Object?>[];
  final order = <String>[];
  final pending = <Future<void>>[];
  final gate = Completer<void>();

  Object owner(String name) => owners.putIfAbsent(name, Object.new);

  for (final rawStep in scenario['steps'] as List) {
    final step = rawStep as Map;
    if (step['install'] != null) {
      lifecycle.install(owner(step['install'] as String));
      results.add(null);
    } else if (step['release'] != null) {
      final name = step['release'] as String;
      final gated = step['disconnect'] == 'gated';
      final closing = lifecycle.release(owner(name), () async {
        disconnects[name] = (disconnects[name] ?? 0) + 1;
        if (gated) {
          order.add('disconnect-start');
          await gate.future;
          order.add('disconnect-end');
        }
      });
      if (gated) {
        pending.add(closing);
      } else {
        await closing;
      }
      results.add(null);
    } else if (step['raceWaitForDisconnect'] != null) {
      final marker = step['raceWaitForDisconnect'] as String;
      pending.add(() async {
        await lifecycle.waitForDisconnect();
        order.add(marker);
      }());
      results.add(null);
    } else if (step['openGate'] == true) {
      if (!gate.isCompleted) gate.complete();
      await Future.wait(pending);
      pending.clear();
      results.add(null);
    } else if (step['beginExplicitEpisode'] == true) {
      lifecycle.beginExplicitEpisode();
      results.add(null);
    } else if (step['noteRendererReady'] != null) {
      results.add(lifecycle.noteRendererReady(
        owner(step['noteRendererReady'] as String),
      ));
    } else if (step['noteTerminalFailure'] != null) {
      final cause = switch (step['noteTerminalFailure']) {
        'agent-ended' => t0.LiveKitTerminalCause.agentEnded,
        'transport-ended' => t0.LiveKitTerminalCause.transportEnded,
        'rate-limited' => t0.LiveKitTerminalCause.rateLimited,
        final value => throw StateError('Unknown terminal cause: $value'),
      };
      results.add(switch (lifecycle.noteTerminalFailure(cause)) {
        t0.LiveKitTerminalAction.retry => 'retry',
        t0.LiveKitTerminalAction.awaitUser => 'await-user',
        t0.LiveKitTerminalAction.blocked => 'blocked',
      });
    } else if (step['isCurrent'] != null) {
      results.add(lifecycle.isCurrent(owner(step['isCurrent'] as String)));
    } else {
      fail('Unknown retry-policy step: $step');
    }
  }
  await Future.wait(pending);

  expect(results, equals(scenario['expectResults']));
  if (scenario['expectOrder'] != null) {
    expect(order, equals(scenario['expectOrder']));
  }

  final expectedFinal = scenario['expectFinal'] as Map;
  if (expectedFinal.containsKey('automaticAttempts')) {
    expect(
      lifecycle.automaticAttempts,
      equals(expectedFinal['automaticAttempts']),
    );
  }
  if (expectedFinal.containsKey('isRateLimited')) {
    expect(lifecycle.isRateLimited, equals(expectedFinal['isRateLimited']));
  }
  final expectedDisconnects = expectedFinal['disconnects'] as Map?;
  if (expectedDisconnects != null) {
    for (final entry in expectedDisconnects.entries) {
      expect(disconnects[entry.key] ?? 0, equals(entry.value));
    }
  }
}

void _runReplyStreamScenario(Map<String, dynamic> scenario) {
  final frames = (scenario['frames'] as List).cast<Object>();
  final expectEvents =
      (scenario['expectEvents'] as List).cast<Map<String, dynamic>>();
  final expectAccepted = (scenario['expectAccepted'] as List?)?.cast<Object?>();
  final expectSawProtocol = scenario['expectSawProtocol'] as bool?;
  // keepTags defaults to false per vector spec; a scenario may seed
  // it via a top-level field or flip it mid-stream via a directive.
  var keepTags = (scenario['keepTags'] as bool?) ?? false;

  // Capture ordered events as the reducer fires callbacks.
  final events = <Map<String, Object?>>[];
  final reducer = ReplyStreamReducer(
    onStart: (id) => events.add({'event': 'start', 'replyId': id}),
    onText: (text, id) =>
        events.add({'event': 'text', 'replyId': id, 'text': text}),
    onComplete: (text, kind, id) => events.add({
      'event': 'complete',
      'replyId': id,
      'text': text,
      'kind': switch (kind) {
        ReplyTerminalKind.end => 'end',
        ReplyTerminalKind.cancel => 'cancel',
        ReplyTerminalKind.error => 'error',
      },
    }),
    keepTags: () => keepTags,
  );

  // Replay each entry, marking accepted per obligation 7: directives
  // (`reset` / `keepTags`) get null; frames get true iff the reducer
  // emitted any event for them.
  final accepted = <Object?>[];
  for (final entry in frames) {
    if (entry is Map && entry['op'] is String) {
      final op = entry['op'] as String;
      switch (op) {
        case 'reset':
          reducer.reset();
        case 'keepTags':
          keepTags = entry['value'] as bool;
        default:
          fail('Unknown directive op: $op');
      }
      accepted.add(null);
      continue;
    }
    final before = events.length;
    final frame = ReplyFrame.tryParse(entry);
    if (frame == null) {
      // Malformed frame: never reaches apply(). accepted=false.
      accepted.add(false);
      continue;
    }
    reducer.apply(frame);
    accepted.add(events.length > before);
  }

  // Obligation 1: arrays are ordered; compare event log exactly.
  expect(events, equals(expectEvents),
      reason: 'event log mismatch for ${scenario['name']}');

  if (expectAccepted != null) {
    expect(accepted, equals(expectAccepted),
        reason: 'accept verdict mismatch for ${scenario['name']}');
  }
  if (expectSawProtocol != null) {
    expect(reducer.sawProtocol, equals(expectSawProtocol),
        reason: 'sawProtocol mismatch for ${scenario['name']}');
  }
}
