import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralocal/main.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dsp = MethodChannel('auralocal/native_dsp');
  const refs = MethodChannel('auralocal/file_references');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(dsp, (call) async {
        if (call.method == 'getState') return <String, dynamic>{};
        return null;
      });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(refs, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(dsp, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(refs, null);
  });

  testWidgets('last song remains in library after opening and dismissing player', (tester) async {
    await tester.view.setPhysicalSize(const Size(390, 844));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: app.MusicPage()));
    final state = tester.state(find.byType(app.MusicPage)) as dynamic;
    state.setState(() {
      state.files.clear();
      state.files.addAll(List.generate(7, (i) => '/tmp/AuraTrack${i + 1}.flac'));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('7 songs'), findsOneWidget);
    await tester.ensureVisible(find.text('AuraTrack7'));
    await tester.tap(find.text('AuraTrack7'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('AuraTrack7'), findsWidgets);
    await tester.tap(find.byTooltip('Minimize player'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('7 songs'), findsOneWidget);
    expect(find.text('All songs'), findsOneWidget);
    expect(find.text('AuraTrack7'), findsWidgets);
    expect(find.byTooltip('Sort tracks'), findsOneWidget);
    expect(find.byTooltip('Song options'), findsNWidgets(7));
    expect(tester.takeException(), isNull);
  });
}
