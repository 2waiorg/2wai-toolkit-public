import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

void main() {
  testWidgets('bare shortcuts do not fire while a text field has focus',
      (tester) async {
    var shortcutCalls = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: TwaiKeyboardShortcutsOverlay(
        disableOnMobile: false,
        shortcuts: [
          TwaiShortcut(
            activator: const SingleActivator(LogicalKeyboardKey.keyO),
            label: 'O',
            description: 'Outfits',
            onPressed: () => shortcutCalls++,
          ),
        ],
        child: Scaffold(
          body: Column(children: [
            TextField(controller: controller),
            const Text('outside'),
          ]),
        ),
      ),
    ));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();
    expect(shortcutCalls, 0);
  });

  testWidgets('bare shortcuts still fire outside a text editor',
      (tester) async {
    var shortcutCalls = 0;
    final outsideFocus = FocusNode();
    addTearDown(outsideFocus.dispose);

    await tester.pumpWidget(MaterialApp(
      home: TwaiKeyboardShortcutsOverlay(
        disableOnMobile: false,
        shortcuts: [
          TwaiShortcut(
            activator: const SingleActivator(LogicalKeyboardKey.keyO),
            label: 'O',
            description: 'Outfits',
            onPressed: () => shortcutCalls++,
          ),
        ],
        child: Scaffold(
          body: Focus(
            focusNode: outsideFocus,
            child: const Text('outside'),
          ),
        ),
      ),
    ));

    outsideFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();
    expect(shortcutCalls, 1);
  });
}
