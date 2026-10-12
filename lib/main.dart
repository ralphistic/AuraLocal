import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
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
  final eqGains = List<double>.filled(10, 0);
  final customEqPresets = <String, List<double>>{};
  bool eqEnabled = false;
  String eqPreset = 'Flat';
  static const eqFrequencies = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];
  static const eqPresets = <String, List<double>>{
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Warm': [3, 3, 2, 1, 0, 0, -1, -1, 0, 0],
    'Bass Boost': [6, 5, 4, 2, 0, -1, -1, 0, 0, 0],
    'Vocal Clarity': [-2, -2, -1, 0, 1, 2, 3, 3, 1, 0],
    'Bright': [-1, 0, 0, 0, 0, 1, 2, 3, 4, 3],
    'V-shaped': [4, 3, 1, -1, -2, -1, 1, 3, 4, 3],
    'Soft': [1, 1, 0, 0, 0, -1, -2, -2, -2, -1],
  };
  static const Color activeEqAccent = Color(0xFF9BE9C6);
  Timer? eqDebounce;
  final favorites = <String>{};
  final playlists = <String, List<String>>{};
  String? activePlaylist;
  String? error;
  int currentIndex = -1;
  bool isPlaying = false;
  bool libraryHome = true;
  bool favoritesOnly = false;
  bool sortAscending = true;
  String sortMode = 'alphabetical';
  final dateAdded = <String, int>{};
  final trackDurations = <String, double>{};
  bool isLibraryExporting = false;
  bool isLibraryRestoring = false;
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
  double miniSwipeTravel = 0;
  Timer? dspWheelDebounce;
  Offset? pitchTouchStart;
  bool pitchTouchMoved = false;

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
    dspWheelDebounce?.cancel();
    eqDebounce?.cancel();
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
      'eqGains': eqGains, 'eqEnabled': eqEnabled,
      'eqPreset': eqPreset, 'customEqPresets': customEqPresets,
      'sortMode': sortMode, 'sortAscending': sortAscending,
      'dateAdded': dateAdded, 'trackDurations': trackDurations,
    }));
  }

  Future<void> syncQueue() async {
    await nativeDsp.invokeMethod('setQueue', {
      'paths': List<String>.of(files), 'shuffle': shuffle, 'repeat': repeat,
    });
  }

  void scheduleNativePitchTempoUpdate() {
    dspWheelDebounce?.cancel();
    dspWheelDebounce = Timer(const Duration(milliseconds: 240), () {
      updateNativePitchTempo();
    });
  }

  Future<void> updateNativePitchTempo() async {
    dspWheelDebounce?.cancel();
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
          if (decoded['eqGains'] is List) {
            final levels = decoded['eqGains'] as List;
            if (levels.length == 10) {
              for (var i = 0; i < 10; i++) {
                if (levels[i] is num) {
                  eqGains[i] = (levels[i] as num).toDouble().clamp(-12.0, 12.0).toDouble();
                }
              }
            }
          }
          eqEnabled = decoded['eqEnabled'] == true;
          final rememberedPreset = decoded['eqPreset'];
          if (rememberedPreset is String) eqPreset = rememberedPreset;
          final custom = decoded['customEqPresets'];
          if (custom is Map) {
            custom.forEach((name, gains) {
              if (name is String && gains is List && gains.length == 10 &&
                  gains.every((v) => v is num)) {
                customEqPresets[name] = gains
                  .map((v) => (v as num).toDouble().clamp(-12.0, 12.0).toDouble())
                  .toList();
              }
            });
          }
          final storedMode = decoded['sortMode'];
          if (storedMode is String && ['alphabetical', 'dateAdded', 'length'].contains(storedMode)) {
            sortMode = storedMode;
          }
          if (decoded['sortAscending'] is bool) sortAscending = decoded['sortAscending'] as bool;
          if (decoded['dateAdded'] is Map) {
            (decoded['dateAdded'] as Map).forEach((path, value) {
              if (path is String && value is num) dateAdded[path] = value.toInt();
            });
          }
          if (decoded['trackDurations'] is Map) {
            (decoded['trackDurations'] as Map).forEach((path, value) {
              if (path is String && value is num) trackDurations[path] = value.toDouble();
            });
          }
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
          if (await File(path).exists()) {
            files.add(path);
            dateAdded.putIfAbsent(path, () => File(path).lastModifiedSync().millisecondsSinceEpoch);
          }
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
      await applyNativeEQ();
      if (mounted) setState(() {});
      // Metadata probing never plays or interrupts a track.
      await loadMissingDurations();
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
        dateAdded[target.path] = DateTime.now().millisecondsSinceEpoch;
        files.add(target.path);
        imported++;
      }
      if (imported == 0 && skipped == 0) throw Exception('No accessible audio files returned');
      if (imported > 0) await syncQueue();
      await saveLibrary();
      if (imported > 0) await loadMissingDurations();
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

  void showLibrary() => dismissPlayer();

  void dismissPlayer() {
    if (libraryHome || dismissingPlayer) return;
    final height = MediaQuery.sizeOf(context).height;
    setState(() {
      dismissingPlayer = true;
      draggingPlayer = false;
      playerDrag = height;
    });
    Future<void>.delayed(const Duration(milliseconds: 290), () {
      if (mounted && dismissingPlayer) {
        setState(() {
          libraryHome = true;
          playerDrag = 0;
          dismissingPlayer = false;
        });
      }
    });
  }

  void showPlayer() {
    if (!libraryHome) return;
    final height = MediaQuery.sizeOf(context).height;
    setState(() {
      libraryHome = false;
      dismissingPlayer = false;
      playerDrag = height;
      draggingPlayer = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() { draggingPlayer = false; playerDrag = 0; });
    });
  }

  void startMiniSwipe() {
    if (!libraryHome) return;
    miniSwipeTravel = 0;
    setState(() {
      libraryHome = false;
      playerDrag = MediaQuery.sizeOf(context).height;
      draggingPlayer = true;
      dismissingPlayer = false;
    });
  }

  void updateMiniSwipe(DragUpdateDetails details) {
    miniSwipeTravel += details.delta.dy;
    setState(() {
      playerDrag = (MediaQuery.sizeOf(context).height + miniSwipeTravel)
          .clamp(0.0, MediaQuery.sizeOf(context).height).toDouble();
    });
  }

  void finishMiniSwipe(DragEndDetails details) {
    final rise = -miniSwipeTravel;
    if (rise > 34 || (details.primaryVelocity ?? 0) < -220) {
      // A short upward swipe magnetically opens the full player.
      setState(() {
        playerDrag = 0;
        draggingPlayer = false;
      });
    } else {
      dismissPlayer();
    }
  }

  void finishPlayerDrag(DragEndDetails details) {
    draggingPlayer = false;
    final height = MediaQuery.sizeOf(context).height;
    if (playerDrag > height * 0.12 || (details.primaryVelocity ?? 0) > 450) {
      dismissPlayer();
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
                scheduleNativePitchTempoUpdate();
              },
              children: [for (var i = -12; i <= 12; i++) Center(child: Text('${i >= 0 ? '+' : ''}$i'))],
            )),
            Expanded(child: CupertinoPicker(
              scrollController: FixedExtentScrollController(initialItem: pitchCents.round() + 99),
              itemExtent: 44,
              onSelectedItemChanged: (i) {
                refresh(() => pitchCents = (i - 99).toDouble());
                setState(() {});
                scheduleNativePitchTempoUpdate();
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
              scheduleNativePitchTempoUpdate();
            },
            children: [for (var i = 50; i <= 200; i++) Center(child: Text('$i%'))],
          )),
        ]),
      )));
  }


  Future<void> applyNativeEQ() async {
    try {
      await nativeDsp.invokeMethod('setEQ', {
        'gains': eqGains,
        'enabled': eqEnabled,
      });
      await saveLibrary();
      if (mounted && error?.startsWith('Equalizer:') == true) {
        setState(() => error = null);
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Equalizer: ${e.message}');
    }
  }

  void scheduleEQUpdate() {
    eqDebounce?.cancel();
    eqDebounce = Timer(const Duration(milliseconds: 75), () {
      applyNativeEQ();
    });
  }

  void chooseEQPreset(String name, StateSetter refresh) {
    final values = eqPresets[name];
    if (values == null) return;
    refresh(() {
      eqPreset = name;
      for (var i = 0; i < eqGains.length; i++) {
        eqGains[i] = values[i];
      }
    });
    setState(() {});
    applyNativeEQ();
  }

  void showEqualizer() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B26),
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          final accent = activeEqAccent;
          final screenHeight = MediaQuery.sizeOf(sheetContext).height;
          return SafeArea(
            child: SizedBox(
              height: screenHeight * 0.76,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                child: Column(children: [
                  Row(children: [
                    Icon(Icons.equalizer, color: accent, size: 27),
                    const SizedBox(width: 12),
                    const Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Audio Equalizer', style: TextStyle(
                          fontSize: 21, fontWeight: FontWeight.bold)),
                        Text('10-band • native audio processing',
                          style: TextStyle(fontSize: 12, color: Colors.white60)),
                      ],
                    )),
                    Switch.adaptive(
                      value: eqEnabled,
                      activeColor: accent,
                      onChanged: (enabled) {
                        refresh(() => eqEnabled = enabled);
                        setState(() {});
                        applyNativeEQ();
                      },
                    ),
                  ]),
                  const SizedBox(height: 16),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final name in eqPresets.keys) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: ChoiceChip(
                            label: Text(name),
                            selected: eqPreset == name,
                            selectedColor: accent.withValues(alpha: 0.25),
                            onSelected: (_) => chooseEQPreset(name, refresh),
                          ),
                        ),
                      ],
                      ChoiceChip(
                        label: const Text('Custom'),
                        selected: eqPreset == 'Custom',
                        selectedColor: accent.withValues(alpha: 0.25),
                        onSelected: (_) => refresh(() => eqPreset = 'Custom'),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, limits) => Stack(children: [
                        Positioned.fill(child: CustomPaint(
                          painter: EqGridPainter(accent: accent),
                        )),
                        Row(crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < 10; i++)
                              Expanded(child: Column(children: [
                                Text(
                                  '${eqGains[i] >= 0 ? '+' : ''}${eqGains[i].toStringAsFixed(1)}',
                                  maxLines: 1,
                                  style: TextStyle(fontSize: 9.2,
                                    fontWeight: FontWeight.w600,
                                    color: accent),
                                ),
                                Expanded(child: RotatedBox(
                                  quarterTurns: 3,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3.5,
                                      activeTrackColor: accent,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: accent,
                                      overlayColor: accent.withValues(alpha: 0.15),
                                    ),
                                    child: Slider(
                                      min: -12, max: 12,
                                      divisions: 48,
                                      value: eqGains[i],
                                      onChanged: (v) {
                                        refresh(() {
                                          eqGains[i] = v;
                                          eqPreset = 'Custom';
                                        });
                                        scheduleEQUpdate();
                                      },
                                      onChangeEnd: (_) => applyNativeEQ(),
                                    ),
                                  ),
                                )),
                                const SizedBox(height: 4),
                                FittedBox(child: Text(eqFrequencies[i],
                                  style: const TextStyle(fontSize: 10.5,
                                    color: Colors.white70))),
                              ])),
                          ]),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Align(alignment: Alignment.centerLeft,
                    child: Text('Appearance', style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.white70))),
                  const SizedBox(height: 7),
                  SizedBox(height: 38,
                    child: ListView(scrollDirection: Axis.horizontal, children: [
                      for (final name in eqAccentColors.keys)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Tooltip(
                            message: name,
                            child: InkWell(
                              onTap: () {
                                refresh(() => eqAccent = name);
                                saveLibrary();
                              },
                              customBorder: const CircleBorder(),
                              child: CircleAvatar(
                                radius: 16,
                                backgroundColor: eqAccentColors[name],
                                child: eqAccent == name
                                  ? const Icon(Icons.check, size: 18, color: Colors.black87)
                                  : null,
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          refresh(() {
                            eqEnabled = false;
                          });
                          setState(() {});
                          applyNativeEQ();
                        },
                        icon: const Icon(Icons.power_settings_new),
                        label: const Text('Bypass'),
                      ),
                      TextButton.icon(
                        onPressed: () => chooseEQPreset('Flat', refresh),
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Reset bands'),
                      ),
                    ]),
                ]),
              ),
            ),
          );
        },
      ),
    );
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
              label: 'Pitch slider. Tap to open semitone and cent wheels; drag to change pitch.',
              child: Listener(
                onPointerDown: (event) {
                  pitchTouchStart = event.position;
                  pitchTouchMoved = false;
                },
                onPointerMove: (event) {
                  if (pitchTouchStart != null &&
                      (event.position - pitchTouchStart!).distance > 9) {
                    pitchTouchMoved = true;
                  }
                },
                onPointerUp: (event) {
                  final wasTap = !pitchTouchMoved && pitchTouchStart != null &&
                      (event.position - pitchTouchStart!).distance < 9;
                  pitchTouchStart = null;
                  if (wasTap) showPitchWheel(refresh);
                },
                onPointerCancel: (_) => pitchTouchStart = null,
                child: Slider(
                  value: ((pitchSemitones * 100 + pitchCents) / 100)
                      .clamp(-12.0, 12.0).toDouble(),
                  min: -12,
                  max: 12,
                  onChanged: (value) {
                    final cents = (value * 100).round().clamp(-1200, 1200);
                    refresh(() {
                      pitchSemitones = (cents / 100).truncate();
                      pitchCents = (cents - pitchSemitones * 100).toDouble();
                    });
                    setState(() {});
                    scheduleNativePitchTempoUpdate();
                  },
                  onChangeEnd: (_) => updateNativePitchTempo(),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => showPitchWheel(refresh),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Fine tune: semitones / cents'),
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


  Future<void> loadMissingDurations() async {
    final missing = files.where((p) => !trackDurations.containsKey(p)).toList();
    if (missing.isEmpty) return;
    try {
      // Native AVAudioFile provides durations without starting another player.
      for (var i = 0; i < missing.length; i += 24) {
        final batch = missing.skip(i).take(24).toList();
        final response = await nativeDsp.invokeListMethod<double>('probeDurations', {'paths': batch});
        if (response == null || response.length != batch.length) continue;
        for (var k = 0; k < batch.length; k++) {
          if (response[k].isFinite && response[k] >= 0) {
            trackDurations[batch[k]] = response[k];
          }
        }
      }
      await saveLibrary();
      if (mounted) setState(() {});
    } catch (_) {
      // Older build or an unreadable format: leave its length unknown.
    }
  }

  void chooseLibrarySort(String value) {
    setState(() {
      if (sortMode == value) {
        sortAscending = !sortAscending;
      } else {
        sortMode = value;
        sortAscending = value != 'dateAdded';
      }
    });
    saveLibrary();
    if (value == 'length') loadMissingDurations();
  }

  Widget buildLibrary() {
    final matches = List<int>.generate(files.length, (i) => i).where((i) =>
      (activePlaylist == null || (playlists[activePlaylist]?.contains(files[i]) ?? false)) &&
      (!favoritesOnly || favorites.contains(files[i])) &&
      displayName(files[i]).toLowerCase().contains(query.toLowerCase())).toList()
      ..sort((a, b) {
        int comparison;
        switch (sortMode) {
          case 'dateAdded':
            comparison = (dateAdded[files[a]] ?? 0).compareTo(dateAdded[files[b]] ?? 0);
            break;
          case 'length':
            comparison = (trackDurations[files[a]] ?? -1).compareTo(trackDurations[files[b]] ?? -1);
            break;
          default:
            comparison = displayName(files[a]).toLowerCase()
                .compareTo(displayName(files[b]).toLowerCase());
        }
        if (comparison == 0) comparison = a.compareTo(b);
        return sortAscending ? comparison : -comparison;
      });
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
          PopupMenuButton<String>(
            tooltip: 'Sort tracks',
            icon: const Icon(Icons.filter_list),
            onSelected: chooseLibrarySort,
            itemBuilder: (_) => [
              for (final item in [
                ('alphabetical', 'Alphabetical order'),
                ('dateAdded', 'Date added'),
                ('length', 'Track length'),
              ]) PopupMenuItem<String>(
                value: item.$1,
                child: Row(children: [
                  Expanded(child: Text(item.$2)),
                  if (sortMode == item.$1)
                    Icon(sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 18, color: activeEqAccent),
                ]),
              ),
            ],
          ),
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
                subtitle: Text(
                  index == currentIndex ? 'Now playing'
                      : trackDurations.containsKey(files[index])
                        ? clock(trackDurations[files[index]]!)
                        : 'Local audio',
                  style: const TextStyle(color: Colors.white60)),
                trailing: IconButton(tooltip: 'Song options', icon: const Icon(Icons.more_vert),
                  onPressed: () => trackMenu(files[index])),
                onTap: () async {
                  await selectAndPlayTrack(index);
                  if (mounted) showPlayer();
                },
              );
            })),
        if (currentIndex >= 0 && currentIndex < files.length) GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => startMiniSwipe(),
          onVerticalDragUpdate: updateMiniSwipe,
          onVerticalDragEnd: finishMiniSwipe,
          child: AnimatedContainer(
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
          IconButton(tooltip: 'Equalizer', icon: const Icon(Icons.equalizer),
            color: eqEnabled ? activeEqAccent : Colors.white,
            onPressed: showEqualizer),
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
              child: SizedBox(height: 76, width: double.infinity,
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

/// Single live horizontal EQ-frequency contour, driven by actual PCM analysis.
class LiveWaveformPainter extends CustomPainter {
  final List<double> samples;
  final bool isPlaying;
  const LiveWaveformPainter(this.samples, {required this.isPlaying});

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || size.width <= 0) return;
    final baseline = size.height * 0.80;
    final span = size.height * 0.68;
    final points = <Offset>[
      for (var i = 0; i < samples.length; i++)
        Offset(
          size.width * i / (samples.length - 1),
          baseline - samples[i].clamp(0.0, 1.0).toDouble() * span,
        ),
    ];
    final curve = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset((points[i].dx + points[i + 1].dx) / 2,
          (points[i].dy + points[i + 1].dy) / 2);
      curve.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    curve.lineTo(points.last.dx, points.last.dy);
    final paint = Paint()
      ..color = isPlaying ? const Color(0xFF9BE9C6) : const Color(0xFF6B8E84)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(curve, paint);
  }

  @override
  bool shouldRepaint(covariant LiveWaveformPainter old) =>
      old.isPlaying != isPlaying || old.samples != samples;
}

class EqGridPainter extends CustomPainter {
  final Color accent;
  const EqGridPainter({required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.09)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guide);
    }
    final zero = Paint()
      ..color = accent.withValues(alpha: 0.32)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, size.height / 2),
      Offset(size.width, size.height / 2), zero);
  }

  @override
  bool shouldRepaint(covariant EqGridPainter old) => old.accent != accent;
}
