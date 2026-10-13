import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

void main() {
  group('TwaiGreeting', () {
    test('.none is a const identity', () {
      const a = TwaiGreeting.none();
      const b = TwaiGreeting.none();
      expect(identical(a, b), isTrue);
      expect(a, isA<TwaiGreetingNone>());
    });

    test('.text carries all construction fields', () {
      const g = TwaiGreeting.text(
        text: 'Hello.',
        scopeId: 'test:scope',
        onceForever: false,
        sendAfterReady: Duration(milliseconds: 100),
      );
      expect(g, isA<TwaiGreetingText>());
      final t = g as TwaiGreetingText;
      expect(t.text, 'Hello.');
      expect(t.scopeId, 'test:scope');
      expect(t.onceForever, isFalse);
      expect(t.sendAfterReady, const Duration(milliseconds: 100));
      expect(t.onSent, isNull);
    });

    test('.text defaults are stable', () {
      const g = TwaiGreeting.text(text: 'hi', scopeId: 's');
      final t = g as TwaiGreetingText;
      expect(t.onceForever, isTrue, reason: 'default persistence is onceForever');
      expect(t.sendAfterReady, const Duration(milliseconds: 400),
          reason: 'default clears the engine SEND_GRACE_MS window');
    });

    test('.rendered carries all construction fields including intro/return kinds', () {
      final rendered = TwaiGreeting.rendered(
        videoUrl: Uri.parse('https://example.com/g.mp4'),
        text: 'Welcome back.',
        id: 'grt_123',
        kind: GreetingKind.returning,
        consumptionKey: 'rg-42-1727280000',
      );
      expect(rendered, isA<TwaiGreetingRendered>());
      final r = rendered as TwaiGreetingRendered;
      expect(r.id, 'grt_123');
      expect(r.kind, GreetingKind.returning);
      expect(r.consumptionKey, 'rg-42-1727280000');
    });

    test('.dynamic exposes its fetch callback', () async {
      var called = 0;
      final d = TwaiGreeting.dynamic(fetch: () async {
        called++;
        return const TwaiGreeting.text(text: 'resolved', scopeId: 's');
      });
      expect(d, isA<TwaiGreetingDynamic>());
      final result = await (d as TwaiGreetingDynamic).fetch();
      expect(called, 1);
      expect(result, isA<TwaiGreetingText>());
      expect((result as TwaiGreetingText).text, 'resolved');
    });

    test('TwaiGreetingPlayedEvent carries the audible flag', () {
      const ev = TwaiGreetingPlayedEvent(
        greetingId: 'grt_1',
        kind: GreetingKind.intro,
        wasAudible: false,
      );
      expect(ev.wasAudible, isFalse);
      expect(ev.consumptionKey, isNull);
    });
  });

  group('InMemoryGreetingStore', () {
    test('starts empty', () async {
      final store = InMemoryGreetingStore();
      expect(await store.hasBeenSent('any'), isFalse);
    });

    test('markSent then hasBeenSent returns true', () async {
      final store = InMemoryGreetingStore();
      await store.markSent('scope-a');
      expect(await store.hasBeenSent('scope-a'), isTrue);
      expect(await store.hasBeenSent('scope-b'), isFalse,
          reason: 'other scopes are independent');
    });

    test('markSent is idempotent', () async {
      final store = InMemoryGreetingStore();
      await store.markSent('scope-a');
      await store.markSent('scope-a');
      expect(await store.hasBeenSent('scope-a'), isTrue);
    });

    test('clear reverts the flag', () async {
      final store = InMemoryGreetingStore();
      await store.markSent('scope-a');
      await store.clear('scope-a');
      expect(await store.hasBeenSent('scope-a'), isFalse);
    });

    test('clearing an unset scope is a no-op', () async {
      final store = InMemoryGreetingStore();
      await store.clear('never-set');
      expect(await store.hasBeenSent('never-set'), isFalse);
    });

    test('two stores are independent', () async {
      final a = InMemoryGreetingStore();
      final b = InMemoryGreetingStore();
      await a.markSent('s');
      expect(await b.hasBeenSent('s'), isFalse);
    });
  });

  group('TwaiGreeting.dynamic resolution semantics', () {
    // These tests cover the fetch-returning-another-dynamic recursion
    // guard that TwaiTransport0Player enforces. The guard lives in the
    // widget layer; here we just verify the fetch callback can be
    // invoked repeatedly and each call produces an independent future.

    test('fetch is called on each invocation', () async {
      var calls = 0;
      final d = TwaiGreeting.dynamic(fetch: () async {
        calls++;
        return const TwaiGreeting.none();
      });
      final f = d as TwaiGreetingDynamic;
      await f.fetch();
      await f.fetch();
      expect(calls, 2);
    });

    test('fetch may return any variant', () async {
      final asText = TwaiGreeting.dynamic(
        fetch: () async =>
            const TwaiGreeting.text(text: 'x', scopeId: 's'),
      );
      final asNone = TwaiGreeting.dynamic(
        fetch: () async => const TwaiGreeting.none(),
      );
      expect(await (asText as TwaiGreetingDynamic).fetch(),
          isA<TwaiGreetingText>());
      expect(await (asNone as TwaiGreetingDynamic).fetch(),
          isA<TwaiGreetingNone>());
    });
  });

  group('TwaiGreeting.fromCatalog', () {
    test('intro wire kind maps to GreetingKind.intro + no consumption key',
        () {
      final payload = TwaiApiGreetingPayload(
        id: 'grt_42',
        videoUrl: Uri.parse('https://blob.example.test/g.mp4'),
        text: 'Welcome.',
        kind: 'intro',
      );
      final greeting = TwaiGreeting.fromCatalog(payload);
      expect(greeting, isA<TwaiGreetingRendered>());
      final r = greeting as TwaiGreetingRendered;
      expect(r.id, 'grt_42');
      expect(r.text, 'Welcome.');
      expect(r.kind, GreetingKind.intro);
      expect(r.consumptionKey, isNull);
    });

    test('return wire kind maps to GreetingKind.returning + carries key', () {
      final payload = TwaiApiGreetingPayload(
        id: 'rg_7',
        videoUrl: Uri.parse('https://blob.example.test/rg.mp4'),
        text: 'Welcome back.',
        kind: 'return',
        consumptionKey: 'rg-7-1727900000',
      );
      final greeting = TwaiGreeting.fromCatalog(payload);
      final r = greeting as TwaiGreetingRendered;
      expect(r.kind, GreetingKind.returning);
      expect(r.consumptionKey, 'rg-7-1727900000');
    });

    test('unknown wire kind falls back to intro (safer default)', () {
      final payload = TwaiApiGreetingPayload(
        id: 'grt_x',
        videoUrl: Uri.parse('https://blob.example.test/x.mp4'),
        text: 'Hi.',
        kind: 'future-value-we-dont-know-yet',
      );
      final r = TwaiGreeting.fromCatalog(payload) as TwaiGreetingRendered;
      expect(r.kind, GreetingKind.intro,
          reason: 'intro skips the consumption POST; safest fallback');
    });

    test('onAudiblyPlayed callback is wired through', () {
      final payload = TwaiApiGreetingPayload(
        id: 'rg_8',
        videoUrl: Uri.parse('https://blob.example.test/rg8.mp4'),
        text: 't',
        kind: 'return',
        consumptionKey: 'rg-8-1',
      );
      TwaiGreetingPlayedEvent? captured;
      final r = TwaiGreeting.fromCatalog(
        payload,
        onAudiblyPlayed: (ev) => captured = ev,
      ) as TwaiGreetingRendered;
      // Simulate the widget firing the event (the adapter just wires
      // the callback; firing it here verifies the plumbing).
      r.onAudiblyPlayed!.call(TwaiGreetingPlayedEvent(
        greetingId: 'rg_8',
        kind: GreetingKind.returning,
        wasAudible: true,
        consumptionKey: 'rg-8-1',
      ));
      expect(captured, isNotNull);
      expect(captured!.consumptionKey, 'rg-8-1');
    });
  });
}
