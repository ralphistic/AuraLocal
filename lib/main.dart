import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
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
  ConcatenatingAudioSource? activeSource;

  AudioSource sourceFor(String path) => AudioSource.uri(Uri.file(path), tag: MediaItem(
    id: path, title: displayName(path), artist: 'Unknown Artist',
  ));
  final files = <String>[];
  int repeat = 0;
  bool shuffle = false;
  String? error;
  bool libraryHome = true;
  String query = '';
  final favorites = <String>{};
  final playlists = <String, List<String>>{};
  String? activePlaylist;
  bool favoritesOnly = false;
  bool sortAscending = true;
  double playbackSpeed = 1.0;
  double pitchCents = 0.0;
  int pitchSemitones = 0;
  static const nativeDsp = MethodChannel('auralocal/native_dsp');

  Future<void> updateNativePitchTempo() async {
    try {
      await nativeDsp.invokeMethod('setTimePitch', {'tempo': playbackSpeed, 'cents': pitchSemitones * 100 + pitchCents});
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Native DSP: ${e.message}');
    }
  }
  double? scrubPosition;
  bool draggingPlayer = false;

  @override
  void initState() {
    super.initState();
    AudioSession.instance.then((s) => s.configure(const AudioSessionConfiguration.music()));
    restoreLibrary();
    player.playerStateStream.listen((_) { if (mounted) setState(() {}); });
    player.currentIndexStream.listen((_) { if (mounted) setState(() {}); });
    player.positionStream.listen((_) { if (mounted && !draggingPlayer && !libraryHome) setState(() {}); });
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
    await manifest.writeAsString(jsonEncode({'files': files, 'favorites': favorites.toList(), 'playlists': playlists, 'shuffle': shuffle, 'repeat': repeat, 'speed': playbackSpeed, 'pitchCents': pitchCents, 'pitchSemitones': pitchSemitones}));
  }

  Future<void> loadPlaylist({bool autoplay = false}) async {
    if (activeSource != null || files.isEmpty) return;
    final source = ConcatenatingAudioSource(children: [
      for (final path in files) sourceFor(path),
    ]);
    activeSource = source;
    try {
      await player.setAudioSource(source);
      await player.setShuffleModeEnabled(shuffle);
      await player.setLoopMode([LoopMode.off, LoopMode.all, LoopMode.one][repeat]);
      await player.setSpeed(playbackSpeed);
      if (autoplay) player.play();
    } catch (_) {
      activeSource = null;
      rethrow;
    }
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
      if (decoded is Map) {
        shuffle = decoded['shuffle'] == true;
        final savedRepeat = decoded['repeat'];
        if (savedRepeat is int && savedRepeat >= 0 && savedRepeat <= 2) repeat = savedRepeat;
        final savedSemitones = decoded['pitchSemitones'];
        if (savedSemitones is int) pitchSemitones = savedSemitones.clamp(-12, 12);
        final savedPitch = decoded['pitchCents'];
        if (savedPitch is num) pitchCents = savedPitch.toDouble().clamp(-99.0, 99.0);
        final savedSpeed = decoded['speed'];
        if (savedSpeed is num && [0.75, 1.0, 1.25, 1.5, 2.0].contains(savedSpeed.toDouble())) playbackSpeed = savedSpeed.toDouble();
      }
      playlists.clear();
      if (decoded is Map && decoded['playlists'] is Map) {
        (decoded['playlists'] as Map).forEach((name, paths) {
          if (name is String && paths is List) playlists[name] = paths.whereType<String>().toList();
        });
      }
      final existing = <String>[];
      for (final path in saved) {
        if (await File(path).exists()) existing.add(path);
      }
      files..clear()..addAll(existing);
      for (final songs in playlists.values) { songs.removeWhere((path) => !files.contains(path)); }
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
      if (activeSource == null) {
        await loadPlaylist();
      } else {
        // Extend the existing audio sequence; never reset the playing track.
        final newPaths = files.sublist(files.length - imported);
        await activeSource!.addAll([for (final path in newPaths) sourceFor(path)]);
      }
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> showPitchWheel(StateSetter refresh) async {
    await showModalBottomSheet<void>(context: context, backgroundColor: const Color(0xFF343438),
      isScrollControlled: true, builder: (sheet) => SafeArea(child: SizedBox(height: 360,
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close)),
            const Expanded(child: Text('Adjust Pitch', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(width: 48),
          ]),
          const Row(children: [
            Expanded(child: Center(child: Text('Semitones'))),
            Expanded(child: Center(child: Text('Cents'))),
          ]),
          Expanded(child: Row(children: [
            Expanded(child: CupertinoPicker(
              scrollController: FixedExtentScrollController(initialItem: pitchSemitones + 12),
              itemExtent: 44, onSelectedItemChanged: (i) {
                refresh(() => pitchSemitones = i - 12);
                updateNativePitchTempo(); saveLibrary();
              }, children: [for (var i = -12; i <= 12; i++) Center(child: Text('${i >= 0 ? '+' : ''}$i'))],
            )),
            Expanded(child: CupertinoPicker(
              scrollController: FixedExtentScrollController(initialItem: pitchCents.round() + 99),
              itemExtent: 44, onSelectedItemChanged: (i) {
                refresh(() => pitchCents = (i - 99).toDouble());
                updateNativePitchTempo(); saveLibrary();
              }, children: [for (var i = -99; i <= 99; i++) Center(child: Text('${i >= 0 ? '+' : ''}$i'))],
            )),
          ])),
        ]),
      )));
  }

  Future<void> showTempoWheel(StateSetter refresh) async {
    await showModalBottomSheet<void>(context: context, backgroundColor: const Color(0xFF343438),
      isScrollControlled: true, builder: (sheet) => SafeArea(child: SizedBox(height: 360,
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close)),
            const Expanded(child: Text('Adjust Tempo', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(width: 48),
          ]),
          Expanded(child: CupertinoPicker(
            scrollController: FixedExtentScrollController(initialItem: (playbackSpeed * 100).round() - 50),
            itemExtent: 44, onSelectedItemChanged: (i) async {
              final value = (i + 50) / 100.0;
              refresh(() => playbackSpeed = value);
              await player.setSpeed(value);
              await updateNativePitchTempo();
              await saveLibrary();
            }, children: [for (var i = 50; i <= 200; i++) Center(child: Text('$i%'))],
          )),
        ]),
      )));
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

  Future<void> createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('New playlist'),
      content: TextField(controller: controller, autofocus: true, maxLength: 60,
        decoration: const InputDecoration(hintText: 'Playlist name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Create')),
      ],
    ));
    controller.dispose();
    if (name == null || name.isEmpty || playlists.containsKey(name)) return;
    setState(() { playlists[name] = []; activePlaylist = name; });
    await saveLibrary();
  }

  Future<void> addToPlaylist(String path) async {
    if (playlists.isEmpty) await createPlaylist();
    if (!mounted || playlists.isEmpty) return;
    final selected = await showModalBottomSheet<String>(context: context, builder: (context) =>
      SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Add to playlist')),
        for (final name in playlists.keys)
          ListTile(leading: const Icon(Icons.playlist_add), title: Text(name),
            onTap: () => Navigator.pop(context, name)),
      ])));
    if (selected == null) return;
    setState(() { if (!playlists[selected]!.contains(path)) playlists[selected]!.add(path); });
    await saveLibrary();
  }

  Future<void> renamePlaylist(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Rename playlist'),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
      ],
    ));
    controller.dispose();
    if (name == null || name.isEmpty || (name != oldName && playlists.containsKey(name))) return;
    setState(() {
      final songs = playlists.remove(oldName);
      if (songs != null) playlists[name] = songs;
      if (activePlaylist == oldName) activePlaylist = name;
    });
    await saveLibrary();
  }

  void playlistMenu(String name) {
    showModalBottomSheet<void>(context: context, builder: (context) => SafeArea(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.edit), title: const Text('Rename playlist'), onTap: () {
          Navigator.pop(context); renamePlaylist(name);
        }),
        ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete playlist'), onTap: () async {
          Navigator.pop(context);
          setState(() { playlists.remove(name); if (activePlaylist == name) activePlaylist = null; });
          await saveLibrary();
        }),
      ])));
  }

  Future<void> removeTrack(String path) async {
    final index = files.indexOf(path);
    if (index < 0) return;
    // Remove from the live audio sequence rather than replacing the player source.
    if (activeSource != null) await activeSource!.removeAt(index);
    setState(() {
      files.removeAt(index);
      favorites.remove(path);
      for (final songs in playlists.values) { songs.remove(path); }
    });
    await saveLibrary();
    if (files.isEmpty) {
      await player.stop();
      activeSource = null;
    }
  }

  void trackMenu(String path) {
    showModalBottomSheet<void>(context: context, builder: (context) => SafeArea(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.playlist_add), title: const Text('Add to playlist'),
          onTap: () { Navigator.pop(context); addToPlaylist(path); }),
        ListTile(leading: Icon(favorites.contains(path) ? Icons.favorite : Icons.favorite_border),
          title: Text(favorites.contains(path) ? 'Remove favorite' : 'Add favorite'),
          onTap: () { Navigator.pop(context); toggleFavorite(path); }),
        ListTile(leading: const Icon(Icons.remove_circle_outline), title: const Text('Remove from library'),
          onTap: () { Navigator.pop(context); removeTrack(path); }),
      ])));
  }

  Future<void> moveQueuedTrack(int from, int to) async {
    if (from < 0 || from >= files.length || to < 0 || to >= files.length || from == to) return;
    final currentPath = player.currentIndex == null ? null : files[player.currentIndex!];
    final wasPlaying = player.playing;
    final currentPosition = player.position;
    final source = player.audioSource;
    if (source is ConcatenatingAudioSource) {
      await source.move(from, to);
    } else {
      return;
    }
    setState(() {
      final moved = files.removeAt(from);
      files.insert(to, moved);
    });
    // Moving a source preserves its playback identity; keep the current track and position.
    if (currentPath != null && files.contains(currentPath) && player.currentIndex != files.indexOf(currentPath)) {
      await player.seek(currentPosition, index: files.indexOf(currentPath));
    }
    if (wasPlaying && !player.playing) player.play();
    await saveLibrary();
  }

  void showQueue() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (sheetContext) =>
      SafeArea(child: FractionallySizedBox(heightFactor: 0.78, child: Column(children: [
        const ListTile(title: Text('Up Next'), subtitle: Text('Drag the handles to reorder playback')),
        Expanded(child: StatefulBuilder(builder: (context, updateSheet) =>
          ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: files.length,
            onReorder: (oldIndex, newIndex) async {
              if (newIndex > oldIndex) newIndex--;
              await moveQueuedTrack(oldIndex, newIndex);
              updateSheet(() {});
            },
            itemBuilder: (_, i) => ListTile(
              key: ValueKey(files[i]),
              leading: Icon(i == player.currentIndex ? Icons.graphic_eq : Icons.music_note),
              title: Text(displayName(files[i]), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: i == player.currentIndex ? const Text('Now playing') : null,
              onTap: () {
                Navigator.pop(sheetContext);
                player.seek(Duration.zero, index: i);
                player.play();
              },
              trailing: ReorderableDragStartListener(index: i,
                child: const Icon(Icons.drag_handle, color: Colors.white70)),
            ),
          ))),
      ]))));
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
    final pos = draggingPlayer && scrubPosition != null ? Duration(milliseconds: scrubPosition!.round()) : player.position;
    final max = length.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    if (libraryHome) {
      final matches = List<int>.generate(files.length, (i) => i).where((i) =>
        (activePlaylist == null || (playlists[activePlaylist]?.contains(files[i]) ?? false)) && (!favoritesOnly || favorites.contains(files[i])) && displayName(files[i]).toLowerCase().contains(query.toLowerCase())).toList()
        ..sort((a, b) => sortAscending ? displayName(files[a]).toLowerCase().compareTo(displayName(files[b]).toLowerCase()) : displayName(files[b]).toLowerCase().compareTo(displayName(files[a]).toLowerCase()));
      return Scaffold(
        backgroundColor: const Color(0xFF101218),
        appBar: AppBar(
          title: const Text('Your Library'),
          backgroundColor: const Color(0xFF101218),
          actions: [IconButton(tooltip: 'New playlist', icon: const Icon(Icons.playlist_add), onPressed: createPlaylist), IconButton(tooltip: 'Import music', icon: const Icon(Icons.add), onPressed: import)],
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
          SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            ChoiceChip(label: const Text('Library'), selected: activePlaylist == null, onSelected: (_) => setState(() => activePlaylist = null)),
            const SizedBox(width: 8),
            for (final name in playlists.keys) ...[
              InputChip(label: Text(name), selected: activePlaylist == name,
                onSelected: (_) => setState(() => activePlaylist = name),
                onDeleted: () => playlistMenu(name), deleteIcon: const Icon(Icons.more_horiz, size: 18)),
              const SizedBox(width: 8),
            ],
          ])),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
            ChoiceChip(label: const Text('All songs'), selected: !favoritesOnly, onSelected: (_) => setState(() => favoritesOnly = false)),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text('Favorites'), selected: favoritesOnly, onSelected: (_) => setState(() => favoritesOnly = true)),
            const Spacer(),
            IconButton(tooltip: 'Change sort order', icon: Icon(sortAscending ? Icons.sort_by_alpha : Icons.sort), onPressed: () => setState(() => sortAscending = !sortAscending)),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(18, 8, 18, 6), child: Align(alignment: Alignment.centerLeft, child: Text(activePlaylist == null ? '${files.length} songs' : '${activePlaylist!} • ${matches.length} songs', style: const TextStyle(color: Colors.white60)))),
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
                    trailing: IconButton(tooltip: 'Song options', icon: const Icon(Icons.more_vert, color: Colors.white70), onPressed: () => trackMenu(files[i])),
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
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (details) { if ((details.primaryVelocity ?? 0) > 450) showLibrary(); },
      child: Scaffold(
      backgroundColor: const Color(0xFF101218),
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('Now Playing'),
        actions: [IconButton(tooltip: 'Queue', onPressed: showQueue, icon: const Icon(Icons.queue_music)), IconButton(tooltip: 'Library', onPressed: showLibrary, icon: const Icon(Icons.library_music)), IconButton(tooltip: 'Import songs', onPressed: import, icon: const Icon(Icons.add_circle_outline))]),
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
        Text(files.isEmpty ? 'Tap + to import local audio' : 'Playing from Your Library',
          style: const TextStyle(color: Colors.white60)),
        const SizedBox(height: 22),
        Slider(value: pos.inMilliseconds.toDouble().clamp(0.0, max), max: max,
          onChangeStart: length == Duration.zero ? null : (v) => setState(() { draggingPlayer = true; scrubPosition = v; }),
          onChanged: length == Duration.zero ? null : (v) => setState(() => scrubPosition = v),
          onChangeEnd: length == Duration.zero ? null : (v) async {
            await player.seek(Duration(milliseconds: v.round()));
            if (mounted) setState(() { draggingPlayer = false; scrubPosition = null; });
          }),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(clock(pos), style: const TextStyle(color: Colors.white70)),
          Text(clock(length), style: const TextStyle(color: Colors.white70))
        ]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          IconButton(color: shuffle ? Colors.tealAccent : Colors.white,
            onPressed: () async { shuffle = !shuffle; await player.setShuffleModeEnabled(shuffle); await saveLibrary(); setState(() {}); },
            icon: const Icon(Icons.shuffle)),
          IconButton(tooltip: 'Previous track', onPressed: files.isEmpty ? null : () => skipTrack(-1), icon: const Icon(Icons.skip_previous), iconSize: 36),
          IconButton.filled(onPressed: files.isEmpty ? import : () => player.playing ? player.pause() : player.play(),
            icon: Icon(player.playing ? Icons.pause : Icons.play_arrow), iconSize: 38),
          IconButton(tooltip: 'Next track', onPressed: files.isEmpty ? null : () => skipTrack(1), icon: const Icon(Icons.skip_next), iconSize: 36),
          Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(color: repeat == 0 ? Colors.white : Colors.tealAccent,
              onPressed: () async { repeat = (repeat + 1) % 3;
                await player.setLoopMode([LoopMode.off, LoopMode.all, LoopMode.one][repeat]); await saveLibrary(); setState(() {}); },
              icon: Icon(repeat == 2 ? Icons.repeat_one : Icons.repeat)),
            Text(['OFF', 'ALL', 'ONE'][repeat], style: const TextStyle(fontSize: 10, color: Colors.white))
          ])
        ]),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(tooltip: 'Back 10 seconds', iconSize: 32,
            onPressed: files.isEmpty ? null : () => seekSeconds(-10), icon: const Icon(Icons.replay_10)),
          const SizedBox(width: 16),
          IconButton(tooltip: 'Forward 10 seconds', iconSize: 32,
            onPressed: files.isEmpty ? null : () => seekSeconds(10), icon: const Icon(Icons.forward_10)),
        ]),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton.icon(onPressed: showLibrary, icon: const Icon(Icons.library_music), label: const Text('Library')),
          TextButton.icon(onPressed: showQueue, icon: const Icon(Icons.queue_music), label: const Text('Queue')),
          if (files.isNotEmpty) IconButton(tooltip: 'Add to playlist', icon: const Icon(Icons.playlist_add), onPressed: () => addToPlaylist(files[player.currentIndex ?? 0])),
        ]),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('Speed', style: TextStyle(color: Colors.white70)),
          const SizedBox(width: 12),
          DropdownButton<double>(value: playbackSpeed, dropdownColor: const Color(0xFF252A35),
            items: [0.75, 1.0, 1.25, 1.5, 2.0].map((v) => DropdownMenuItem(value: v, child: Text('${v}×'))).toList(),
            onChanged: (v) async { if (v == null) return; await player.setSpeed(v); setState(() => playbackSpeed = v); await saveLibrary(); }),
        ]),
        TextButton.icon(onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (context) => StatefulBuilder(builder: (context, refresh) => SafeArea(
            child: Padding(padding: const EdgeInsets.all(20), child: Column(
              mainAxisSize: MainAxisSize.min, children: [
                const Text('Pitch / tempo engine', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text('Native DSP controls are experimental. Playback still uses just_audio; pitch changes are not audible until the audio stream is connected.', textAlign: TextAlign.center),
                const SizedBox(height: 20),
                TextButton(onPressed: () => showPitchWheel(refresh), child: Text('Pitch: ${pitchSemitones >= 0 ? '+' : ''}$pitchSemitones semitones, ${pitchCents.toStringAsFixed(0)} cents')),
                Text('Semitones: ${pitchSemitones >= 0 ? '+' : ''}$pitchSemitones'),
                Slider(value: pitchSemitones.toDouble(), min: -12, max: 12, divisions: 24,
                  onChanged: (v) { refresh(() => pitchSemitones = v.round()); setState(() {}); },
                  onChangeEnd: (v) async { await updateNativePitchTempo(); await saveLibrary(); }),
                Text('Fine pitch: ${pitchCents.toStringAsFixed(0)} cents'),
                Slider(value: pitchCents, min: -99, max: 99, divisions: 198,
                  onChanged: (v) { refresh(() => pitchCents = v); setState(() {}); },
                  onChangeEnd: (v) async { await updateNativePitchTempo(); await saveLibrary(); }),
                TextButton(onPressed: () => showTempoWheel(refresh), child: Text('Tempo: ${(playbackSpeed * 100).toStringAsFixed(0)}%')),
                Slider(value: playbackSpeed, min: 0.5, max: 2.0, divisions: 150,
                  onChanged: (v) { refresh(() => playbackSpeed = v); setState(() {}); },
                  onChangeEnd: (v) async {
                    await player.setSpeed(v);
                    await updateNativePitchTempo();
                    await saveLibrary();
                  }),
                TextButton(onPressed: () async {
                  refresh(() { pitchCents = 0; pitchSemitones = 0; playbackSpeed = 1; });
                  setState(() {});
                  await player.setSpeed(1);
                  await updateNativePitchTempo();
                  await saveLibrary();
                }, child: const Text('Reset pitch and tempo')),
              ],
            )),
          )),
        ), icon: const Icon(Icons.tune), label: const Text('Pitch / tempo (experimental)')),
        TextButton.icon(onPressed: () => showModalBottomSheet(context: context,
          builder: (_) => const SafeArea(child: Padding(padding: EdgeInsets.all(24),
            child: Text('EQ is planned, but is not implemented in this prototype.')))),
          icon: const Icon(Icons.equalizer), label: const Text('Audio settings')),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
        const Spacer()
      ]))),
    ));
  }
}
