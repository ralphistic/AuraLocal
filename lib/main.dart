import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.auralocal.audio',
    androidNotificationChannelName: 'AuraLocal playback',
    androidNotificationOngoing: true,
  );
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF101218),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF9BE9C6),
        brightness: Brightness.dark,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF101218),
        foregroundColor: Colors.white,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: Colors.white,
        iconColor: Color(0xFF9BE9C6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF252A35),
        hintStyle: const TextStyle(color: Color(0xFFB7BDC9)),
        prefixIconColor: const Color(0xFFB7BDC9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: const MusicPage(),
  ));
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key});
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  final player = AudioPlayer();
  final files = <String>[];
  int repeat = 0;
  bool shuffle = false;
  String? error;
  bool libraryHome = true;
  String query = '';
  final favorites = <String>{};
  bool favoritesOnly = false;
  bool sortAscending = true;
  double playbackSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    AudioSession.instance.then((s) => s.configure(const AudioSessionConfiguration.music()));
    restoreLibrary();
    player.playerStateStream.listen((_) { if (mounted) setState(() {}); });
    player.currentIndexStream.listen((_) { if (mounted) setState(() {}); });
    player.positionStream.listen((_) { if (mounted) setState(() {}); });
    player.durationStream.listen((_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() { player.dispose(); super.dispose(); }

  Future<Directory> musicDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Music');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> libraryManifest() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/auralocal-library.json');
  }

  Future<void> saveLibrary() async {
    final manifest = await libraryManifest();
    await manifest.writeAsString(jsonEncode({'files': files, 'favorites': favorites.toList()}));
  }

  Future<void> loadPlaylist({bool autoplay = false}) async {
    if (files.isEmpty) return;
    await player.setAudioSource(ConcatenatingAudioSource(children: [
      for (final f in files)
        AudioSource.uri(Uri.file(f), tag: MediaItem(
          id: f,
          title: Uri.file(f).pathSegments.last,
          artist: 'Unknown Artist',
        )),
    ]));
    await player.setShuffleModeEnabled(shuffle);
    await player.setLoopMode([LoopMode.off, LoopMode.all, LoopMode.one][repeat]);
    if (autoplay) player.play();
  }

  Future<void> restoreLibrary() async {
    try {
      final manifest = await libraryManifest();
      if (!await manifest.exists()) return;
      final decoded = jsonDecode(await manifest.readAsString());
      final saved = (decoded is List ? decoded : decoded['files'] as List).cast<String>();
      favorites.clear();
      if (decoded is Map && decoded['favorites'] is List) {
        favorites.addAll((decoded['favorites'] as List).cast<String>());
      }
      final existing = <String>[];
      for (final path in saved) {
        if (await File(path).exists()) existing.add(path);
      }
      files..clear()..addAll(existing);
      await loadPlaylist();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = 'Could not restore library: $e');
    }
  }

  Future<void> import() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['flac', 'mp3', 'm4a', 'wav', 'aac'],
        allowMultiple: true,
      );
      if (picked == null) return;
      final directory = await musicDirectory();
      var imported = 0;
      for (final entry in picked.files) {
        final source = entry.path;
        if (source == null) continue;
        final original = File(source);
        if (!await original.exists()) continue;
        final safeName = entry.name.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_');
        var target = File('${directory.path}/$safeName');
        var suffix = 1;
        while (await target.exists()) {
          final dot = safeName.lastIndexOf('.');
          final base = dot > 0 ? safeName.substring(0, dot) : safeName;
          final ext = dot > 0 ? safeName.substring(dot) : '';
          target = File('${directory.path}/${base}_${suffix++}$ext');
        }
        await original.copy(target.path);
        files.add(target.path);
        imported++;
      }
      if (imported == 0) throw Exception('No accessible audio files returned');
      await saveLibrary();
      await loadPlaylist();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> skipTrack(int delta) async {
    if (files.isEmpty) return;
    final current = player.currentIndex ?? 0;
    if (delta < 0 && player.position.inSeconds > 3) {
      await player.seek(Duration.zero);
      return;
    }
    final target = (current + delta + files.length) % files.length;
    await player.seek(Duration.zero, index: target);
    if (!player.playing) await player.play();
  }

  Future<void> seekSeconds(int seconds) async {
    final duration = player.duration;
    if (files.isEmpty || duration == null) return;
    final target = player.position + Duration(seconds: seconds);
    final ms = target.inMilliseconds.clamp(0, duration.inMilliseconds);
    await player.seek(Duration(milliseconds: ms));
  }

  void showLibrary() => setState(() => libraryHome = true);

  String displayName(String path) {
    final raw = Uri.file(path).pathSegments.last;
    return raw.replaceFirst(RegExp(r'\\.(flac|mp3|m4a|wav|aac)$', caseSensitive: false), '');
  }

  Future<void> toggleFavorite(String path) async {
    setState(() => favorites.contains(path) ? favorites.remove(path) : favorites.add(path));
    await saveLibrary();
  }

  String get title {
    final i = player.currentIndex;
    if (i == null || i >= files.length) return 'Your music awaits';
    return displayName(files[i]);
  }

  String clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final length = player.duration ?? Duration.zero;
    final pos = player.position;
    final max = length.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    if (libraryHome) {
      final matches = List<int>.generate(files.length, (i) => i).where((i) =>
        (!favoritesOnly || favorites.contains(files[i])) && displayName(files[i]).toLowerCase().contains(query.toLowerCase())).toList()
        ..sort((a, b) => sortAscending ? displayName(files[a]).toLowerCase().compareTo(displayName(files[b]).toLowerCase()) : displayName(files[b]).toLowerCase().compareTo(displayName(files[a]).toLowerCase()));
      return Scaffold(
        backgroundColor: const Color(0xFF101218),
        appBar: AppBar(
          title: const Text('Your Library'),
          backgroundColor: const Color(0xFF101218),
          actions: [IconButton(tooltip: 'Import music', icon: const Icon(Icons.add), onPressed: import)],
        ),
        body: SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: InputDecoration(
                hintText: 'Search songs',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
            ChoiceChip(label: const Text('All songs'), selected: !favoritesOnly, onSelected: (_) => setState(() => favoritesOnly = false)),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text('Favorites'), selected: favoritesOnly, onSelected: (_) => setState(() => favoritesOnly = true)),
            const Spacer(),
            IconButton(tooltip: 'Change sort order', icon: Icon(sortAscending ? Icons.sort_by_alpha : Icons.sort), onPressed: () => setState(() => sortAscending = !sortAscending)),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(18, 8, 18, 6), child: Align(alignment: Alignment.centerLeft, child: Text('${files.length} songs', style: const TextStyle(color: Colors.white60)))),
          Expanded(child: files.isEmpty
            ? Center(child: FilledButton.icon(onPressed: import,
                icon: const Icon(Icons.add), label: const Text('Import your music')))
            : ListView.builder(
                itemCount: matches.length,
                itemBuilder: (_, row) {
                  final i = matches[row];
                  return ListTile(
                    leading: const Icon(Icons.music_note, color: Colors.tealAccent),
                    title: Text(displayName(files[i]), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(i == player.currentIndex ? 'Now playing' : 'Local audio', style: const TextStyle(color: Colors.white60)),
                    trailing: IconButton(tooltip: 'Favorite', icon: Icon(favorites.contains(files[i]) ? Icons.favorite : Icons.favorite_border, color: favorites.contains(files[i]) ? const Color(0xFF9BE9C6) : Colors.white70), onPressed: () => toggleFavorite(files[i])),
                    onTap: () async {
                      await player.seek(Duration.zero, index: i);
                      player.play();
                      if (mounted) setState(() => libraryHome = false);
                    },
                  );
                },
              )),
          if (files.isNotEmpty) ListTile(
            tileColor: const Color(0xFF29483F),
            leading: const Icon(Icons.graphic_eq, color: Colors.tealAccent),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            onTap: () => setState(() => libraryHome = false),
            trailing: IconButton(color: Colors.white,
              icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => player.playing ? player.pause() : player.play()),
          ),
          if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
        ])),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF101218),
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Now Playing'),
        actions: [IconButton(tooltip: 'Library', onPressed: showLibrary, icon: const Icon(Icons.library_music)), IconButton(tooltip: 'Import songs', onPressed: import, icon: const Icon(Icons.add_circle_outline))]),
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const Spacer(),
        Expanded(flex: 5, child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(colors: [Color(0xFF295548), Color(0xFF181B2B)])),
          child: const Center(child: Icon(Icons.music_note, size: 120, color: Color(0xFF9BE9C6))))),
        const SizedBox(height: 24),
        Row(children: [Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold, color: Colors.white))),
          if (files.isNotEmpty) IconButton(tooltip: 'Favorite', onPressed: () => toggleFavorite(files[player.currentIndex ?? 0]), icon: Icon(favorites.contains(files[player.currentIndex ?? 0]) ? Icons.favorite : Icons.favorite_border, color: const Color(0xFF9BE9C6)))
        ]),
        const SizedBox(height: 8),
        Text(files.isEmpty ? 'Tap + to import local audio' : '${files.length} local files',
          style: const TextStyle(color: Colors.white60)),
        const SizedBox(height: 22),
        Slider(value: pos.inMilliseconds.toDouble().clamp(0.0, max), max: max,
          onChanged: length == Duration.zero ? null : (v) => player.seek(Duration(milliseconds: v.round()))),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(clock(pos), style: const TextStyle(color: Colors.white70)),
          Text(clock(length), style: const TextStyle(color: Colors.white70))
        ]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          IconButton(color: shuffle ? Colors.tealAccent : Colors.white,
            onPressed: () async { shuffle = !shuffle; await player.setShuffleModeEnabled(shuffle); setState(() {}); },
            icon: const Icon(Icons.shuffle)),
          IconButton(tooltip: 'Previous track', onPressed: files.isEmpty ? null : () => skipTrack(-1), icon: const Icon(Icons.skip_previous), iconSize: 36),
          IconButton.filled(onPressed: files.isEmpty ? import : () => player.playing ? player.pause() : player.play(),
            icon: Icon(player.playing ? Icons.pause : Icons.play_arrow), iconSize: 38),
          IconButton(tooltip: 'Next track', onPressed: files.isEmpty ? null : () => skipTrack(1), icon: const Icon(Icons.skip_next), iconSize: 36),
          Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(color: repeat == 0 ? Colors.white : Colors.tealAccent,
              onPressed: () async { repeat = (repeat + 1) % 3;
                await player.setLoopMode([LoopMode.off, LoopMode.all, LoopMode.one][repeat]); setState(() {}); },
              icon: Icon(repeat == 2 ? Icons.repeat_one : Icons.repeat)),
            Text(['OFF', 'ALL', 'ONE'][repeat], style: const TextStyle(fontSize: 10, color: Colors.white))
          ])
        ]),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton.icon(
            onPressed: files.isEmpty ? null : () => seekSeconds(-10),
            icon: const Icon(Icons.replay_10),
            label: const Text('Back 10s')),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: files.isEmpty ? null : () => seekSeconds(10),
            icon: const Icon(Icons.forward_10),
            label: const Text('Forward 10s')),
        ]),
        TextButton.icon(onPressed: showLibrary,
          icon: const Icon(Icons.library_music), label: const Text('Your Library')),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('Speed', style: TextStyle(color: Colors.white70)),
          const SizedBox(width: 12),
          DropdownButton<double>(value: playbackSpeed, dropdownColor: const Color(0xFF252A35),
            items: [0.75, 1.0, 1.25, 1.5, 2.0].map((v) => DropdownMenuItem(value: v, child: Text('${v}×'))).toList(),
            onChanged: (v) async { if (v == null) return; await player.setSpeed(v); setState(() => playbackSpeed = v); }),
        ]),
        TextButton.icon(onPressed: () => showModalBottomSheet(context: context,
          builder: (_) => const SafeArea(child: Padding(padding: EdgeInsets.all(24),
            child: Text('EQ is planned, but is not implemented in this prototype.')))),
          icon: const Icon(Icons.equalizer), label: const Text('Audio settings')),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
        const Spacer()
      ]))),
    );
  }
}
