import 'package:flutter/widgets.dart';

import '../avatar_scene_stage.dart';
import '../cinematic_player.dart';
import 'color_grade.dart';
import 'contact_shadow.dart';
import 'ken_burns.dart';
import 'scene.dart';

/// Imperative handle for switching scenes in a [TwaiSceneNavigator].
/// The app holds one of these + calls [go] to activate a scene by
/// id. Also exposes the current scene via [current] for HUD /
/// diagnostic displays.
///
/// Modeled after `ChangeNotifier` so widgets that need to rebuild
/// when the scene changes can subscribe with an `AnimatedBuilder`
/// (or an app-side `ValueNotifier` bridge).
class TwaiSceneController extends ChangeNotifier {
  TwaiSceneController({required TwaiScene initial}) : _current = initial;

  TwaiScene _current;
  TwaiScene? _pending;

  /// The scene currently rendering — either fully mounted, or the
  /// *outgoing* scene during a transition (transition film covers
  /// it until [notifyTransitionComplete] fires).
  TwaiScene get current => _current;

  /// The scene queued to become active once the transition film
  /// finishes. Null when no transition is in flight.
  TwaiScene? get pending => _pending;

  /// True while [pending] is non-null — i.e. the navigator is
  /// currently playing a transition film. HUD / composer widgets
  /// can watch this to disable input during the film.
  bool get isTransitioning => _pending != null;

  /// Activate the scene with the given [id] (must exist in the
  /// navigator's `scenes` list). Idempotent — a repeat call with
  /// the current id is a no-op.
  ///
  /// Silent no-op when [id] is unknown; callers can pre-validate
  /// with [canGo] if they want to distinguish.
  ///
  /// # Transition behavior
  ///
  /// - Target scene has [TwaiScene.transitionFilmUrl] set →
  ///   [pending] is set, [isTransitioning] flips true, listeners
  ///   notify. The navigator plays the film in its overlay layer;
  ///   when the film ends the navigator calls
  ///   [notifyTransitionComplete] and this controller swaps
  ///   [current] ← [pending] and notifies again.
  /// - Target scene has no film → [current] flips immediately,
  ///   [pending] stays null, hard-cut behavior.
  ///
  /// Calling [go] again while [isTransitioning] REPLACES the
  /// pending target (the current film continues playing to
  /// completion, then lands on the newest target). Useful for
  /// rapid navigation without stacking film playbacks.
  void go(String id, {required List<TwaiScene> from}) {
    if (id == _current.id && !isTransitioning) return;
    for (final s in from) {
      if (s.id == id) {
        if (s.transitionFilmUrl != null && s.transitionFilmUrl!.isNotEmpty) {
          _pending = s;
          notifyListeners();
        } else {
          _current = s;
          _pending = null;
          notifyListeners();
        }
        return;
      }
    }
  }

  /// Called by [TwaiSceneNavigator] when the transition film for
  /// [pending] finishes playing (or errors). Swaps [current] to
  /// [pending] and clears [pending]. Safe to call when no
  /// transition is in flight — no-op in that case.
  void notifyTransitionComplete() {
    final p = _pending;
    if (p == null) return;
    _current = p;
    _pending = null;
    notifyListeners();
  }

  bool canGo(String id, {required List<TwaiScene> from}) {
    for (final s in from) {
      if (s.id == id) return true;
    }
    return false;
  }
}

/// A stateful multi-scene stage — swap between named [scenes] by
/// asking the controller to `.go(id)`. Composes the primitives from
/// [scene_anchor], [color_grade], [contact_shadow], and [ken_burns]
/// into a full stage per scene, using [TwaiSceneStage] under the
/// hood so the layer ordering matches the rest of the SDK.
///
/// # Composition per scene
///
/// - **plate** — the [TwaiScene.plate] widget, wrapped in a
///   [TwaiKenBurnsParallax] when [kenBurns] is enabled.
/// - **atmosphere** — the per-scene [TwaiContactShadow] (when
///   `contactShadowIntensity > 0`).
/// - **feed** — the caller's [feed] widget, positioned per
///   [TwaiScene.anchor], graded per the scene's `grade*` fields.
/// - **overlay** / **tools** — pass through the widget's `overlay` /
///   `tools` slots.
///
/// # State ownership
///
/// - **App owns the controller.** Create + retain it in the parent's
///   State; the navigator subscribes on mount and rebuilds on
///   `notifyListeners`. Not disposed by the navigator — its lifecycle
///   is longer than any one navigator instance.
/// - **Scenes are declared statically** as a list on this widget.
///   Adding a scene = passing a new list; the widget rebuilds
///   cleanly (no scene state is retained beyond the controller).
class TwaiSceneNavigator extends StatefulWidget {
  const TwaiSceneNavigator({
    super.key,
    required this.controller,
    required this.scenes,
    required this.feed,
    this.overlay,
    this.tools,
    this.kenBurns = true,
  });

  final TwaiSceneController controller;
  final List<TwaiScene> scenes;
  final Widget feed;
  final Widget? overlay;
  final Widget? tools;

  /// Whether to wrap the plate in a [TwaiKenBurnsParallax] for slow
  /// parallax motion. Turn off for static backdrops or when the app
  /// runs on constrained hardware.
  final bool kenBurns;

  @override
  State<TwaiSceneNavigator> createState() => _TwaiSceneNavigatorState();
}

class _TwaiSceneNavigatorState extends State<TwaiSceneNavigator> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant TwaiSceneNavigator old) {
    super.didUpdateWidget(old);
    if (widget.controller != old.controller) {
      old.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.controller.current;

    final plate = widget.kenBurns
        ? TwaiKenBurnsParallax(child: scene.plate)
        : scene.plate;

    final grade = TwaiColorGrade(
      brightness: scene.gradeBrightness,
      contrast: scene.gradeContrast,
      saturation: scene.gradeSaturation,
      sepia: scene.gradeSepia,
      hueRotate: scene.gradeHueRotate,
      child: widget.feed,
    );

    final anchor = scene.anchor;
    final anchoredFeed = anchor == null
        ? grade
        : LayoutBuilder(
            builder: (context, constraints) {
              final rect = anchor.resolveIn(constraints.biggest);
              return Stack(
                children: [
                  Positioned(
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    child: grade,
                  ),
                ],
              );
            },
          );

    final atmosphere = scene.contactShadowIntensity > 0
        ? TwaiContactShadow(
            color: scene.contactShadowColor,
            intensity: scene.contactShadowIntensity,
          )
        : null;

    // Transition film — plays IN THE OVERLAY SLOT while a scene
    // switch is in flight (pending scene has transitionFilmUrl).
    // On end, notifyTransitionComplete flips current → pending;
    // widget rebuilds without the film + the new scene is live.
    //
    // Sits above [widget.overlay] semantically: any caller-supplied
    // overlay is stashed beneath the film during the transition, so
    // the transition covers the whole stage until it completes.
    final pending = widget.controller.pending;
    final Widget? overlaySlot;
    if (pending != null && pending.transitionFilmUrl != null) {
      overlaySlot = TwaiCinematicPlayer(
        // Force a fresh video controller per pending scene id so
        // rapid controller.go replaces the running film cleanly
        // (VideoPlayerController does the disposal + init dance
        // when the widget's key changes).
        key: ValueKey('twai-transition-${pending.id}'),
        videoUrl: pending.transitionFilmUrl!,
        // The film is decorative; user shouldn't be able to skip
        // through it and land mid-scene-swap.
        dismissOnTap: false,
        onComplete: widget.controller.notifyTransitionComplete,
      );
    } else {
      overlaySlot = widget.overlay;
    }

    return TwaiSceneStage(
      plate: plate,
      atmosphere: atmosphere,
      feed: anchoredFeed,
      overlay: overlaySlot,
      tools: widget.tools,
    );
  }
}
