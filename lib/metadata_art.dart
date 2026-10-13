import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';

typedef MetadataSave = Future<void> Function(Map<String, String> fields);

/// Artwork is constrained square even when the parent gives unbounded height.
class ArtworkFlipCard extends StatefulWidget {
  final String trackName;
  final Map<String, String> metadata;
  final MetadataSave onSave;
  const ArtworkFlipCard({super.key, required this.trackName, required this.metadata, required this.onSave});
  @override
  State<ArtworkFlipCard> createState() => _ArtworkFlipCardState();
}

class _ArtworkFlipCardState extends State<ArtworkFlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController flip = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1050));
  bool editing = false;
  @override
  void dispose() { flip.dispose(); super.dispose(); }
  @override
  void didUpdateWidget(covariant ArtworkFlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackName != widget.trackName) flip.reverse();
  }
  void toggle() { if (flip.value > 0.5) { flip.reverse(); } else { flip.forward(); } }
  @override
  Widget build(BuildContext context) => AspectRatio(aspectRatio: 1,
    child: AnimatedBuilder(animation: flip, builder: (context, _) {
      // Anticipation, accelerating turn, and soft elastic landing.
      final t = Curves.easeInOutCubicEmphasized.transform(flip.value);
      final rotation = math.pi * t + math.sin(flip.value * math.pi * 2) * 0.045;
      final rear = rotation > math.pi / 2;
      return GestureDetector(onTap: toggle,
        child: Transform(transform: Matrix4.identity()..setEntry(3, 2, 0.0012)..rotateY(rotation),
          alignment: Alignment.center, child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(rear ? math.pi : 0),
            child: ClipRect(child: DecoratedBox(
              decoration: const BoxDecoration(gradient: LinearGradient(
                colors: [Color(0xFFFFB8A5), Color(0xFFF08078)])),
              child: rear ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('ADD METADATA?', style: TextStyle(color: Color(0xFF221A1B),
                  fontSize: 21, fontWeight: FontWeight.w900)),
                const SizedBox(height: 18),
                FilledButton(onPressed: () => openEditor(context), child: const Text('Enter manually')),
                const SizedBox(height: 8),
                FilledButton.tonal(onPressed: () => findOnline(context), child: const Text('Find online')),
                const SizedBox(height: 14),
                const Text('Tap to flip back', style: TextStyle(color: Color(0xFF221A1B))),
              ]) : _front(),
            )),
          )),
      );
    }));
  }
  Widget _front() {
    final artwork = widget.metadata['artworkUrl'] ?? '';
    return Stack(fit: StackFit.expand, children: [
      if (artwork.isNotEmpty) Image.network(artwork, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _generic())
      else _generic(),
      const Positioned(right: 10, bottom: 10,
        child: Icon(Icons.flip_camera_android, color: Color(0xFF221A1B))),
    ]);
  }
  Widget _generic() => const Center(child: Icon(Icons.music_note, size: 115, color: Color(0xFF221A1B)));
  Future<void> openEditor(BuildContext context, [Map<String, String>? suggestion]) async {
    final fields = {...widget.metadata, ...?suggestion};
    const keys = ['title', 'artist', 'album', 'releaseDate', 'genre', 'trackNumber', 'artworkUrl'];
    const labels = ['Song title', 'Artist', 'Album', 'Release date', 'Genre', 'Track number', 'Artwork URL'];
    final controllers = {for (final key in keys)
      key: TextEditingController(text: fields[key] ?? (key == 'title' ? widget.trackName : ''))};
    try {
      await showModalBottomSheet<void>(context: context, isScrollControlled: true,
        builder: (sheet) => Padding(
          padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.viewInsetsOf(sheet).bottom + 18),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Track metadata', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            for (var i = 0; i < keys.length; i++) Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: TextField(controller: controllers[keys[i]], decoration: InputDecoration(labelText: labels[i]))),
            const SizedBox(height: 12),
            FilledButton(onPressed: () async {
              final data = {for (final key in keys) key: controllers[key]!.text.trim()};
              await widget.onSave(data);
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
                      ? Image.network(item['artworkUrl']!, width: 54, height: 54, fit: BoxFit.cover,
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
        if (candidates.value.isEmpty) error.value = 'No matches found. Try manual entry.';
      } finally { client.close(force: true); }
    } catch (e) { error.value = 'Could not search online: $e'; }
    finally { loading.value = false; }
    await search;
    loading.dispose(); candidates.dispose(); error.dispose();
  }
}
