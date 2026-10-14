import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'google_letter_palette.dart';
import 'package:file_picker/file_picker.dart';

typedef MetadataSave = Future<void> Function(Map<String, String> fields);

/// Artwork is constrained square even when the parent gives unbounded height.
class ArtworkFlipCard extends StatefulWidget {
  final String trackName;
  final Map<String, String> metadata;
  final MetadataSave onSave;
  final Uint8List? embeddedArtwork;
  const ArtworkFlipCard({super.key, required this.trackName, required this.metadata,
    required this.onSave, this.embeddedArtwork});
  @override
  State<ArtworkFlipCard> createState() => _ArtworkFlipCardState();
}

class _ArtworkFlipCardState extends State<ArtworkFlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController flip = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 760), reverseDuration: const Duration(milliseconds: 610));
  bool editing = false;
  @override
  void dispose() { flip.dispose(); super.dispose(); }
  @override
  void didUpdateWidget(covariant ArtworkFlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackName != widget.trackName ||
        oldWidget.metadata['artworkData'] != widget.metadata['artworkData'] ||
        oldWidget.metadata['artworkUrl'] != widget.metadata['artworkUrl']) {
      flip.reverse();
    }
  }
  bool get hasArtwork => widget.embeddedArtwork != null ||
      (widget.metadata['artworkUrl'] ?? '').isNotEmpty ||
      (widget.metadata['artworkData'] ?? '').isNotEmpty;

  Future<void> confirmEdit() async {
    HapticFeedback.mediumImpact();
    final edit = await showModalBottomSheet<bool>(context: context,
      builder: (sheet) => SafeArea(child: ListTile(
        leading: const Icon(Icons.edit_rounded),
        title: const Text('Edit Metadata?'),
        onTap: () => Navigator.pop(sheet, true))));
    if (edit == true && mounted) await openEditor(context);
  }

  void toggle() {
    if (widget.embeddedArtwork != null ||
        (widget.metadata['artworkUrl'] ?? '').isNotEmpty ||
        (widget.metadata['artworkData'] ?? '').isNotEmpty) {
      openEditor(context);
      return;
    }
    if (flip.value > 0.5) { flip.reverse(); } else { flip.forward(); }
  }
  @override
  Widget build(BuildContext context) => AspectRatio(aspectRatio: 1,
    child: AnimatedBuilder(animation: flip, builder: (context, _) {
      // Anticipation, accelerating turn, and soft elastic landing.
      final t = Curves.easeInOutCubic.transform(flip.value);
      final rotation = math.pi * t;
      final rear = rotation > math.pi / 2;
      return GestureDetector(
        onTap: hasArtwork ? null : toggle,
        onLongPress: hasArtwork ? confirmEdit : null,
        child: Transform(transform: Matrix4.identity()..setEntry(3, 2, 0.0012)..rotateY(rotation),
          alignment: Alignment.center, child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(rear ? math.pi : 0),
            child: ClipRRect(borderRadius: BorderRadius.circular(8),
              child: DecoratedBox(
              decoration: const BoxDecoration(gradient: LinearGradient(
                colors: [GoogleLetterPalette.blue, GoogleLetterPalette.red])),
              child: rear ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('Add metadata?', style: TextStyle(color: Color(0xFF221A1B),
                  fontSize: 21, fontWeight: FontWeight.w900)),
                const SizedBox(height: 18),
                FilledButton(onPressed: () => openEditor(context), child: const Text('Enter manually')),
                const SizedBox(height: 8),
                FilledButton.tonal(onPressed: () => findOnline(context), child: const Text('Find online')),
                const SizedBox(height: 14),
                const Text('Tap to flip back', style: TextStyle(
                  fontSize: 11, color: Color(0xFF221A1B))),
              ]) : _front(),
            )),
          )),
      );
    }));
  Widget _front() {
    final artwork = widget.metadata['artworkUrl'] ?? '';
    final localArtwork = widget.metadata['artworkData'] ?? '';
    return Stack(fit: StackFit.expand, children: [
      if (localArtwork.isNotEmpty) Builder(builder: (artContext) {
        try {
          return Image.memory(base64Decode(localArtwork), fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _generic());
        } catch (_) { return _generic(); }
      })
      else if (artwork.isNotEmpty) Image.network(artwork, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => widget.embeddedArtwork == null
          ? _generic() : Image.memory(widget.embeddedArtwork!, fit: BoxFit.cover))
      else if (widget.embeddedArtwork != null) Image.memory(widget.embeddedArtwork!, fit: BoxFit.cover)
      else _generic(),
      if (!hasArtwork) const Positioned(right: 10, bottom: 10,
        child: Icon(Icons.flip_camera_android, color: Color(0xFF221A1B))),
    ]);
  }
  Widget _generic() => const Center(child: Icon(Icons.music_note, size: 115, color: Color(0xFF221A1B)));
  Future<void> openEditor(BuildContext context, [Map<String, String>? suggestion]) async {
    final fields = {...widget.metadata, ...?suggestion};
    const keys = ['title', 'artist', 'album', 'releaseDate', 'genre',
      'trackNumber', 'discNumber', 'composer', 'comments', 'artworkUrl'];
    const labels = ['Song title', 'Artist', 'Album', 'Release date', 'Genre',
      'Track number', 'Disc number', 'Composer', 'Comments', 'Artwork URL'];
    final controllers = {for (final key in keys)
      key: TextEditingController(text: fields[key] ?? (key == 'title' ? widget.trackName : ''))};
    String localArtwork = fields['artworkData'] ?? '';
    String artworkFeedback = '';
    try {
      await showModalBottomSheet<void>(context: context, isScrollControlled: true,
        backgroundColor: GoogleLetterPalette.cream,
        showDragHandle: true,
        builder: (sheet) => StatefulBuilder(builder: (sheet, refresh) => Padding(
          padding: EdgeInsets.fromLTRB(18, 10, 18, MediaQuery.viewInsetsOf(sheet).bottom + 18),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Track metadata', style: TextStyle(fontSize: 25,
              fontWeight: FontWeight.w900, color: GoogleLetterPalette.ink)),
            for (final section in [
              ('BASIC INFORMATION', 0, 3),
              ('TRACK INFORMATION', 3, 8),
              ('NOTES & ARTWORK', 8, keys.length),
            ]) ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 9),
              childrenPadding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
              title: Text(section.$1.toLowerCase().split(' ').map((word) =>
                word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}').join(' '),
                style: const TextStyle(fontWeight: FontWeight.w900,
                  color: GoogleLetterPalette.ink, fontSize: 15)),
              initiallyExpanded: section.$2 == 0,
              children: [for (var i = section.$2; i < section.$3; i++) Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.fromLTRB(6, 0, 0, 6),
                    child: Text(labels[i], style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800,
                      color: GoogleLetterPalette.creamText))),
                  TextField(controller: controllers[keys[i]],
                    style: const TextStyle(color: GoogleLetterPalette.ink,
                      fontWeight: FontWeight.w700, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Enter ${labels[i].toLowerCase()}',
                      hintStyle: TextStyle(color: GoogleLetterPalette.creamText.withValues(alpha: 0.55)),
                      filled: true,
                      fillColor: const Color(0xFFFFFAEF),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
                      border: OutlineInputBorder(borderSide: BorderSide.none,
                        borderRadius: BorderRadius.circular(14)))),
                ]))]),
            const SizedBox(height: 12),
            OutlinedButton.icon(icon: const Icon(Icons.image),
              label: const Text('Choose high-resolution artwork from Files'),
              onPressed: () async {
                final chosen = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
                if (chosen == null || chosen.files.isEmpty) return;
                final image = chosen.files.first.bytes ??
                  (chosen.files.first.path == null ? null :
                    await File(chosen.files.first.path!).readAsBytes());
                if (image == null || image.length > 8000000) {
                  refresh(() => artworkFeedback = 'Choose an image smaller than 8 MB.');
                  return;
                }
                refresh(() {
                  localArtwork = base64Encode(image);
                  artworkFeedback = 'Artwork selected (original resolution preserved).';
                });
              }),
            if (artworkFeedback.isNotEmpty) Text(artworkFeedback),
            const SizedBox(height: 12),
            FilledButton(onPressed: () async {
              final data = {for (final key in keys) key: controllers[key]!.text.trim()};
              if (localArtwork.isNotEmpty) data['artworkData'] = localArtwork;
              await widget.onSave(data);
              if (mounted) flip.reverse();
              if (sheet.mounted) Navigator.pop(sheet);
            }, child: const Text('Save metadata')),
          ]))),
        ));
    } finally { for (final controller in controllers.values) { controller.dispose(); } }
  }
  Future<void> findOnline(BuildContext context) async {
    final query = widget.metadata['title']?.isNotEmpty == true
      ? widget.metadata['title']! : widget.trackName;
    final loading = ValueNotifier<bool>(true);
    final candidates = ValueNotifier<List<Map<String, String>>>([]);
    final error = ValueNotifier<String?>(null);
    // The result picker is opened first; network calls must never freeze playback.
    if (!context.mounted) return;
    final search = showModalBottomSheet<void>(context: context, isScrollControlled: true,
      builder: (sheet) => SafeArea(child: Padding(padding: const EdgeInsets.all(18),
        child: SizedBox(height: MediaQuery.sizeOf(sheet).height * 0.62,
          child: Column(children: [
            const Text('Choose a matching recording', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const Text('Verify the result before saving. Remixes may have no exact match.'),
            ValueListenableBuilder<bool>(valueListenable: loading, builder: (_, waiting, __) =>
              waiting ? const LinearProgressIndicator() : const SizedBox(height: 5)),
            ValueListenableBuilder<String?>(valueListenable: error, builder: (_, message, __) =>
              message == null ? const SizedBox.shrink() : Text(message)),
            Expanded(child: ValueListenableBuilder<List<Map<String, String>>>(
              valueListenable: candidates, builder: (_, results, __) => ListView.builder(
                itemCount: results.length, itemBuilder: (_, i) {
                  final item = results[i];
                  return ListTile(
                    leading: item['artworkUrl']?.isNotEmpty == true
                      ? Image.network(item['artworkUrl']!, width: 54, height: 54,
                          cacheWidth: 160, cacheHeight: 160, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.album))
                      : const Icon(Icons.album),
                    title: Text(item['title'] ?? ''),
                    subtitle: Text('${item['artist'] ?? ''} · ${item['album'] ?? ''}'),
                    onTap: () async {
                      Navigator.pop(sheet);
                      if (mounted) await openEditor(context, item);
                    },
                  );
                },
              ))),
          ])))));
    try {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': query, 'entity': 'song', 'limit': '15',
      });
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 9);
      try {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, 'AuraLocal/1.0 (metadata lookup)');
        final response = await request.close().timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) throw const HttpException('Music search unavailable');
        final body = await utf8.decoder.bind(response).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        candidates.value = (decoded['results'] as List? ?? []).whereType<Map>().map((record) {
          String value(String key) => (record[key] ?? '').toString();
          final image = value('artworkUrl100').replaceAll('100x100bb', '1200x1200bb');
          return <String, String>{
            'title': value('trackName'), 'artist': value('artistName'),
            'album': value('collectionName'), 'releaseDate': value('releaseDate').split('T').first,
            'genre': value('primaryGenreName'), 'trackNumber': value('trackNumber'),
            'artworkUrl': image,
          };
        }).toList();
        if (candidates.value.isEmpty) {
          // MusicBrainz is particularly useful for soundtracks and recordings
          // not distributed through the commercial storefront catalogue.
          final mbUri = Uri.https('musicbrainz.org', '/ws/2/recording/', {
            'query': 'recording:$query', 'fmt': 'json', 'limit': '12',
          });
          final mbRequest = await client.getUrl(mbUri);
          mbRequest.headers.set(HttpHeaders.userAgentHeader, 'AuraLocal/1.0 (metadata research)');
          final mbResponse = await mbRequest.close().timeout(const Duration(seconds: 12));
          if (mbResponse.statusCode == 200) {
            final mb = jsonDecode(await utf8.decoder.bind(mbResponse).join()) as Map;
            candidates.value = (mb['recordings'] as List? ?? []).whereType<Map>().map((record) {
              final credits = record['artist-credit'] as List? ?? [];
              final artist = credits.whereType<Map>().map((c) =>
                (c['artist'] is Map ? c['artist']['name'] : c['name'])?.toString() ?? '').join(', ');
              final releases = (record['releases'] as List? ?? []).whereType<Map>().toList();
              final release = releases.isEmpty ? <String, dynamic>{} : releases.first;
              return <String, String>{
                'title': (record['title'] ?? '').toString(), 'artist': artist,
                'album': (release['title'] ?? '').toString(),
                'releaseDate': (release['date'] ?? '').toString(),
                'genre': '', 'trackNumber': '',
                'artworkUrl': release['id'] == null ? '' :
                  'https://coverartarchive.org/release/${release['id']}/front-1200',
              };
            }).toList();
          }
        }
        if (candidates.value.isEmpty) error.value = 'No matches found. Try manual entry.';
      } finally { client.close(force: true); }
    } catch (e) { error.value = 'Could not search online: $e'; }
    finally { loading.value = false; }
    await search;
    loading.dispose(); candidates.dispose(); error.dispose();
  }
}
