import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:avatar_player_lab/lab_shell.dart' show showLabSnack;

void main() {
  testWidgets('lab errors have no action and always auto-dismiss',
      (tester) async {
    late BuildContext scaffoldContext;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          scaffoldContext = context;
          return const SizedBox();
        }),
      ),
    ));

    showLabSnack(scaffoldContext, 'send failed: SessionNotReady', bad: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.persist, isFalse);
    expect(snack.action, isNull);
    expect(find.text('send failed: SessionNotReady'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsNothing);
  });
}
