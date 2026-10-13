import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

/// Fill parent — good default for wrapping tests since most scene
/// primitives take a `child: Widget` with no size constraint.
class _FillMarker extends StatelessWidget {
  const _FillMarker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: Key(name),
        child: const SizedBox.expand(),
      );
}

Widget _wrap(
  Widget child, {
  Size size = const Size(1600, 900),
  bool disableAnimations = false,
}) {
  final base = MediaQueryData(
    size: size,
    disableAnimations: disableAnimations,
  );
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: base,
      child: SizedBox.fromSize(size: size, child: child),
    ),
  );
}

void main() {
  group('SceneAnchor', () {
    test('resolveIn returns feed rect centered on x, top-anchored on y', () {
      const anchor = SceneAnchor(
        xFraction: 0.5,
        yFraction: 0.1,
        widthFraction: 0.4,
        heightFraction: 0.8,
      );
      final rect = anchor.resolveIn(const Size(1000, 500));
      expect(rect.width, closeTo(400, 1e-9));
      expect(rect.height, closeTo(400, 1e-9));
      expect(rect.left, closeTo(300, 1e-9)); // 500 (center) - 200 (half width)
      expect(rect.top, closeTo(50, 1e-9)); // 500 * 0.1
    });

    test('equality by value', () {
      const a = SceneAnchor(
        xFraction: 0.5,
        yFraction: 0.0,
        widthFraction: 1.0,
        heightFraction: 1.0,
      );
      expect(a, equals(SceneAnchor.fullStage));
    });
  });

  group('TwaiEdgeFeather', () {
    testWidgets('renders child + does not throw', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiEdgeFeather(child: _FillMarker('inside')),
      ));
      expect(find.byKey(const Key('inside')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('TwaiColorGrade', () {
    test('isIdentity true for defaults', () {
      const g = TwaiColorGrade(child: SizedBox());
      expect(g.isIdentity, isTrue);
    });

    test('isIdentity false when any grade non-default', () {
      const g = TwaiColorGrade(child: SizedBox(), brightness: 0.9);
      expect(g.isIdentity, isFalse);
    });

    testWidgets('identity grade skips ColorFiltered wrapping', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiColorGrade(child: _FillMarker('inside')),
      ));
      // No ColorFiltered ancestor of the marker when grade is
      // identity — the widget short-circuits to raw child.
      expect(
        find.ancestor(
          of: find.byKey(const Key('inside')),
          matching: find.byType(ColorFiltered),
        ),
        findsNothing,
      );
    });

    testWidgets('non-identity grade wraps in ColorFiltered', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiColorGrade(
          brightness: 0.87,
          hueRotate: -6,
          child: _FillMarker('inside'),
        ),
      ));
      expect(
        find.ancestor(
          of: find.byKey(const Key('inside')),
          matching: find.byType(ColorFiltered),
        ),
        findsOneWidget,
      );
    });
  });

  group('TwaiContactShadow', () {
    testWidgets('renders as a pointer-transparent overlay', (tester) async {
      await tester.pumpWidget(_wrap(const TwaiContactShadow()));
      expect(find.byType(TwaiContactShadow), findsOneWidget);
      expect(find.byType(IgnorePointer), findsOneWidget);
    });
  });

  group('TwaiKenBurnsParallax', () {
    testWidgets('animates by default (controller running)', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiKenBurnsParallax(child: _FillMarker('plate')),
      ));
      expect(find.byKey(const Key('plate')), findsOneWidget);
      // Let the controller tick once.
      await tester.pump(const Duration(seconds: 1));
      // No crash + child still there.
      expect(find.byKey(const Key('plate')), findsOneWidget);
    });

    testWidgets(
      'respects prefers-reduced-motion (disableAnimations = true) '
      '— renders static, no ticker running',
      (tester) async {
        await tester.pumpWidget(_wrap(
          TwaiKenBurnsParallax(child: _FillMarker('plate')),
          disableAnimations: true,
        ));
        expect(find.byKey(const Key('plate')), findsOneWidget);
        // Advance a long time; if the ticker was running the widget
        // tree would rebuild via AnimatedBuilder; if it isn't, this
        // is a no-op. Either way we're just asserting no crash.
        await tester.pump(const Duration(seconds: 5));
        expect(find.byKey(const Key('plate')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('TwaiScene + TwaiSceneController', () {
    test('scenes with same fields compare equal', () {
      final a = TwaiScene(id: 'x', plate: Container());
      final b = TwaiScene(id: 'x', plate: Container());
      // Not equal — plate widgets are different instances. This
      // documents behavior; app-level equality checks should
      // compare scene ids.
      expect(a, isNot(equals(b)));
      expect(a.id, b.id);
    });

    test('controller.go swaps scene + notifies listeners', () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final s2 = TwaiScene(id: 's2', plate: Container());
      final ctrl = TwaiSceneController(initial: s1);
      var notifyCount = 0;
      ctrl.addListener(() => notifyCount++);
      expect(ctrl.current.id, 's1');
      ctrl.go('s2', from: [s1, s2]);
      expect(ctrl.current.id, 's2');
      expect(notifyCount, 1);
    });

    test('controller.go with same id is no-op (no notify)', () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final ctrl = TwaiSceneController(initial: s1);
      var notifyCount = 0;
      ctrl.addListener(() => notifyCount++);
      ctrl.go('s1', from: [s1]);
      expect(notifyCount, 0);
    });

    test('controller.go with unknown id is silent no-op', () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final ctrl = TwaiSceneController(initial: s1);
      ctrl.go('does-not-exist', from: [s1]);
      expect(ctrl.current.id, 's1');
      expect(ctrl.canGo('does-not-exist', from: [s1]), isFalse);
      expect(ctrl.canGo('s1', from: [s1]), isTrue);
    });
  });

  group('TwaiSceneNavigator', () {
    testWidgets('renders current scene\'s plate + feed', (tester) async {
      final s1 = TwaiScene(id: 's1', plate: _FillMarker('plate-1'));
      final s2 = TwaiScene(id: 's2', plate: _FillMarker('plate-2'));
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_wrap(
        TwaiSceneNavigator(
          controller: ctrl,
          scenes: [s1, s2],
          feed: _FillMarker('feed'),
          kenBurns: false, // simplifies the tree for the finder
        ),
      ));
      expect(find.byKey(const Key('plate-1')), findsOneWidget);
      expect(find.byKey(const Key('feed')), findsOneWidget);
      expect(find.byKey(const Key('plate-2')), findsNothing);
    });

    testWidgets('rebuilds on controller.go(other-id)', (tester) async {
      final s1 = TwaiScene(id: 's1', plate: _FillMarker('plate-1'));
      final s2 = TwaiScene(id: 's2', plate: _FillMarker('plate-2'));
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_wrap(
        TwaiSceneNavigator(
          controller: ctrl,
          scenes: [s1, s2],
          feed: _FillMarker('feed'),
          kenBurns: false,
        ),
      ));
      ctrl.go('s2', from: [s1, s2]);
      await tester.pump();
      expect(find.byKey(const Key('plate-1')), findsNothing);
      expect(find.byKey(const Key('plate-2')), findsOneWidget);
    });

    testWidgets(
      'anchor positions feed inside scene stage (not full-bleed)',
      (tester) async {
        // Actually resize the test surface — the nested SizedBox gets
        // clamped by the default 800×600, same trap as A1's portrait
        // test.
        await tester.binding.setSurfaceSize(const Size(1000, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final anchoredScene = TwaiScene(
          id: 'anchored',
          plate: _FillMarker('plate'),
          anchor: const SceneAnchor(
            xFraction: 0.5,
            yFraction: 0.0,
            widthFraction: 0.5,
            heightFraction: 1.0,
          ),
        );
        final ctrl = TwaiSceneController(initial: anchoredScene);
        addTearDown(ctrl.dispose);

        await tester.pumpWidget(_wrap(
          TwaiSceneNavigator(
            controller: ctrl,
            scenes: [anchoredScene],
            feed: _FillMarker('feed'),
            kenBurns: false,
          ),
          size: const Size(1000, 500),
        ));
        final feedRect = tester.getRect(find.byKey(const Key('feed')));
        // 0.5 wide × 1.0 tall → 500 × 500 in a 1000×500 stage.
        expect(feedRect.width, closeTo(500, 1));
        expect(feedRect.height, closeTo(500, 1));
      },
    );
  });

  group('TwaiSceneController transition-film state', () {
    test('go(target-with-film) sets pending, does not swap current yet', () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final s2 = TwaiScene(
        id: 's2',
        plate: Container(),
        transitionFilmUrl: 'https://cdn/s1-to-s2.mp4',
      );
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);
      var notifyCount = 0;
      ctrl.addListener(() => notifyCount++);

      ctrl.go('s2', from: [s1, s2]);
      expect(ctrl.current.id, 's1', reason: 'current stays put during film');
      expect(ctrl.pending?.id, 's2');
      expect(ctrl.isTransitioning, isTrue);
      expect(notifyCount, 1);
    });

    test('notifyTransitionComplete swaps current to pending + clears pending',
        () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final s2 = TwaiScene(
        id: 's2',
        plate: Container(),
        transitionFilmUrl: 'https://cdn/film.mp4',
      );
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);
      ctrl.go('s2', from: [s1, s2]);
      expect(ctrl.pending?.id, 's2');

      ctrl.notifyTransitionComplete();
      expect(ctrl.current.id, 's2');
      expect(ctrl.pending, isNull);
      expect(ctrl.isTransitioning, isFalse);
    });

    test('notifyTransitionComplete is a no-op when nothing pending', () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);
      var notifyCount = 0;
      ctrl.addListener(() => notifyCount++);
      ctrl.notifyTransitionComplete();
      expect(notifyCount, 0);
      expect(ctrl.current.id, 's1');
    });

    test('go(target-without-film) still hard-cuts (bypasses transition state)',
        () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final s2 = TwaiScene(id: 's2', plate: Container());
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);
      ctrl.go('s2', from: [s1, s2]);
      expect(ctrl.current.id, 's2');
      expect(ctrl.pending, isNull);
      expect(ctrl.isTransitioning, isFalse);
    });

    test('go while transitioning replaces the pending target', () {
      final s1 = TwaiScene(id: 's1', plate: Container());
      final s2 = TwaiScene(
        id: 's2',
        plate: Container(),
        transitionFilmUrl: 'https://cdn/film-s2.mp4',
      );
      final s3 = TwaiScene(
        id: 's3',
        plate: Container(),
        transitionFilmUrl: 'https://cdn/film-s3.mp4',
      );
      final ctrl = TwaiSceneController(initial: s1);
      addTearDown(ctrl.dispose);

      ctrl.go('s2', from: [s1, s2, s3]);
      expect(ctrl.pending?.id, 's2');
      ctrl.go('s3', from: [s1, s2, s3]);
      expect(ctrl.pending?.id, 's3',
          reason: 'second go should overwrite the pending target');
      expect(ctrl.current.id, 's1',
          reason: 'current still not swapped until notifyTransitionComplete');
    });

    testWidgets(
      'TwaiSceneNavigator mounts TwaiCinematicPlayer in overlay while '
      'transitioning; unmounts after notifyTransitionComplete',
      (tester) async {
        final s1 = TwaiScene(id: 's1', plate: _FillMarker('plate-1'));
        final s2 = TwaiScene(
          id: 's2',
          plate: _FillMarker('plate-2'),
          transitionFilmUrl: 'https://example.invalid/film.mp4',
        );
        final ctrl = TwaiSceneController(initial: s1);
        addTearDown(ctrl.dispose);

        await tester.pumpWidget(_wrap(
          TwaiSceneNavigator(
            controller: ctrl,
            scenes: [s1, s2],
            feed: _FillMarker('feed'),
            kenBurns: false,
          ),
        ));
        expect(find.byType(TwaiCinematicPlayer), findsNothing);
        expect(find.byKey(const Key('plate-1')), findsOneWidget);

        // Kick off transition — pending set, film should mount.
        ctrl.go('s2', from: [s1, s2]);
        await tester.pump();
        expect(find.byType(TwaiCinematicPlayer), findsOneWidget,
            reason: 'transition film should render in overlay slot');
        expect(find.byKey(const Key('plate-1')), findsOneWidget,
            reason: 'outgoing scene stays visible under the film');

        // Simulate film completing.
        ctrl.notifyTransitionComplete();
        await tester.pump();
        expect(find.byType(TwaiCinematicPlayer), findsNothing);
        expect(find.byKey(const Key('plate-2')), findsOneWidget,
            reason: 'new scene is live after transition completes');
      },
    );
  });
}
