import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF101218),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF9BE9C6), brightness: Brightness.dark),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF101218), foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: const Color(0xFF252A35),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    ),
    home: const MusicPage(),
  ));
}

/// UI and library manager. The sole audio player lives in AuraDspGraph on iOS.
class MusicPage extends StatefulWidget {
  const MusicPage({super.key});
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> with SingleTickerProviderStateMixin {
  static const nativeDsp = MethodChannel('auralocal/native_dsp');
  final files = <String>[];
  final originalNames = <String, String>{};
  final favorites = <String>{};
  final playlists = <String, List<String>>{};
  String? activePlaylist;
  String? error;
  int currentIndex = -1;
  bool isPlaying = false;
  bool libraryHome = true;
  bool favoritesOnly = false;
  bool sortAscending = true;
  String query = '';
  int repeat = 0;
  bool shuffle = false;
  double playbackSpeed = 1.0;
  int pitchSemitones = 0;
  double pitchCents = 0.0;
  double positionSeconds = 0;
  double durationSeconds = 0;
  double? scrubPosition;
  bool draggingSeek = false;
  bool waveformVisible = false;
  final waveformLevels = ValueNotifier<List<double>>(List.filled(48, 0));
  List<double> waveformTarget = List.filled(48, 0);
  Ticker? spectrumTicker;
  Timer? pollTimer;
  bool pollBusy = false;
  int tick = 0;
  double playerDrag = 0;
  bool draggingPlayer = false;
  bool dismissingPlayer = false;

  @override
  void initState() {
    super.initState();
    nativeDsp.setMethodCallHandler((call) async {
      if (call.method != 'nativePlaybackEvent' || !mounted) return;
      final state = Map<String, dynamic>.from(call.arguments as Map);
      applyNativeState(state);
      if (state['error'] is String) setState(() => error = state['error'] as String);
    });
    restoreLibrary();
    spectrumTicker = createTicker((_) {
      if (!waveformVisible || !mounted) return;
      final previous = waveformLevels.value;
      final next = List<double>.generate(waveformTarget.length, (i) {
        final target = isPlaying ? waveformTarget[i] : 0.0;
        final before = previous[i];
        return before + (target - before) * (target > before ? 0.38 : 0.16);
      });
      waveformLevels.value = next;
    });
    // Timeline and spectrum sampling are distinct from the display's vsync.
    pollTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => pollNative());
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    spectrumTicker?.dispose();
    waveformLevels.dispose();
    nativeDsp.setMethodCallHandler(null);
    // The iOS audio session owns playback lifecycle; hiding this widget must not
    // accidentally stop audio playing in the background.
    super.dispose();
  }

  Future<void> pollNative() async {
    if (pollBusy || files.isEmpty) return;
    pollBusy = true;
    try {
      final response = await nativeDsp.invokeMapMethod<String, dynamic>('getState');
      if (!mounted || response == null) return;
      tick++;
      if (waveformVisible) {
        final values = response['waveform'];
        if (values is List) {
          waveformTarget = values.map((v) => (v as num).toDouble().clamp(0.0, 1.0).toDouble()).toList();
        }
      }
      applyNativeState(response, repaint: !libraryHome || tick % 5 == 0);
    } on PlatformException catch (e) {
      if (mounted && error == null) setState(() => error = 'Native audio: ${e.message}');
    } finally {
      pollBusy = false;
    }
  }

  void applyNativeState(Map<String, dynamic> state, {bool repaint = true}) {
    final newIndex = (state['index'] as num?)?.toInt();
    final indexChanged = newIndex != null && newIndex >= 0 &&
        newIndex < files.length && newIndex != currentIndex;
    void apply() {
      if (newIndex != null && newIndex >= -1 && newIndex < files.length) currentIndex = newIndex;
      if (state['playing'] is bool) isPlaying = state['playing'] as bool;
      if (state['position'] is num) positionSeconds = (state['position'] as num).toDouble();
      if (state['duration'] is num) durationSeconds = (state['duration'] as num).toDouble();
    }
    if (repaint || indexChanged) {
      if (mounted) setState(apply);
    } else {
      apply();
    }
  }

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
    await manifest.writeAsString(jsonEncode({
      'files': files, 'favorites': favorites.toList(), 'playlists': playlists,
      'shuffle': shuffle, 'repeat': repeat, 'speed': playbackSpeed,
      'pitchCents': pitchCents, 'pitchSemitones': pitchSemitones,
      'originalNames': originalNames,
    }));
  }

  Future<void> syncQueue() async {
    await nativeDsp.invokeMethod('setQueue', {
      'paths': List<String>.of(files), 'shuffle': shuffle, 'repeat': repeat,
    });
  }

  Future<void> updateNativePitchTempo() async {
    try {
      await nativeDsp.invokeMethod('setTimePitch', {
        'tempo': playbackSpeed,
        'cents': (pitchSemitones * 100 + pitchCents).clamp(-1200.0, 1200.0).toDouble(),
      });
      await saveLibrary();
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Audio processing: ${e.message}');
    }
  }

  Future<void> restoreLibrary() async {
    try {
      final manifest = await libraryManifest();
      if (await manifest.exists()) {
        final decoded = jsonDecode(await manifest.readAsString());
        final saved = (decoded is List ? decoded : decoded['files'] as List).cast<String>();
        if (decoded is Map) {
          if (decoded['favorites'] is List) favorites.addAll((decoded['favorites'] as List).whereType<String>());
          shuffle = decoded['shuffle'] == true;
          repeat = (decoded['repeat'] is int ? decoded['repeat'] as int : 0).clamp(0, 2);
          pitchSemitones = (decoded['pitchSemitones'] is int ? decoded['pitchSemitones'] as int : 0).clamp(-12, 12);
          pitchCents = (decoded['pitchCents'] is num ? decoded['pitchCents'] as num : 0).toDouble().clamp(-99.0, 99.0).toDouble();
          playbackSpeed = (decoded['speed'] is num ? decoded['speed'] as num : 1).toDouble().clamp(0.5, 2.0).toDouble();
          if (decoded['originalNames'] is Map) {
            (decoded['originalNames'] as Map).forEach((path, name) {
              if (path is String && name is String) originalNames[path] = name;
            });
          }
          if (decoded['playlists'] is Map) {
            (decoded['playlists'] as Map).forEach((name, entries) {
              if (name is String && entries is List) playlists[name] = entries.whereType<String>().toList();
            });
          }
        }
        for (final path in saved) {
          if (await File(path).exists()) files.add(path);
        }
        // Restore old 'GBA_1' imports when the original 'GBA' also exists.
        for (final path in files) {
          if (originalNames.containsKey(path)) continue;
          final raw = Uri.file(path).pathSegments.last;
          final match = RegExp(r'^(.*)_\d+(\.[^.]+)$').firstMatch(raw);
          if (match == null) continue;
          final canonical = match.group(1)! + match.group(2)!;
          final parent = File(path).parent.path;
          if (await File(parent + '/' + canonical).exists()) {
            originalNames[path] = canonical;
          }
        }
        for (final songs in playlists.values) { songs.removeWhere((path) => !files.contains(path)); }
      }
      await syncQueue();
      await updateNativePitchTempo();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = 'Could not restore library: $e');
    }
  }

  Future<bool> isSameAudio(File a, File b) async {
    if (!await b.exists() || await a.length() != await b.length()) return false;
    final left = await a.open();
    final right = await b.open();
    try {
      while (true) {
        final x = await left.read(65536);
        final y = await right.read(65536);
        if (x.length != y.length) return false;
        if (x.isEmpty) return true;
        for (var i = 0; i < x.length; i++) {
          if (x[i] != y[i]) return false;
        }
      }
    } finally {
      await left.close();
      await right.close();
    }
  }

  Future<void> import() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['flac', 'mp3', 'm4a', 'wav', 'aac'],
        allowMultiple: true,
      );
      if (picked == null) return;
      final directory = await musicDirectory();
      var imported = 0;
      var skipped = 0;
      for (final entry in picked.files) {
        final sourcePath = entry.path;
        if (sourcePath == null || !await File(sourcePath).exists()) continue;
        final source = File(sourcePath);
        final originalName = entry.name;
        final safeName = originalName.replaceAll(RegExp(r'[/\\]'), '_');
        var duplicate = false;
        for (final path in files) {
          final known = originalNames[path] ?? Uri.file(path).pathSegments.last;
          final nameMatches = known == originalName ||
            known.replaceFirst(RegExp(r'_\d+(?=\.[^.]+$)'), '') == originalName;
          if (nameMatches && await isSameAudio(source, File(path))) {
            duplicate = true;
            skipped++;
            break;
          }
        }
        if (duplicate) continue;
        var target = File(directory.path + '/' + safeName);
        var counter = 1;
        while (await target.exists()) {
          final dot = safeName.lastIndexOf('.');
          final base = dot > 0 ? safeName.substring(0, dot) : safeName;
          final ext = dot > 0 ? safeName.substring(dot) : '';
          target = File(directory.path + '/' + base + '_' + (counter++).toString() + ext);
        }
        await source.copy(target.path);
        originalNames[target.path] = originalName;
        files.add(target.path);
        imported++;
      }
      if (imported == 0 && skipped == 0) throw Exception('No accessible audio files returned');
      if (imported > 0) await syncQueue();
      await saveLibrary();
      if (mounted) {
        setState(() => error = null);
        if (skipped > 0) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(skipped == 1 ? 'Already imported — original title preserved.'
              : '$skipped existing tracks skipped — original titles preserved.'),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> selectAndPlayTrack(int index) async {
    if (index < 0 || index >= files.length) return;
    try {
      await nativeDsp.invokeMethod('playIndex', {'index': index});
      if (mounted) setState(() {
        currentIndex = index; isPlaying = true; positionSeconds = 0; error = null;
      });
      await setNativeTitle();
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Playback: ${e.message}');
    }
  }

  Future<void> setNativeTitle() async {
    if (currentIndex < 0 || currentIndex >= files.length) return;
    await nativeDsp.invokeMethod('setNowPlaying', {'title': displayName(files[currentIndex])});
  }

  Future<void> togglePlayback() async {
    if (files.isEmpty) return;
    if (currentIndex < 0 || (!isPlaying && durationSeconds <= 0)) {
      await selectAndPlayTrack(currentIndex < 0 ? 0 : currentIndex);
      return;
    }
    final shouldPlay = !isPlaying;
    try {
      if (shouldPlay) {
        final confirmed = await nativeDsp.invokeMethod<bool>('resumeFile');
        if (confirmed != true) {
          throw PlatformException(code: 'AUDIO_SESSION', message: 'iOS did not restart audio output');
        }
      } else {
        await nativeDsp.invokeMethod('pauseFile');
      }
      // Never show a playing state unless the actual native engine confirms it.
      final state = await nativeDsp.invokeMapMethod<String, dynamic>('getState');
      if (state != null) applyNativeState(state);
      if (mounted) setState(() => error = null);
    } on PlatformException catch (e) {
      if (mounted) setState(() {
        isPlaying = false;
        error = 'Playback: ${e.message}';
      });
    }
  }

  Future<void> skipTrack(int delta) async {
    if (files.isEmpty) return;
    if (currentIndex < 0) { await selectAndPlayTrack(0); return; }
    try {
      final next = await nativeDsp.invokeMethod<int>('skipFile', {'delta': delta});
      if (next != null && mounted) setState(() => currentIndex = next);
      await setNativeTitle();
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Skip: ${e.message}');
    }
  }

  Future<void> seekTo(double seconds) async {
    if (currentIndex < 0) return;
    try {
      await nativeDsp.invokeMethod('seekFile', {'position': seconds.clamp(0.0, durationSeconds).toDouble()});
      if (mounted) setState(() => positionSeconds = seconds.clamp(0.0, durationSeconds).toDouble());
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Seek: ${e.message}');
    }
  }

  Future<void> seekSeconds(int seconds) async => seekTo(positionSeconds + seconds);

  Future<void> toggleWaveform() async {
    final enabled = !waveformVisible;
    await nativeDsp.invokeMethod('setWaveformEnabled', {'enabled': enabled});
    if (mounted) setState(() {
      waveformVisible = enabled;
      if (!enabled) {
        waveformTarget = List.filled(48, 0);
        waveformLevels.value = List.filled(48, 0);
      }
    });
    if (enabled) {
      spectrumTicker?.start();
    } else {
      spectrumTicker?.stop();
    }
  }

  void showLibrary() {
    if (dismissingPlayer) return;
    setState(() {
      libraryHome = true;
      playerDrag = 0;
    });
  }

  void showPlayer() {
    if (!libraryHome) return;
    final height = MediaQuery.sizeOf(context).height;
    setState(() { libraryHome = false; playerDrag = height; draggingPlayer = true; });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() { draggingPlayer = false; playerDrag = 0; });
    });
  }

  void finishPlayerDrag(DragEndDetails details) {
    draggingPlayer = false;
    final height = MediaQuery.sizeOf(context).height;
    if (playerDrag > height * 0.18 || (details.primaryVelocity ?? 0) > 650) {
      dismissingPlayer = true;
      setState(() => playerDrag = height);
      Future<void>.delayed(const Duration(milliseconds: 285), () {
        if (mounted) setState(() {
          libraryHome = true; playerDrag = 0; dismissingPlayer = false;
        });
      });
    } else {
      setState(() => playerDrag = 0);
    }
  }

  String displayName(String path) {
    final raw = originalNames[path] ?? Uri.file(path).pathSegments.last;
    return raw.replaceFirst(RegExp(r'\.(flac|mp3|m4a|wav|aac)$', caseSensitive: false), '');
  }
  String get title => currentIndex < 0 || currentIndex >= files.length
      ? 'Your music awaits' : displayName(files[currentIndex]);
  String clock(double seconds) {
    final total = seconds.isFinite ? seconds.floor().clamp(0, 360000) : 0;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
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
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Add to playlist')),
        for (final name in playlists.keys)
          ListTile(leading: const Icon(Icons.playlist_add), title: Text(name),
            onTap: () => Navigator.pop(context, name)),
      ])),
    );
    if (selected == null || !playlists.containsKey(selected)) return;
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
    showModalBottomSheet<void>(context: context, builder: (sheet) => SafeArea(child:
      Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.edit), title: const Text('Rename playlist'), onTap: () {
          Navigator.pop(sheet); renamePlaylist(name);
        }),
        ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete playlist'), onTap: () async {
          Navigator.pop(sheet);
          setState(() { playlists.remove(name); if (activePlaylist == name) activePlaylist = null; });
          await saveLibrary();
        }),
      ])));
  }

  void trackMenu(String path) {
    showModalBottomSheet<void>(context: context, builder: (sheet) => SafeArea(child:
      Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.playlist_add), title: const Text('Add to playlist'),
          onTap: () { Navigator.pop(sheet); addToPlaylist(path); }),
        ListTile(leading: Icon(favorites.contains(path) ? Icons.favorite : Icons.favorite_border),
          title: Text(favorites.contains(path) ? 'Remove from favorites' : 'Add to favorites'),
          onTap: () { Navigator.pop(sheet); toggleFavorite(path); }),
      ])));
  }

  Future<void> moveQueuedTrack(int from, int to) async {
    if (from < 0 || from >= files.length || to < 0 || to >= files.length) return;
    setState(() {
      final path = files.removeAt(from);
      files.insert(to, path);
      if (currentIndex == from) currentIndex = to;
      else if (from < currentIndex && to >= currentIndex) currentIndex--;
      else if (from > currentIndex && to <= currentIndex) currentIndex++;
    });
    await syncQueue();
    await saveLibrary();
  }

  void showQueue() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (sheet) =>
      SafeArea(child: FractionallySizedBox(heightFactor: 0.78, child: Column(children: [
        const ListTile(title: Text('Up Next'), subtitle: Text('Drag the handles to reorder playback')),
        Expanded(child: StatefulBuilder(builder: (context, refresh) => ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: files.length,
          onReorder: (oldIndex, newIndex) async {
            if (newIndex > oldIndex) newIndex--;
            await moveQueuedTrack(oldIndex, newIndex);
            refresh(() {});
          },
          itemBuilder: (_, index) => ListTile(
            key: ValueKey(files[index]),
            leading: Icon(index == currentIndex ? Icons.graphic_eq : Icons.music_note),
            title: Text(displayName(files[index]), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: index == currentIndex ? const Text('Now playing') : null,
            onTap: () async { Navigator.pop(sheet); await selectAndPlayTrack(index); },
            trailing: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
          ),
        ))),
      ]))));
  }

  Future<void> showPitchWheel(StateSetter refresh) async {
    await showModalBottomSheet<void>(context: context, backgroundColor: const Color(0xFF343438),
      isScrollControlled: true, builder: (sheet) => SafeArea(child: SizedBox(height: 340,
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close)),
            const Expanded(child: Text('Adjust Pitch', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(width: 48),
          ]),
          const Row(children: [
            Expanded(child: Center(child: Text('Semitones'))),
            Expanded(child: Center(child: Text('Cents'))),
          ]),
          Expanded(child: Row(children: [
            Expanded(child: CupertinoPicker(
              scrollController: FixedExtentScrollController(initialItem: pitchSemitones + 12),
              itemExtent: 44,
              onSelectedItemChanged: (i) {
                refresh(() => pitchSemitones = i - 12);
                setState(() {});
                updateNativePitchTempo();
              },
              children: [for (var i = -12; i <= 12; i++) Center(child: Text('${i >= 0 ? '+' : ''}$i'))],
            )),
            Expanded(child: CupertinoPicker(
              scrollController: FixedExtentScrollController(initialItem: pitchCents.round() + 99),
              itemExtent: 44,
              onSelectedItemChanged: (i) {
                refresh(() => pitchCents = (i - 99).toDouble());
                setState(() {});
                updateNativePitchTempo();
              },
              children: [for (var i = -99; i <= 99; i++) Center(child: Text('${i >= 0 ? '+' : ''}$i'))],
            )),
          ])),
        ]),
      )));
  }

  Future<void> showTempoWheel(StateSetter refresh) async {
    await showModalBottomSheet<void>(context: context, backgroundColor: const Color(0xFF343438),
      isScrollControlled: true, builder: (sheet) => SafeArea(child: SizedBox(height: 330,
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close)),
            const Expanded(child: Text('Adjust Tempo', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(width: 48),
          ]),
          Expanded(child: CupertinoPicker(
            scrollController: FixedExtentScrollController(initialItem: (playbackSpeed * 100).round() - 50),
            itemExtent: 44,
            onSelectedItemChanged: (i) {
              refresh(() => playbackSpeed = (i + 50) / 100);
              setState(() {});
              updateNativePitchTempo();
            },
            children: [for (var i = 50; i <= 200; i++) Center(child: Text('$i%'))],
          )),
        ]),
      )));
  }

  void showAudioSettings() {
    showModalBottomSheet<void>(context: context, isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, refresh) => SafeArea(
        child: Padding(padding: const EdgeInsets.all(18), child: Column(mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Pitch and tempo', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Adjust the one native audio engine. Your original FLAC files remain unchanged.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            Text('Pitch: ${pitchSemitones >= 0 ? '+' : ''}$pitchSemitones semitones · ${pitchCents >= 0 ? '+' : ''}${pitchCents.toStringAsFixed(0)} cents'),
            // One combined pitch control. Tap anywhere on it to open BOTH
            // precise iOS picker wheels; a second fine-pitch slider is gone.
            Semantics(
              button: true,
              label: 'Adjust pitch in semitones and cents',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showPitchWheel(refresh),
                child: AbsorbPointer(child: Slider(
                  value: ((pitchSemitones * 100 + pitchCents) / 100).clamp(-12.0, 12.0).toDouble(),
                  min: -12, max: 12,
                  onChanged: (_) {},
                )),
              ),
            ),
            TextButton(onPressed: () => showTempoWheel(refresh),
              child: Text('Tempo: ${(playbackSpeed * 100).round()}%')),
            Slider(value: playbackSpeed, min: 0.5, max: 2.0, divisions: 150,
              onChanged: (value) { refresh(() => playbackSpeed = value); setState(() {}); },
              onChangeEnd: (_) => updateNativePitchTempo()),
            TextButton(onPressed: () async {
              refresh(() { pitchSemitones = 0; pitchCents = 0; playbackSpeed = 1; });
              setState(() {});
              await updateNativePitchTempo();
            }, child: const Text('Reset pitch and tempo')),
          ],
        )),
      )));
  }

  Widget buildLibrary() {
    final matches = List<int>.generate(files.length, (i) => i).where((i) =>
      (activePlaylist == null || (playlists[activePlaylist]?.contains(files[i]) ?? false)) &&
      (!favoritesOnly || favorites.contains(files[i])) &&
      displayName(files[i]).toLowerCase().contains(query.toLowerCase())).toList()
      ..sort((a, b) => sortAscending
          ? displayName(files[a]).toLowerCase().compareTo(displayName(files[b]).toLowerCase())
          : displayName(files[b]).toLowerCase().compareTo(displayName(files[a]).toLowerCase()));
    return Scaffold(
      appBar: AppBar(title: const Text('Your Library'), actions: [
        IconButton(tooltip: 'New playlist', icon: const Icon(Icons.playlist_add), onPressed: createPlaylist),
        IconButton(tooltip: 'Import music', icon: const Icon(Icons.add), onPressed: import),
      ]),
      body: SafeArea(child: Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: TextField(
          onChanged: (value) => setState(() => query = value),
          decoration: const InputDecoration(hintText: 'Search songs', prefixIcon: Icon(Icons.search)),
        )),
        SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          ChoiceChip(label: const Text('Library'), selected: activePlaylist == null,
            onSelected: (_) => setState(() => activePlaylist = null)),
          const SizedBox(width: 8),
          for (final name in playlists.keys) ...[
            InputChip(label: Text(name), selected: activePlaylist == name,
              onSelected: (_) => setState(() => activePlaylist = name),
              onDeleted: () => playlistMenu(name), deleteIcon: const Icon(Icons.more_horiz, size: 18)),
            const SizedBox(width: 8),
          ],
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          ChoiceChip(label: const Text('All songs'), selected: !favoritesOnly,
            onSelected: (_) => setState(() => favoritesOnly = false)),
          const SizedBox(width: 8),
          ChoiceChip(label: const Text('Favorites'), selected: favoritesOnly,
            onSelected: (_) => setState(() => favoritesOnly = true)),
          const Spacer(),
          IconButton(tooltip: 'Change sort order',
            icon: Icon(sortAscending ? Icons.sort_by_alpha : Icons.sort),
            onPressed: () => setState(() => sortAscending = !sortAscending)),
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
          child: Align(alignment: Alignment.centerLeft,
            child: Text(activePlaylist == null ? '${files.length} songs' :
              '${activePlaylist!} • ${matches.length} songs',
              style: const TextStyle(color: Colors.white60)))),
        Expanded(child: files.isEmpty
          ? Center(child: FilledButton.icon(onPressed: import, icon: const Icon(Icons.add),
              label: const Text('Import your music')))
          : ListView.builder(itemCount: matches.length, itemBuilder: (_, row) {
              final index = matches[row];
              return ListTile(
                leading: const Icon(Icons.music_note, color: Colors.tealAccent),
                title: Text(displayName(files[index]), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(index == currentIndex ? 'Now playing' : 'Local audio',
                  style: const TextStyle(color: Colors.white60)),
                trailing: IconButton(tooltip: 'Song options', icon: const Icon(Icons.more_vert),
                  onPressed: () => trackMenu(files[index])),
                onTap: () async {
                  await selectAndPlayTrack(index);
                  if (mounted) showPlayer();
                },
              );
            })),
        if (currentIndex >= 0 && currentIndex < files.length) AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          color: const Color(0xFF29483F),
          child: ListTile(
            leading: const Icon(Icons.graphic_eq, color: Colors.tealAccent),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
            onTap: showPlayer,
            trailing: IconButton(
              icon: AnimatedSwitcher(duration: const Duration(milliseconds: 180),
                child: Icon(isPlaying ? Icons.pause : Icons.play_arrow,
                  key: ValueKey(isPlaying))),
              onPressed: togglePlayback,
            ),
          ),
        ),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
      ])),
    );
  }

  Widget buildPlayer() {
    final effectivePosition = draggingSeek && scrubPosition != null ? scrubPosition! : positionSeconds;
    final maximum = math.max(durationSeconds, 0.001);
    return Scaffold(
      backgroundColor: const Color(0xFF101218),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(tooltip: 'Minimize player', icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: showLibrary),
        title: const Text('Now Playing'),
        actions: [
          IconButton(tooltip: 'Toggle live waveform', onPressed: toggleWaveform,
            color: waveformVisible ? Colors.tealAccent : Colors.white,
            icon: const Icon(Icons.waves)),
          IconButton(tooltip: 'Queue', icon: const Icon(Icons.queue_music), onPressed: showQueue),
          IconButton(tooltip: 'Import music', icon: const Icon(Icons.add_circle_outline), onPressed: import),
        ],
      ),
      body: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(22, 6, 22, 14),
        child: Column(children: [
          const Spacer(),
          Expanded(flex: 5, child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(colors: [Color(0xFF295548), Color(0xFF181B2B)])),
            child: const Center(child: Icon(Icons.music_note, size: 120, color: Color(0xFF9BE9C6))),
          )),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold))),
            if (currentIndex >= 0 && currentIndex < files.length)
              IconButton(tooltip: 'Favorite',
                onPressed: () => toggleFavorite(files[currentIndex]),
                icon: Icon(favorites.contains(files[currentIndex]) ? Icons.favorite : Icons.favorite_border,
                  color: const Color(0xFF9BE9C6))),
          ]),
          AnimatedSize(duration: const Duration(milliseconds: 280), curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: waveformVisible ? Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: SizedBox(height: 58, width: double.infinity,
                child: ValueListenableBuilder<List<double>>(
                  valueListenable: waveformLevels,
                  builder: (_, levels, __) => CustomPaint(
                    painter: LiveWaveformPainter(levels, isPlaying: isPlaying),
                  ),
                ),
              ),
            ) : const SizedBox(width: double.infinity, height: 0),
          ),
          const SizedBox(height: 12),
          Slider(value: effectivePosition.clamp(0.0, maximum).toDouble(), max: maximum,
            onChangeStart: durationSeconds <= 0 ? null :
              (value) => setState(() { draggingSeek = true; scrubPosition = value; }),
            onChanged: durationSeconds <= 0 ? null :
              (value) => setState(() => scrubPosition = value),
            onChangeEnd: durationSeconds <= 0 ? null : (value) async {
              await seekTo(value);
              if (mounted) setState(() { draggingSeek = false; scrubPosition = null; });
            }),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(clock(effectivePosition), style: const TextStyle(color: Colors.white70)),
            Text(clock(durationSeconds), style: const TextStyle(color: Colors.white70)),
          ]),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(tooltip: 'Shuffle', color: shuffle ? Colors.tealAccent : Colors.white,
              onPressed: () async {
                setState(() => shuffle = !shuffle);
                await syncQueue(); await saveLibrary();
              }, icon: const Icon(Icons.shuffle)),
            IconButton(tooltip: 'Previous track', onPressed: files.isEmpty ? null : () => skipTrack(-1),
              icon: const Icon(Icons.skip_previous), iconSize: 36),
            IconButton.filled(onPressed: files.isEmpty ? import : togglePlayback,
              icon: AnimatedSwitcher(duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
                child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, key: ValueKey(isPlaying), size: 38))),
            IconButton(tooltip: 'Next track', onPressed: files.isEmpty ? null : () => skipTrack(1),
              icon: const Icon(Icons.skip_next), iconSize: 36),
            Column(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Repeat mode', color: repeat == 0 ? Colors.white : Colors.tealAccent,
                onPressed: () async {
                  setState(() => repeat = (repeat + 1) % 3);
                  await syncQueue(); await saveLibrary();
                }, icon: Icon(repeat == 2 ? Icons.repeat_one : Icons.repeat)),
              Text(['OFF', 'ALL', 'ONE'][repeat],
                style: const TextStyle(fontSize: 10, color: Colors.white)),
            ]),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Back 10 seconds', iconSize: 32,
              onPressed: currentIndex < 0 ? null : () => seekSeconds(-10),
              icon: const Icon(Icons.replay_10)),
            const SizedBox(width: 16),
            IconButton(tooltip: 'Forward 10 seconds', iconSize: 32,
              onPressed: currentIndex < 0 ? null : () => seekSeconds(10),
              icon: const Icon(Icons.forward_10)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton.icon(onPressed: showLibrary, icon: const Icon(Icons.library_music),
              label: const Text('Library')),
            TextButton.icon(onPressed: showQueue, icon: const Icon(Icons.queue_music),
              label: const Text('Queue')),
            if (currentIndex >= 0 && currentIndex < files.length)
              IconButton(tooltip: 'Add to playlist', icon: const Icon(Icons.playlist_add),
                onPressed: () => addToPlaylist(files[currentIndex])),
          ]),
          const SizedBox(height: 4),
          TextButton.icon(onPressed: showAudioSettings, icon: const Icon(Icons.tune),
            label: const Text('Pitch and tempo')),
          if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
          const Spacer(),
        ]),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      buildLibrary(),
      if (!libraryHome) AnimatedContainer(
        duration: draggingPlayer ? Duration.zero : const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, playerDrag, 0),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (_) => setState(() => draggingPlayer = true),
          onVerticalDragUpdate: (details) => setState(() {
            playerDrag = (playerDrag + details.delta.dy).clamp(0.0, MediaQuery.sizeOf(context).height).toDouble();
          }),
          onVerticalDragEnd: finishPlayerDrag,
          onVerticalDragCancel: () => setState(() { draggingPlayer = false; playerDrag = 0; }),
          child: buildPlayer(),
        ),
      ),
    ]);
  }
}

/// Displays the most recently rendered PCM samples, not an overview of the file.
class LiveWaveformPainter extends CustomPainter {
  final List<double> samples;
  final bool isPlaying;
  const LiveWaveformPainter(this.samples, {required this.isPlaying});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = isPlaying ? const Color(0xFF9BE9C6) : const Color(0xFF6B8E84);
    final count = samples.length;
    if (count == 0) return;
    final stride = size.width / count;
    final width = math.max(2.0, stride * 0.53);
    for (var i = 0; i < count; i++) {
      final height = math.max(3.0, samples[i].clamp(0.0, 1.0).toDouble() * size.height);
      final left = i * stride + (stride - width) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, (size.height - height) / 2, width, height),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, paint);
    }
  }
  @override
  bool shouldRepaint(covariant LiveWaveformPainter old) =>
      old.isPlaying != isPlaying || old.samples != samples;
}
