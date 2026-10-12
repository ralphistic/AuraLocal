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
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: MusicPage()));
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
    await manifest.writeAsString(jsonEncode(files));
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
    if (autoplay) await player.play();
  }

  Future<void> restoreLibrary() async {
    try {
      final manifest = await libraryManifest();
      if (!await manifest.exists()) return;
      final saved = (jsonDecode(await manifest.readAsString()) as List).cast<String>();
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
      await loadPlaylist(autoplay: true);
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

  void showLibrary() {
    setState(() => libraryHome = true);
    /* Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (libraryContext) => Scaffold(
        backgroundColor: const Color(0xFF101218),
        appBar: AppBar(title: const Text('Your Library'), backgroundColor: const Color(0xFF101218),
          actions: [IconButton(icon: const Icon(Icons.add), onPressed: () async {
            Navigator.of(libraryContext).pop();
            await import();
          })]),
        body: files.isEmpty
          ? Center(child: TextButton.icon(
              onPressed: () async {
                Navigator.of(libraryContext).pop();
                await import();
              },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Import your first song')))
          : ListView.builder(
              itemCount: files.length,
              itemBuilder: (_, index) {
                final name = Uri.file(files[index]).pathSegments.last;
                return ListTile(
                  leading: Icon(
                    index == player.currentIndex ? Icons.graphic_eq : Icons.music_note,
                    color: Colors.tealAccent),
                  title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('Track ${index + 1}'),
                  onTap: () async {
                    Navigator.of(libraryContext).pop();
                    await player.seek(Duration.zero, index: index);
                    await player.play();
                  },
                );
              },
            ),
      ),
    )); */
  }

  String get title {
    final i = player.currentIndex;
    if (i == null || i >= files.length) return 'Your music awaits';
    return Uri.file(files[i]).pathSegments.last;
  }

  String clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final length = player.duration ?? Duration.zero;
    final pos = player.position;
    final max = length.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    if (libraryHome) {
      final matches = List<int>.generate(files.length, (i) => i).where((i) =>
        Uri.file(files[i]).pathSegments.last.toLowerCase().contains(query.toLowerCase())).toList();
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
          Expanded(child: files.isEmpty
            ? Center(child: FilledButton.icon(onPressed: import,
                icon: const Icon(Icons.add), label: const Text('Import your music')))
            : ListView.builder(
                itemCount: matches.length,
                itemBuilder: (_, row) {
                  final i = matches[row];
                  return ListTile(
                    leading: const Icon(Icons.music_note, color: Colors.tealAccent),
                    title: Text(Uri.file(files[i]).pathSegments.last,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
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
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => setState(() => libraryHome = false),
            trailing: IconButton(
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
        const SizedBox(height: 30),
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold, color: Colors.white)),
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
