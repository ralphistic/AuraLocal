import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auralocal/metadata_art.dart';

void main() {
  testWidgets('missing artwork stays square and flips to metadata options', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(
      width: 270, height: 270,
      child: ArtworkFlipCard(
        trackName: 'Lost Ancient Ruins',
        metadata: const {},
        onSave: (_) async {},
      ),
    )))));
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    final aspect = find.byType(AspectRatio).first;
    final size = tester.getSize(aspect);
    expect(size.width, size.height);
    await tester.tap(aspect);
    await tester.pumpAndSettle();
    expect(find.text('ADD METADATA?'), findsOneWidget);
    expect(find.text('Enter manually'), findsOneWidget);
    expect(find.text('Find online'), findsOneWidget);
  });

  testWidgets('manual metadata editor exposes required fields', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(
      width: 270, height: 270,
      child: ArtworkFlipCard(
        trackName: 'Example',
        metadata: const {},
        onSave: (_) async {},
      ),
    )))));
    await tester.tap(find.byType(AspectRatio).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter manually'));
    await tester.pumpAndSettle();
    expect(find.text('Track metadata'), findsOneWidget);
    expect(find.text('Song title'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Release date'), findsOneWidget);
    expect(find.text('Genre'), findsOneWidget);
    expect(find.text('Track number'), findsOneWidget);
  });
}
