// TwaiKeyboardShortcutsOverlay — wraps a child with a keyboard
// shortcut system + `/`-triggered help sheet. Web + desktop only —
// mobile builds are pass-through no-ops (no physical keyboard
// assumption).
//
// Consumer builds the shortcut list, this widget hosts the Focus +
// Shortcuts + Actions plumbing and renders the help overlay when the
// help trigger fires.
//
// Ported from Penthouse's shortcut layer; keeps Mason's default map
// (Cmd/Ctrl+Shift+D → debug, m → immersive, o → outfits, / → help)
// available via [TwaiKeyboardShortcutsOverlay.masonDefaults].

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One keyboard shortcut — a key combination + a label + description +
/// the callback to invoke when it fires.
class TwaiShortcut {
  final ShortcutActivator activator;
  final String label;
  final String description;
  final VoidCallback onPressed;

  const TwaiShortcut({
    required this.activator,
    required this.label,
    required this.description,
    required this.onPressed,
  });
}

class TwaiKeyboardShortcutsOverlay extends StatefulWidget {
  /// The subtree that inherits the shortcuts.
  final Widget child;

  /// User-facing shortcuts. Each fires [TwaiShortcut.onPressed] when the
  /// [activator] matches a key event and no text field is focused. The
  /// help sheet enumerates these with their labels + descriptions.
  final List<TwaiShortcut> shortcuts;

  /// Key combo that toggles the help sheet. Default `/` (matches
  /// Mason's convention).
  final ShortcutActivator helpTrigger;

  /// Title shown at the top of the help sheet.
  final String helpTitle;

  /// If true, render the widget as a pass-through on mobile (no
  /// keyboard assumption). Default true — desktop + web mount the full
  /// shortcuts stack; iOS/Android skip it.
  final bool disableOnMobile;

  const TwaiKeyboardShortcutsOverlay({
    super.key,
    required this.child,
    required this.shortcuts,
    this.helpTrigger = const SingleActivator(LogicalKeyboardKey.slash),
    this.helpTitle = 'Keyboard Shortcuts',
    this.disableOnMobile = true,
  });

  /// Mason's default shortcut map — descriptions only, no callbacks.
  /// Consumer passes their own callbacks by copy-constructing each
  /// entry via `TwaiShortcut(..., onPressed: myFn)`.
  static List<({String label, String description, ShortcutActivator activator})>
      get masonDefaults => [
            (
              activator: const SingleActivator(
                LogicalKeyboardKey.keyD,
                shift: true,
                control: true,
              ),
              label: 'Ctrl+Shift+D',
              description: 'Toggle debug overlay',
            ),
            (
              activator: const SingleActivator(LogicalKeyboardKey.keyM),
              label: 'M',
              description: 'Toggle immersive mode',
            ),
            (
              activator: const SingleActivator(LogicalKeyboardKey.keyO),
              label: 'O',
              description: 'Show outfits picker',
            ),
            (
              activator: const SingleActivator(LogicalKeyboardKey.slash),
              label: '/',
              description: 'Show this help overlay',
            ),
          ];

  @override
  State<TwaiKeyboardShortcutsOverlay> createState() =>
      _TwaiKeyboardShortcutsOverlayState();
}

class _TwaiKeyboardShortcutsOverlayState
    extends State<TwaiKeyboardShortcutsOverlay> {
  bool _helpVisible = false;

  bool get _isMobile {
    if (kIsWeb) return false;
    final p = defaultTargetPlatform;
    return p == TargetPlatform.iOS || p == TargetPlatform.android;
  }

  void _toggleHelp() {
    setState(() => _helpVisible = !_helpVisible);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.disableOnMobile && _isMobile) {
      return widget.child;
    }

    // Build shortcut map: each user shortcut + the help trigger.
    final shortcuts = <ShortcutActivator, Intent>{
      _NonEditingShortcutActivator(widget.helpTrigger):
          const _ToggleHelpIntent(),
      for (final s in widget.shortcuts)
        _NonEditingShortcutActivator(s.activator): _InvokeIntent(s.onPressed),
    };

    return Actions(
      actions: {
        _ToggleHelpIntent: CallbackAction<_ToggleHelpIntent>(
          onInvoke: (_) {
            _toggleHelp();
            return null;
          },
        ),
        _InvokeIntent: CallbackAction<_InvokeIntent>(
          onInvoke: (intent) {
            intent.callback();
            return null;
          },
        ),
      },
      child: Shortcuts(
        shortcuts: shortcuts,
        child: Focus(
          autofocus: true,
          child: Stack(children: [
            widget.child,
            if (_helpVisible)
              Positioned.fill(
                child: _HelpOverlay(
                  title: widget.helpTitle,
                  shortcuts: widget.shortcuts,
                  helpTrigger: widget.helpTrigger,
                  onDismiss: _toggleHelp,
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Delegates to [activator] unless focus is currently inside an editor.
///
/// This gate belongs in the activator rather than the action callback. Once a
/// shortcut action is invoked, Flutter has already consumed the key event and
/// the focused [EditableText] never receives the character.
class _NonEditingShortcutActivator implements ShortcutActivator {
  final ShortcutActivator activator;

  const _NonEditingShortcutActivator(this.activator);

  @override
  Iterable<LogicalKeyboardKey>? get triggers => activator.triggers;

  @override
  String debugDescribeKeys() => activator.debugDescribeKeys();

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editing = focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);
    return !editing && activator.accepts(event, state);
  }
}

class _ToggleHelpIntent extends Intent {
  const _ToggleHelpIntent();
}

class _InvokeIntent extends Intent {
  final VoidCallback callback;
  const _InvokeIntent(this.callback);
}

class _HelpOverlay extends StatelessWidget {
  final String title;
  final List<TwaiShortcut> shortcuts;
  final ShortcutActivator helpTrigger;
  final VoidCallback onDismiss;
  const _HelpOverlay({
    required this.title,
    required this.shortcuts,
    required this.helpTrigger,
    required this.onDismiss,
  });

  String _labelFor(ShortcutActivator a) {
    if (a is SingleActivator) {
      final parts = <String>[];
      if (a.control) parts.add('Ctrl');
      if (a.meta) parts.add('Cmd');
      if (a.shift) parts.add('Shift');
      if (a.alt) parts.add('Alt');
      parts.add(a.trigger.keyLabel);
      return parts.join('+');
    }
    return a.toString();
  }

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.65),
        child: GestureDetector(
          onTap: onDismiss,
          child: Center(
            child: GestureDetector(
              onTap: () {}, // absorb inner taps
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF12141B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF2A2F3D)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Color(0xFFE8ECF4),
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close,
                              color: Color(0xFF8B93A6)),
                          onPressed: onDismiss,
                        ),
                      ]),
                      const SizedBox(height: 12),
                      for (final s in shortcuts)
                        _shortcutRow(s.label, s.description),
                      const Divider(color: Color(0xFF2A2F3D)),
                      _shortcutRow(_labelFor(helpTrigger),
                          'Toggle this overlay (this shortcut)'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _shortcutRow(String label, String description) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1E28),
              border: Border.all(color: const Color(0xFF2A2F3D)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFFFEE00),
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(
                  color: Color(0xFFE8ECF4), fontSize: 13),
            ),
          ),
        ]),
      );
}
