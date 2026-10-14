import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralocal/blurred_surfaces.dart';

void main() {
  testWidgets('the entire sheet grab axis follows the finger and blurs', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Builder(builder: (context) => TextButton(
        onPressed: () => showAuraSheet<void>(context: context,
          builder: (_) => const SizedBox(height: 260,
            child: Center(child: Text('Sheet content')))),
        child: const Text('Open sheet'))),
    )));
    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet content'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsWidgets);
    final grab = find.byKey(const Key('aura-sheet-grab-zone'));
    final center = tester.getCenter(grab);
    final width = tester.getSize(grab).width;
    expect(width, greaterThan(300));
    final initial = tester.getTopLeft(find.text('Sheet content')).dy;
    // Starting near the far right edge still grabs the sheet.
    final finger = await tester.startGesture(
      Offset(center.dx + width * 0.40, center.dy));
    await finger.moveBy(const Offset(0, 65));
    await tester.pump();
    expect(tester.getTopLeft(find.text('Sheet content')).dy,
      greaterThan(initial + 40));
    await finger.moveBy(const Offset(0, 85));
    await finger.up();
    await tester.pumpAndSettle();
    expect(find.text('Sheet content'), findsNothing);
  });
}
