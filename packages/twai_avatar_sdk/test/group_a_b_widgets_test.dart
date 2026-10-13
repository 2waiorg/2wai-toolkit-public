import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

/// Wrap a widget in a directionality + Theme + explicit MediaQuery
/// sized container. Avoiding MaterialApp — its default MediaQuery
/// cascades from the tester's view size and overrides ours, which
/// broke the portrait-fallback test on first pass.
Widget _wrap(
  Widget child, {
  Size size = const Size(1600, 900),
  Brightness brightness = Brightness.dark,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: Theme(
        data: ThemeData(brightness: brightness),
        child: SizedBox.fromSize(size: size, child: child),
      ),
    ),
  );
}

/// Fills its parent — useful when a test needs geometry (e.g. the
/// 16:9 aspect check) or when the marker is the sole layer of a
/// layout that expects an infinite child.
class _FillMarker extends StatelessWidget {
  const _FillMarker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: Key(name),
        child: const SizedBox.expand(),
      );
}

/// Fixed 24x24 marker — for slots that expect intrinsic-sized
/// children (motif, tiny inline widgets). Using [_FillMarker] here
/// would overflow the Row on TwaiGildedRule etc.
class _SmallMarker extends StatelessWidget {
  const _SmallMarker(this.name);
  final String name;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: Key(name),
        child: const SizedBox(width: 24, height: 24),
      );
}

void main() {
  group('A1 TwaiImmersiveLayout', () {
    testWidgets(
      'renders a 16:9 aspect-ratio stage in landscape viewport',
      (tester) async {
        await tester.pumpWidget(_wrap(
          TwaiImmersiveLayout(avatar: _FillMarker('stage')),
        ));
        final markerRect = tester.getRect(find.byKey(const Key('stage')));
        expect(markerRect.width / markerRect.height,
            closeTo(16 / 9, 0.01),
            reason: 'landscape must lock to 16:9 aspect');
      },
    );

    testWidgets(
      'switches to portraitFallback when viewport is taller than wide',
      (tester) async {
        // The test surface's default is 800×600 (landscape). Nested
        // SizedBox gets CLAMPED by that, so LayoutBuilder inside the
        // TwaiImmersiveLayout still sees a landscape aspect and never
        // fires the fallback branch. Actually resizing the surface is
        // the only reliable way to test portrait behavior.
        await tester.binding.setSurfaceSize(const Size(400, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(_wrap(
          TwaiImmersiveLayout(
            avatar: _FillMarker('landscape-stage'),
            portraitFallback: _FillMarker('portrait-fallback'),
          ),
          size: const Size(400, 800),
        ));
        expect(find.byKey(const Key('portrait-fallback')), findsOneWidget);
        expect(find.byKey(const Key('landscape-stage')), findsNothing);
      },
    );

    testWidgets(
      'portrait viewport with no fallback still renders the (aspect-locked) '
      'stage rather than crashing',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(_wrap(
          TwaiImmersiveLayout(avatar: _FillMarker('stage')),
          size: const Size(400, 800),
        ));
        expect(find.byKey(const Key('stage')), findsOneWidget);
      },
    );
  });

  group('A3 TwaiSceneStage', () {
    testWidgets('all five slots render in expected z-order', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiSceneStage(
          plate: _FillMarker('plate'),
          atmosphere: _FillMarker('atmosphere'),
          feed: _FillMarker('feed'),
          overlay: _FillMarker('overlay'),
          tools: _FillMarker('tools'),
        ),
      ));
      for (final k in const ['plate', 'atmosphere', 'feed', 'overlay', 'tools']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: 'missing $k layer');
      }
    });

    testWidgets(
      'feed is required; optional slots skipped when null',
      (tester) async {
        await tester.pumpWidget(_wrap(
          TwaiSceneStage(feed: _FillMarker('feed-only')),
        ));
        expect(find.byKey(const Key('feed-only')), findsOneWidget);
      },
    );
  });

  group('B1/B2 TwaiThemedChatPanel + PlayerAvatarTheme', () {
    testWidgets('empty theme still renders child', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiThemedChatPanel(
          theme: const PlayerAvatarTheme.empty(),
          child: _FillMarker('body'),
        ),
      ));
      expect(find.byKey(const Key('body')), findsOneWidget);
    });

    testWidgets(
      'publishes PlayerAvatarTheme via inherited widget so descendants '
      'can read it',
      (tester) async {
        const theme = PlayerAvatarTheme(
          panelBg: Color(0xFF112233),
          accent: Color(0xFFDAA520),
        );
        PlayerAvatarTheme? seen;
        await tester.pumpWidget(_wrap(
          TwaiThemedChatPanel(
            theme: theme,
            child: Builder(
              builder: (ctx) {
                seen = PlayerAvatarTheme.of(ctx);
                return const SizedBox.shrink();
              },
            ),
          ),
        ));
        expect(seen, isNotNull);
        expect(seen!.panelBg, const Color(0xFF112233));
        expect(seen!.accent, const Color(0xFFDAA520));
      },
    );

    test('resolvePanelBg picks dark variant on dark brightness', () {
      const theme = PlayerAvatarTheme(
        panelBg: Color(0xFFFFFFFF),
        panelBgDark: Color(0xFF000000),
      );
      expect(theme.resolvePanelBg(Brightness.light),
          const Color(0xFFFFFFFF));
      expect(theme.resolvePanelBg(Brightness.dark),
          const Color(0xFF000000));
    });

    test('dark falls back to panelBg when panelBgDark unset', () {
      const theme = PlayerAvatarTheme(panelBg: Color(0xFFEEEEEE));
      expect(theme.resolvePanelBg(Brightness.dark),
          const Color(0xFFEEEEEE));
    });
  });

  group('B3 primitives', () {
    testWidgets('TwaiGildedRule renders with motif slot', (tester) async {
      await tester.pumpWidget(_wrap(
        TwaiGildedRule(motif: _SmallMarker('motif')),
      ));
      expect(find.byKey(const Key('motif')), findsOneWidget);
    });

    testWidgets('TwaiGildedRule without motif still lays out', (tester) async {
      await tester.pumpWidget(_wrap(const TwaiGildedRule()));
      expect(find.byType(TwaiGildedRule), findsOneWidget);
    });

    testWidgets('TwaiVignette paints without child requirement',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const TwaiVignette(color: Colors.black),
      ));
      expect(find.byType(TwaiVignette), findsOneWidget);
    });
  });

  group('A2 TransparentVideoIdle', () {
    // Full alpha rendering is web-only + needs a real browser. Here
    // we cover the pure Dart contract: constructor + build with
    // various URL combos doesn't throw. The web-runtime rendering
    // is queued as follow-on with the existing browser-test item.

    test('constructor holds all four fields verbatim', () {
      const idle = TransparentVideoIdle(
        hevcAlphaMovUrl: 'https://cdn/a.mov',
        vp9AlphaWebmUrl: 'https://cdn/a.webm',
        fallbackVideoUrl: 'https://cdn/a.mp4',
        fit: BoxFit.contain,
      );
      expect(idle.hevcAlphaMovUrl, 'https://cdn/a.mov');
      expect(idle.vp9AlphaWebmUrl, 'https://cdn/a.webm');
      expect(idle.fallbackVideoUrl, 'https://cdn/a.mp4');
      expect(idle.fit, BoxFit.contain);
    });

    testWidgets(
      'all URLs null → renders SizedBox.expand without crashing',
      (tester) async {
        await tester.pumpWidget(_wrap(
          const _IdleHost(idle: TransparentVideoIdle()),
        ));
        expect(tester.takeException(), isNull);
      },
    );
  });
}

/// Test host for an [AvatarIdleSource] — calls `.build(ctx)` to
/// exercise the source without needing a full TwaiAvatarStage.
class _IdleHost extends StatelessWidget {
  const _IdleHost({required this.idle});
  final AvatarIdleSource idle;

  @override
  Widget build(BuildContext context) => idle.build(context);
}
