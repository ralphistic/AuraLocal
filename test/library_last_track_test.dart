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
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: app.MusicPage()));
    final state = tester.state(find.byType(app.MusicPage)) as dynamic;
    state.setState(() {
      state.files.clear();
      // Exact eight-song order and titles from the user's exported library.
      // Dates mirror AuraLocal-Library-Backup.zip (2026-10-15).
      const names = <String>[
        'Castle Boss Battle SMW Remaster_12.wav',
        'Lost Ancient Ruins VRC6_11.flac',
        'FF4 Battle 2 8Bit.wav',
        '1-01. Hyrule Castle.flac',
        '06. Majestic Castle.flac',
        '09 - Violent Breathing (1).mp3',
        'BowserCastle.mp3',
        '12. Rainbow Road.flac',
      ];
      const dates = <int>[
        1791859375464, 1791881227939, 1791898408738,
        1791905856256, 1791908133268, 1791941811601,
        1791948961459, 1792038089197,
      ];
      state.files.addAll(names.map((name) => 'C:/Documents/Music/$name'));
      state.sortMode = 'dateAdded';
      state.sortAscending = false;
      for (var i = 0; i < names.length; i++) {
        state.dateAdded['C:/Documents/Music/${names[i]}'] = dates[i];
      }
      state.originalNames['C:/Documents/Music/Castle Boss Battle SMW Remaster_12.wav'] =
          'Castle Boss Battle SMW Remaster.wav';
      state.trackMetadata['Music/Castle Boss Battle SMW Remaster_12.wav'] =
          <String, String>{'title': 'Castle Boss Battle SMW Remaster', 'releaseDate': '2019-09-05'};
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('8 songs'), findsOneWidget);
    await tester.ensureVisible(find.text('Castle Boss Battle SMW Remaster'));
    await tester.tap(find.text('Castle Boss Battle SMW Remaster'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Castle Boss Battle SMW Remaster'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Minimize player'), findsOneWidget);
    await tester.tap(find.byTooltip('Minimize player'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('8 songs'), findsOneWidget);
    expect(find.text('All songs'), findsOneWidget);
    expect(find.text('Castle Boss Battle SMW Remaster'), findsWidgets);
    expect(find.byTooltip('Sort tracks'), findsOneWidget);
    expect(find.byTooltip('Song options'), findsNWidgets(8));
    // Verify actual geometry, not just retained widget/state existence.
    final list = find.byType(ListView).first;
    final listSize = tester.getSize(list);
    final listTop = tester.getTopLeft(list);
    expect(listSize.width, greaterThan(300));
    expect(listSize.height, greaterThan(100));
    expect(listTop.dx, greaterThanOrEqualTo(0));
    expect(listTop.dy, greaterThan(0));
    final lastRow = find.text('Castle Boss Battle SMW Remaster');
    await tester.ensureVisible(lastRow.first);
    await tester.pump();
    expect(tester.getSize(lastRow.first).width, greaterThan(0));
    // The real failure recurs after toggling the last song's metadata.
    // Exercise both states repeatedly, not only one successful collapse.
    for (var cycle = 0; cycle < 3; cycle++) {
      state.setState(() {
        final key = 'Music/Castle Boss Battle SMW Remaster_12.wav';
        if (cycle.isEven) {
          state.trackMetadata.remove(key);
        } else {
          state.trackMetadata[key] = <String, String>{
            'title': 'Castle Boss Battle SMW Remaster',
          };
        }
      });
      await tester.pump(const Duration(milliseconds: 100));
      // Re-enter the full player deterministically: the same title appears
      // in both the library and MiniPlayer, so tapping the first text finder
      // can hit the wrong surface and never open the player.
      state.setState(() => state.currentIndex = 0);
      state.showPlayer();
      // First pump starts the animation ticker; the following pump advances it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('Minimize player'), findsOneWidget);
      await tester.tap(find.byTooltip('Minimize player'), warnIfMissed: false);
      // Start the reverse animation, then allow its completion callback to
      // restore libraryHome before asserting the library's geometry.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(state.libraryHome, isTrue);
      expect(find.text('8 songs'), findsOneWidget);
      expect(find.byTooltip('Song options'), findsNWidgets(8));
      expect(tester.getSize(find.byType(ListView).first).height, greaterThan(100));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('both affected tracks preserve library through player expansion and collapse', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: app.MusicPage()));
    final state = tester.state(find.byType(app.MusicPage)) as dynamic;
    const castle = 'Castle Boss Battle SMW Remaster_12.wav';
    const bulby = 'Mario Circuit 8bit Remix - Bulby.mp3';
    state.setState(() {
      state.files.clear();
      state.files.addAll(<String>['C:/Documents/Music/$castle',
        'C:/Documents/Music/Lost Ancient Ruins VRC6_11.flac',
        'C:/Documents/Music/$bulby']);
      state.sortMode = 'dateAdded';
      state.sortAscending = false;
      state.dateAdded['C:/Documents/Music/$castle'] = 1791859375464;
      state.dateAdded['C:/Documents/Music/Lost Ancient Ruins VRC6_11.flac'] = 1791881227939;
      state.dateAdded['C:/Documents/Music/$bulby'] = 1792039000000;
    });
    await tester.pump();
    expect(find.text('3 songs'), findsOneWidget);
    var _bulbyVariant = 0;
    for (final selected in <int>[0, 2, 2, 2, 2, 2]) {
      // Metadata matrix: no tags, title/artist, extra text fields, artwork
      // without extra fields, and artwork with extra fields. The exact Bulby
      // online metadata is not available, so these are synthetic variants.
      final variant = selected == 0 ? 0 : _bulbyVariant++;
      final selectedPath = state.files[selected] as String;
      final metadataKey = 'Music/${selectedPath.split('/').last}';
      state.setState(() {
        state.currentIndex = selected;
        state.trackMetadata.remove(metadataKey);
        if (selected == 2 && variant > 0) {
          state.trackMetadata[metadataKey] = <String, String>{
            'title': 'Mario Circuit 8bit Remix', 'artist': 'Bulby',
            if (variant == 2 || variant == 4) ...<String, String>{
              'album': 'Mario Circuit', 'releaseDate': '2026',
              'genre': 'Chiptune', 'composer': 'Bulby', 'comments': 'Remix',
            },
            if (variant == 3 || variant == 4)
              'artworkData': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jXioAAAAASUVORK5CYII=',
          };
        }
      });
      state.showPlayer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // The library may be remounted during the transition. A finder can
      // briefly reference a deactivated ListView; don't query its renderObject
      // until the collapse has completed and the element is active again.
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byTooltip('Minimize player'), findsOneWidget);
      await tester.tap(find.byTooltip('Minimize player'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(state.libraryHome, isTrue);
      expect(find.text('3 songs'), findsOneWidget);
      expect(find.byTooltip('Song options'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      // Reproduce the user's recovery path: tap an invisible-but-interactive
      // library row, open the player, change to an unaffected track, collapse.
      state.showPlayer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      state.setState(() => state.currentIndex = 1);
      await tester.pump();
      expect(find.byTooltip('Minimize player'), findsOneWidget);
      await tester.tap(find.byTooltip('Minimize player'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(state.libraryHome, isTrue);
      expect(find.text('3 songs'), findsOneWidget);
      expect(find.byTooltip('Song options'), findsNWidgets(3));
      expect(tester.getSize(find.byType(ListView).first).height, greaterThan(100));
      expect(tester.takeException(), isNull);
    }
  });
}

