import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_player/twai_avatar_sdk_player.dart';

/// A stand-in for TwaiAvatarPlayerController — publishes status
/// events on demand + reports currentStatus synchronously. Enough
/// to drive the connection-overlay widget without spinning up a
/// real controller (which needs a session factory + a lot else).
class _FakeStatusController implements TwaiAvatarPlayerController {
  _FakeStatusController(this._status);

  final _c = StreamController<PlayerStatusEvent>.broadcast();
  PlayerStatus _status;

  void set(PlayerStatus s, {Object? cause}) {
    _status = s;
    _c.add(PlayerStatusEvent(status: s, attempt: 0, cause: cause));
  }

  @override
  Stream<PlayerStatusEvent> get status => _c.stream;

  @override
  PlayerStatus get currentStatus => _status;

  void closeStream() => _c.close();

  // Every other TwaiAvatarPlayerController member — the overlay
  // only reads .status + .currentStatus, so we can noSuchMethod the
  // rest. Static analysis is happy because the base class is a
  // regular class, not sealed.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Widget _wrap(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: SizedBox(width: 800, height: 600, child: child),
      ),
    );

void main() {
  group('E1 TwaiConnectionOverlay', () {
    testWidgets(
      'renders connectingBuilder over child while status is connecting',
      (tester) async {
        final ctrl = _FakeStatusController(PlayerStatus.connecting);
        await tester.pumpWidget(_wrap(
          TwaiConnectionOverlay(
            controller: ctrl,
            connectingBuilder: (_) => const Text('CONNECTING',
                textDirection: TextDirection.ltr),
            child: const Text('AVATAR-FEED',
                textDirection: TextDirection.ltr),
          ),
        ));
        expect(find.text('AVATAR-FEED'), findsOneWidget);
        expect(find.text('CONNECTING'), findsOneWidget);
        ctrl.closeStream();
      },
    );

    testWidgets(
      'overlay disappears when status flips to ready',
      (tester) async {
        final ctrl = _FakeStatusController(PlayerStatus.connecting);
        await tester.pumpWidget(_wrap(
          TwaiConnectionOverlay(
            controller: ctrl,
            connectingBuilder: (_) => const Text('CONNECTING',
                textDirection: TextDirection.ltr),
            child: const Text('AVATAR-FEED',
                textDirection: TextDirection.ltr),
          ),
        ));
        expect(find.text('CONNECTING'), findsOneWidget);
        ctrl.set(PlayerStatus.ready);
        await tester.pump(Duration.zero); // flush microtasks
        await tester.pump();
        expect(find.text('CONNECTING'), findsNothing);
        expect(find.text('AVATAR-FEED'), findsOneWidget);
        ctrl.closeStream();
      },
    );

    testWidgets(
      'failedBuilder gets the cause from the status event',
      (tester) async {
        final ctrl = _FakeStatusController(PlayerStatus.connecting);
        Object? seenCause;
        await tester.pumpWidget(_wrap(
          TwaiConnectionOverlay(
            controller: ctrl,
            failedBuilder: (_, cause) {
              seenCause = cause;
              return Text('FAILED: $cause',
                  textDirection: TextDirection.ltr);
            },
            child: const Text('AVATAR-FEED',
                textDirection: TextDirection.ltr),
          ),
        ));
        ctrl.set(PlayerStatus.failed, cause: 'handshake rejected');
        await tester.pump(Duration.zero); // flush microtasks
        await tester.pump();
        expect(seenCause, 'handshake rejected');
        expect(find.textContaining('FAILED'), findsOneWidget);
        ctrl.closeStream();
      },
    );

    testWidgets(
      'silent when builder for current status is null',
      (tester) async {
        final ctrl = _FakeStatusController(PlayerStatus.connecting);
        await tester.pumpWidget(_wrap(
          TwaiConnectionOverlay(
            controller: ctrl,
            // No connectingBuilder → child visible immediately.
            child: const Text('AVATAR-FEED',
                textDirection: TextDirection.ltr),
          ),
        ));
        expect(find.text('AVATAR-FEED'), findsOneWidget);
        ctrl.closeStream();
      },
    );
  });

  group('E2 TwaiCinematicPlayer', () {
    // Real video initialization can't happen in the widget-test
    // environment (video_player needs a platform surface). We cover
    // the surface contract: widget constructs, unmounts cleanly, and
    // the loading state is what renders while init is in flight.

    testWidgets('renders the initialization spinner before init completes',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const TwaiCinematicPlayer(
          videoUrl: 'https://example.invalid/video.mp4',
          background: Colors.black,
        ),
      ));
      // Loading state = the built-in spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('tap fires onComplete when dismissOnTap is on',
        (tester) async {
      var fired = 0;
      await tester.pumpWidget(_wrap(
        TwaiCinematicPlayer(
          videoUrl: 'https://example.invalid/video.mp4',
          onComplete: () => fired++,
        ),
      ));
      await tester.tap(find.byType(TwaiCinematicPlayer));
      expect(fired, 1);
    });

    testWidgets('dismissOnTap=false swallows taps', (tester) async {
      var fired = 0;
      await tester.pumpWidget(_wrap(
        TwaiCinematicPlayer(
          videoUrl: 'https://example.invalid/video.mp4',
          onComplete: () => fired++,
          dismissOnTap: false,
        ),
      ));
      await tester.tap(find.byType(TwaiCinematicPlayer));
      expect(fired, 0);
    });
  });
}
