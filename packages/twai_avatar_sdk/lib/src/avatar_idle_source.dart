import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'transparent_video_idle_impl.dart' as tvi;

/// What the avatar looks like when nothing is being spoken —
/// pre-first-turn (from WS connect until the first reply) and between
/// turns (from turn-end until the next reply arrives). Customer supplies
/// this to [TwaiAvatarStage]; the SDK's sink handles the state-machine
/// swap between idle and speaking automatically.
///
/// Concrete choices (pick one):
///
/// - [AssetVideoIdle] — bundled MP4 (e.g. `Krystal_Idle1.mp4`),
///   looped, muted. Best UX; matches what the wire sends. Requires
///   an asset in the app's `pubspec.yaml`.
/// - [NetworkVideoIdle] — MP4 from an HTTP URL. Same UX as
///   [AssetVideoIdle] without needing to bundle assets. Adds one
///   network fetch on first launch.
/// - [AssetPosterIdle] — bundled still image. Faster load than
///   video; less alive-looking (no breathing motion).
/// - [NetworkPosterIdle] — image from URL. Zero bundling required;
///   good default when the customer has neither video nor bundled
///   assets ready.
/// - [SolidColorIdle] — filled color, no character. Diagnostic /
///   placeholder-only use.
/// - [NoIdle] — renders transparent. Use when the caller layers its
///   own custom idle widget behind the [TwaiAvatarStage] via a
///   `Stack`.
///
/// Every source is a value type (immutable, const-constructible where
/// possible). The corresponding widget lifecycle (video controller
/// init / dispose, image caching) is handled internally when the
/// source is placed in the tree.
sealed class AvatarIdleSource {
  const AvatarIdleSource();

  /// Build the widget the sink renders during idle time. Called from
  /// the sink's `placeholderBuilder` — the concrete subclass owns any
  /// stateful lifecycle (video controller etc.).
  Widget build(BuildContext context);
}

/// Looping muted MP4 bundled with the app.
///
/// ```dart
/// AssetVideoIdle('assets/RedJesus/Idles/RedJesus_Idle1.mp4')
/// ```
class AssetVideoIdle extends AvatarIdleSource {
  const AssetVideoIdle(
    this.assetPath, {
    this.fit = BoxFit.contain,
    this.package,
  });

  /// Asset key as declared in the consuming app's `pubspec.yaml`.
  final String assetPath;

  /// How the video fills the parent. [BoxFit.cover] (default) is what
  /// full-screen avatar UX usually wants — small crop is fine, seams
  /// with wire content are minimized. Use [BoxFit.contain] to letterbox
  /// if aspect ratios differ significantly.
  final BoxFit fit;

  /// Optional Flutter asset-package resolution (for asset paths that
  /// live inside a `package:` — rare for avatar assets, common for
  /// SDK-bundled defaults).
  final String? package;

  @override
  Widget build(BuildContext context) => _LoopingVideoIdle(
        source: _VideoIdleSource.asset(assetPath, package: package),
        fit: fit,
      );
}

/// Looping muted MP4 fetched from an HTTP(S) URL.
class NetworkVideoIdle extends AvatarIdleSource {
  const NetworkVideoIdle(this.url, {this.fit = BoxFit.contain});

  final Uri url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => _LoopingVideoIdle(
        source: _VideoIdleSource.network(url),
        fit: fit,
      );
}

/// Static bundled image (JPG / PNG / WebP).
class AssetPosterIdle extends AvatarIdleSource {
  const AssetPosterIdle(
    this.assetPath, {
    this.fit = BoxFit.contain,
    this.package,
  });

  final String assetPath;
  final BoxFit fit;
  final String? package;

  @override
  Widget build(BuildContext context) => Image.asset(
        assetPath,
        package: package,
        fit: fit,
        gaplessPlayback: true,
      );
}

/// Static image from an HTTP(S) URL.
class NetworkPosterIdle extends AvatarIdleSource {
  const NetworkPosterIdle(this.url, {this.fit = BoxFit.contain});

  final Uri url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => Image.network(
        url.toString(),
        fit: fit,
        gaplessPlayback: true,
      );
}

/// Solid color. Diagnostic — use when there's genuinely no asset and
/// no better idle available.
class SolidColorIdle extends AvatarIdleSource {
  const SolidColorIdle(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => ColoredBox(color: color);
}

/// Renders as a transparent parent-sized box. Use when the app draws
/// its own idle content behind the [TwaiAvatarStage] via `Stack`, and
/// wants the SDK's placeholder slot to simply not obstruct.
class NoIdle extends AvatarIdleSource {
  const NoIdle();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// Looping muted MP4 with **transparent background** — the avatar
/// composites over whatever's behind it. Absorbed from 2wai-edu's
/// dual-format alpha-video approach (see `reference_2wai_edu_repo.md`
/// §A2).
///
/// # Format selection
///
/// The browser picks the first source it can decode with alpha:
///
/// - **`hevcAlphaMovUrl`** — HEVC+alpha `.mov`. Safari 13+ on macOS /
///   iOS. Chrome and Firefox reject; browser moves on.
/// - **`vp9AlphaWebmUrl`** — VP9+alpha `.webm`. Chrome / Firefox /
///   Edge. Safari rejects.
/// - **`fallbackVideoUrl`** — plain opaque MP4 as last-resort so the
///   element still renders something on browsers that can't decode
///   either alpha format. Also the source used on non-web builds
///   (see below).
///
/// # Platform behavior
///
/// - **Web** — real alpha compositing via `HtmlElementView` +
///   `<video>` with the source list above. Transparent pixels show
///   whatever's beneath the platform view (typically the plate layer
///   of a [TwaiSceneStage]).
/// - **Non-web (iOS / Android / Windows / macOS / Linux)** — Flutter's
///   `video_player` doesn't currently expose an alpha-aware
///   compositing path, so the fallback URL renders opaquely. When a
///   reliable native alpha-video plugin lands, this degrades in place
///   without an API change.
///
/// # Use it with [TwaiSceneStage]
///
/// The pairing is:
///
/// ```dart
/// TwaiSceneStage(
///   plate: Image.network(sceneBackdropUrl),
///   feed: TwaiPlayer(controller: handle, idleSource: TransparentVideoIdle(
///     hevcAlphaMovUrl: 'https://.../avatar_idle.mov',
///     vp9AlphaWebmUrl: 'https://.../avatar_idle.webm',
///     fallbackVideoUrl: 'https://.../avatar_idle.mp4',
///   )),
/// )
/// ```
///
/// Either alpha URL may be omitted independently; the resolver just
/// skips it. Providing only [fallbackVideoUrl] is equivalent to
/// [NetworkVideoIdle] (opaque everywhere) — useful when a customer
/// hasn't produced alpha bakes yet.
class TransparentVideoIdle extends AvatarIdleSource {
  const TransparentVideoIdle({
    this.hevcAlphaMovUrl,
    this.vp9AlphaWebmUrl,
    this.fallbackVideoUrl,
    this.fit = BoxFit.cover,
  });

  /// HEVC + alpha `.mov` URL (Safari/iOS). Skipped when null/empty.
  final String? hevcAlphaMovUrl;

  /// VP9 + alpha `.webm` URL (Chrome/Firefox/Edge). Skipped when null/empty.
  final String? vp9AlphaWebmUrl;

  /// Plain opaque MP4 URL — last-resort on browsers that can't decode
  /// either alpha format, and the only source used on non-web builds.
  /// Skipped when null/empty (renders as transparent [SizedBox.expand]).
  final String? fallbackVideoUrl;

  /// Fit for the video within the parent bounds. [BoxFit.cover] is
  /// the natural default for avatar idles; use [BoxFit.contain] to
  /// letterbox if the scene demands it.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => tvi.buildTransparentVideoIdle(
        hevcAlphaMovUrl: hevcAlphaMovUrl,
        vp9AlphaWebmUrl: vp9AlphaWebmUrl,
        fallbackVideoUrl: fallbackVideoUrl,
        fit: fit,
      );
}

// ── Internals ──────────────────────────────────────────────────────

/// Discriminator for the two video sources (asset vs network) so
/// [_LoopingVideoIdle] can dispatch to the right VideoPlayerController
/// factory without duplicating the widget.
class _VideoIdleSource {
  const _VideoIdleSource.asset(this.assetPath, {this.package})
      : url = null,
        isAsset = true;
  const _VideoIdleSource.network(this.url)
      : assetPath = null,
        package = null,
        isAsset = false;

  final String? assetPath;
  final String? package;
  final Uri? url;
  final bool isAsset;

  VideoPlayerController createController() {
    if (isAsset) {
      return VideoPlayerController.asset(assetPath!, package: package);
    }
    return VideoPlayerController.networkUrl(url!);
  }

  /// Stable identity for widget diffing — if two [_LoopingVideoIdle]
  /// have the same key, we don't rebuild the controller.
  Object get key => isAsset ? 'asset:${package ?? ""}:$assetPath' : 'net:$url';
}

/// Manages a [VideoPlayerController] for a looping, muted idle clip.
/// Rebuilds the controller when [source]'s key changes (e.g., mode swap
/// from Jesus idle to Krystal idle).
class _LoopingVideoIdle extends StatefulWidget {
  const _LoopingVideoIdle({required this.source, required this.fit});
  final _VideoIdleSource source;
  final BoxFit fit;

  @override
  State<_LoopingVideoIdle> createState() => _LoopingVideoIdleState();
}

class _LoopingVideoIdleState extends State<_LoopingVideoIdle> {
  VideoPlayerController? _controller;
  Object? _initializedKey;

  @override
  void initState() {
    super.initState();
    _init(widget.source);
  }

  @override
  void didUpdateWidget(covariant _LoopingVideoIdle old) {
    super.didUpdateWidget(old);
    if (widget.source.key != old.source.key) {
      _disposeController();
      _init(widget.source);
    }
  }

  Future<void> _init(_VideoIdleSource src) async {
    final c = src.createController();
    final targetKey = src.key;
    try {
      await c.initialize();
    } catch (e, st) {
      // We always degrade to a transparent placeholder — the sink's
      // default black shows through — so a broken idle never crashes
      // the whole avatar stage. But silent degradation is a debugging
      // trap: consumers see a black pane with no error and can't
      // distinguish "URL wrong" from "asset missing" from the plugin-
      // registrant cache trap below. Surface enough to diagnose without
      // spamming production logs.
      final msg = e.toString();
      final isMissingPlugin = msg.contains('MissingPluginException') ||
          msg.contains('No implementation found') ||
          msg.contains('videoPlayer');
      if (isMissingPlugin) {
        // Distinctive, actionable error for the most common consumer
        // trap: adding twai_avatar_sdk_video_player to an existing
        // Flutter app whose incremental-build cache reused a stale
        // web_plugin_registrant.dart from before the dep was added.
        // Symptom: black idle pane, no error in the browser console,
        // idle URL request never fires. Fix is one command; without
        // this print, diagnosis takes ~90 min (Lumara post-mortem
        // 2026-08-08).
        FlutterError.reportError(FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'twai_avatar_sdk / AvatarIdleSource',
          context: ErrorDescription(
            'video_player plugin not registered when initializing '
            "the idle video. This almost always means Flutter's "
            'incremental build cache reused a stale plugin '
            'registrant from before twai_avatar_sdk_video_player '
            'was added to pubspec.yaml.\n\n'
            'Fix: run `flutter clean` then rebuild. If the problem '
            'persists after a clean rebuild, verify '
            'twai_avatar_sdk_video_player is listed under '
            'dependencies: in pubspec.yaml (transitive dep is not '
            'enough — the plugin registrant only enumerates '
            'direct deps).',
          ),
        ));
      } else {
        // Any other failure: bundled asset key wrong, network URL 404 /
        // CORS blocked, codec unsupported by the platform. Print at
        // debug level so the customer sees it during dev but the app
        // still runs. Same graceful degradation as before.
        debugPrint(
          '[twai_avatar_sdk] idle video initialize() failed: $e '
          '(source=${src.key}). Falling back to transparent placeholder.',
        );
      }
      await c.dispose();
      return;
    }
    if (!mounted || _initializedKey != null && _initializedKey != targetKey) {
      await c.dispose();
      return;
    }
    await c.setLooping(true);
    await c.setVolume(0);
    await c.play();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() {
      _controller = c;
      _initializedKey = targetKey;
    });
  }

  void _disposeController() {
    // ignore: discarded_futures
    _controller?.dispose();
    _controller = null;
    _initializedKey = null;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      // No visible chrome — just fill parent. The avatar stage sits
      // behind everything so a brief transparent moment is fine; the
      // customer's own scaffold background shows through if any.
      return const SizedBox.expand();
    }
    // BoxFit.cover is the natural default — the sink's video will
    // render on top with its own fit, and we want the idle to fill
    // whatever real estate the stage has without letterboxing between
    // idle and speaking states.
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}

// Silence unused-import lint on non-web builds where kIsWeb isn't
// exercised in a branch. Kept import so a future web-specific idle
// (e.g. HTML <video> autoplay-muted fallback) can drop in without
// wire-up.
// ignore: unused_element
bool get _kIsWebAcknowledged => kIsWeb;
