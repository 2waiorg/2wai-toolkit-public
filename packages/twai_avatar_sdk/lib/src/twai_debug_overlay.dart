// TwaiDebugOverlay — diagnostic on-page HUD, Flutter port of Mason's
// `?diag=1` overlay in c:/Dev/avatar-player/src/main.ts.
//
// Off by default (consumer explicitly enables via TwaiDebugController
// or wraps their app in a TwaiDebugOverlayScope). When enabled:
//
//   - swaps the global `debugPrint` so every print gets captured
//   - installs FlutterError.onError to capture framework errors
//   - installs PlatformDispatcher.instance.onError to capture uncaught
//     async errors
//   - buffers the most recent 100 entries in a ring
//   - exposes the buffer as a reactive stream for widgets to render
//
// The controller is a process-wide singleton — one buffer per app run.
// Multiple TwaiDebugOverlay widgets across the tree all read the same
// buffer, matching Mason's original single-overlay design.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The kind of debug event — drives the row's color badge in the UI.
enum DebugEntryKind {
  info,
  warn,
  error,
  uncaught,
}

/// One line in the ring buffer.
class DebugEntry {
  final DateTime at;
  final DebugEntryKind kind;
  final String message;
  const DebugEntry({
    required this.at,
    required this.kind,
    required this.message,
  });
}

/// Process-wide diagnostic controller. Off by default. Consumers call
/// [enable] to install the captures + start buffering. Widgets subscribe
/// to [changes] and re-render on each entry.
class TwaiDebugController {
  TwaiDebugController._();
  static final TwaiDebugController instance = TwaiDebugController._();

  static const int _maxEntries = 100;

  final Queue<DebugEntry> _entries = Queue();
  final StreamController<void> _changes = StreamController.broadcast();
  bool _enabled = false;
  DebugPrintCallback? _previousDebugPrint;
  FlutterExceptionHandler? _previousOnError;
  bool Function(Object, StackTrace)? _previousPlatformOnError;

  /// Reactive tick — fires on every buffer change (add, clear).
  Stream<void> get changes => _changes.stream;

  /// True when captures are installed and events are being buffered.
  bool get enabled => _enabled;

  /// A read-only snapshot of the current buffer.
  List<DebugEntry> get entries => List.unmodifiable(_entries);

  /// Install global captures. Idempotent — re-enabling seeds fresh init
  /// context (BUILD tag, platform) but doesn't reinstall the captures.
  ///
  /// Pass a [buildTag] to record the shipping app version. Optional
  /// [extraContext] entries are logged after the standard init block.
  void enable({String? buildTag, Map<String, String>? extraContext}) {
    if (!_enabled) {
      _enabled = true;
      _previousDebugPrint = debugPrint;
      debugPrint = _capturedDebugPrint;
      _previousOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        _push(DebugEntryKind.uncaught,
            'FlutterError: ${details.exceptionAsString()}');
        _previousOnError?.call(details);
      };
      _previousPlatformOnError = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stack) {
        _push(DebugEntryKind.uncaught,
            'PlatformError: $error');
        return _previousPlatformOnError?.call(error, stack) ?? false;
      };
    }
    if (buildTag != null) log('BUILD: $buildTag');
    log('PLATFORM: ${defaultTargetPlatform.name}${kIsWeb ? " (web)" : ""}');
    if (extraContext != null) {
      for (final e in extraContext.entries) {
        log('${e.key.toUpperCase()}: ${e.value}');
      }
    }
  }

  /// Uninstall captures and clear the buffer. Restores whichever
  /// debugPrint / FlutterError.onError were installed before enable().
  void disable() {
    if (!_enabled) return;
    _enabled = false;
    debugPrint = _previousDebugPrint ?? debugPrintThrottled;
    FlutterError.onError = _previousOnError;
    PlatformDispatcher.instance.onError = _previousPlatformOnError;
    _previousDebugPrint = null;
    _previousOnError = null;
    _previousPlatformOnError = null;
    clear();
  }

  /// Manually log a line (INFO). Callable when disabled — no-op then.
  void log(String message) => _push(DebugEntryKind.info, message);

  /// Manually record an error line.
  void error(String message) => _push(DebugEntryKind.error, message);

  /// Manually record a warning.
  void warn(String message) => _push(DebugEntryKind.warn, message);

  /// Drop all buffered entries. Kept enabled/disabled state unchanged.
  void clear() {
    _entries.clear();
    _changes.add(null);
  }

  void _push(DebugEntryKind kind, String message) {
    if (!_enabled) return;
    _entries.addLast(DebugEntry(
      at: DateTime.now(),
      kind: kind,
      message: message.length > 400 ? '${message.substring(0, 400)}…' : message,
    ));
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    _changes.add(null);
  }

  void _capturedDebugPrint(String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) {
      final kind = message.startsWith('ERROR')
          ? DebugEntryKind.error
          : message.startsWith('WARN')
              ? DebugEntryKind.warn
              : DebugEntryKind.info;
      _push(kind, message);
    }
    // Chain to the previous debugPrint so console output still happens.
    _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
  }
}

/// Positioning options for the standalone overlay.
enum TwaiDebugOverlayCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Renders the current [TwaiDebugController.instance] buffer as a
/// semi-opaque overlay. Use standalone via [Stack] or via
/// [TwaiDebugOverlayScope] for convenience.
///
/// The overlay is `IgnorePointer`-wrapped by default so it doesn't
/// eat gestures on the underlying app. Set [interactive] true when
/// mounting inside a dev-mode panel where you want scroll + clear.
class TwaiDebugOverlay extends StatefulWidget {
  final double? width;
  final double? height;
  final bool interactive;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BoxDecoration? decoration;

  const TwaiDebugOverlay({
    super.key,
    this.width,
    this.height,
    this.interactive = false,
    this.padding = const EdgeInsets.all(8),
    this.margin = EdgeInsets.zero,
    this.decoration,
  });

  @override
  State<TwaiDebugOverlay> createState() => _TwaiDebugOverlayState();
}

class _TwaiDebugOverlayState extends State<TwaiDebugOverlay> {
  StreamSubscription<void>? _sub;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _sub = TwaiDebugController.instance.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      if (widget.interactive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) return;
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = TwaiDebugController.instance.entries;
    final content = Container(
      width: widget.width,
      height: widget.height,
      padding: widget.padding,
      margin: widget.margin,
      decoration: widget.decoration ??
          BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
      child: entries.isEmpty
          ? const Center(
              child: Text('debug overlay live — no entries yet',
                  style: TextStyle(
                      color: Color(0x99FFFFFF),
                      fontSize: 10,
                      fontFamily: 'monospace')))
          : ListView.builder(
              controller: _scrollCtrl,
              physics: widget.interactive
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              itemCount: entries.length,
              itemBuilder: (_, i) => _EntryRow(entry: entries[i]),
            ),
    );
    return widget.interactive ? content : IgnorePointer(child: content);
  }
}

/// Wraps a child, mounts a floating [TwaiDebugOverlay] in a chosen
/// corner, and calls [TwaiDebugController.instance.enable] on init when
/// [enabled] is true. Convenience for apps that just want "add one line,
/// get Mason's diag overlay."
///
/// ```dart
/// runApp(
///   TwaiDebugOverlayScope(
///     enabled: bool.fromEnvironment('DEV_MODE'),
///     buildTag: 'v0.1',
///     child: MyApp(),
///   ),
/// );
/// ```
class TwaiDebugOverlayScope extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final String? buildTag;
  final Map<String, String>? extraContext;
  final TwaiDebugOverlayCorner corner;
  final double width;
  final double height;
  final EdgeInsets safeInset;

  const TwaiDebugOverlayScope({
    super.key,
    required this.child,
    this.enabled = true,
    this.buildTag,
    this.extraContext,
    this.corner = TwaiDebugOverlayCorner.topRight,
    this.width = 320,
    this.height = 200,
    this.safeInset = const EdgeInsets.all(12),
  });

  @override
  State<TwaiDebugOverlayScope> createState() => _TwaiDebugOverlayScopeState();
}

class _TwaiDebugOverlayScopeState extends State<TwaiDebugOverlayScope> {
  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      TwaiDebugController.instance.enable(
        buildTag: widget.buildTag,
        extraContext: widget.extraContext,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Stack(children: [
      widget.child,
      Positioned(
        top: widget.corner == TwaiDebugOverlayCorner.topLeft ||
                widget.corner == TwaiDebugOverlayCorner.topRight
            ? widget.safeInset.top
            : null,
        bottom: widget.corner == TwaiDebugOverlayCorner.bottomLeft ||
                widget.corner == TwaiDebugOverlayCorner.bottomRight
            ? widget.safeInset.bottom
            : null,
        left: widget.corner == TwaiDebugOverlayCorner.topLeft ||
                widget.corner == TwaiDebugOverlayCorner.bottomLeft
            ? widget.safeInset.left
            : null,
        right: widget.corner == TwaiDebugOverlayCorner.topRight ||
                widget.corner == TwaiDebugOverlayCorner.bottomRight
            ? widget.safeInset.right
            : null,
        child: TwaiDebugOverlay(
          width: widget.width,
          height: widget.height,
        ),
      ),
    ]);
  }
}

class _EntryRow extends StatelessWidget {
  final DebugEntry entry;
  const _EntryRow({required this.entry});

  static Color _colorFor(DebugEntryKind k) => switch (k) {
        DebugEntryKind.info => const Color(0xFF41E3A0),
        DebugEntryKind.warn => const Color(0xFFFFB74A),
        DebugEntryKind.error => const Color(0xFFFF5A6E),
        DebugEntryKind.uncaught => const Color(0xFFFF5A6E),
      };

  static String _labelFor(DebugEntryKind k) => switch (k) {
        DebugEntryKind.info => 'INF ',
        DebugEntryKind.warn => 'WRN ',
        DebugEntryKind.error => 'ERR ',
        DebugEntryKind.uncaught => 'UNC ',
      };

  @override
  Widget build(BuildContext context) {
    final t = entry.at;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    final color = _colorFor(entry.kind);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: DefaultTextStyle(
        style: const TextStyle(
            color: Colors.white,
            fontFamily: 'monospace',
            fontSize: 10,
            height: 1.3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$hh:$mm:$ss.$ms',
              style: const TextStyle(color: Color(0x99FFFFFF))),
          const SizedBox(width: 6),
          Text(_labelFor(entry.kind),
              style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5)),
          Expanded(child: Text(entry.message)),
        ]),
      ),
    );
  }
}
