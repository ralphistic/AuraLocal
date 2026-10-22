import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralocal/main.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('lyrics activate at exact line start times', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: app.MusicPage()));
    final state = tester.state(find.byType(app.MusicPage)) as dynamic;
    final lines = <Map<String, dynamic>>[
      {'text': 'First', 'time': 1.250},
      {'text': 'Second', 'time': 2.500},
      {'text': 'Third', 'time': 4.125},
    ];
    expect(state.activeLyricIndex(lines, 1.249), -1);
    expect(state.activeLyricIndex(lines, 1.250), 0);
    expect(state.activeLyricIndex(lines, 2.499), 0);
    expect(state.activeLyricIndex(lines, 2.500), 1);
    expect(state.activeLyricIndex(lines, 4.125), 2);
  });
}
