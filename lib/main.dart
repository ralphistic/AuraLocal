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

/// Scroll long titles smoothly without changing button placement.
class ScrollingTrackTitle extends StatefulWidget {
  final String text;
  final TextStyle style;
  const ScrollingTrackTitle({super.key, required this.text, required this.style});
  @override
  State<ScrollingTrackTitle> createState() => _ScrollingTrackTitleState();
}

class _ScrollingTrackTitleState extends State<ScrollingTrackTitle> with SingleTickerProviderStateMixin {
  late final AnimationController motion = AnimationController(vsync: this);
  @override
  void dispose() { motion.dispose(); super.dispose(); }
  @override
  void didUpdateWidget(covariant ScrollingTrackTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) { motion.stop(); motion.reset(); }
  }
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, bounds) {
    final style = widget.style;
    final painter = TextPainter(text: TextSpan(text: widget.text, style: style),
      textDirection: TextDirection.ltr, maxLines: 1)..layout();
    final textWidth = painter.width;
    if (textWidth <= bounds.maxWidth || !bounds.maxWidth.isFinite) {
      motion.stop();
      return Text(widget.text, maxLines: 1, style: style);
    }
    final distance = textWidth - bounds.maxWidth + 16;
    final duration = Duration(milliseconds: (distance * 35).round().clamp(2500, 25000).toInt());
    if (motion.duration != duration) {
      motion.duration = duration;
      motion.repeat(reverse: true);
    } else if (!motion.isAnimating) {
      motion.repeat(reverse: true);
    }
    return ClipRect(child: AnimatedBuilder(animation: motion, builder: (_, __) =>
      Transform.translate(offset: Offset(-distance * motion.value, 0),
        child: OverflowBox(alignment: Alignment.centerLeft, minWidth: 0, maxWidth: double.infinity,
          child: SizedBox(width: textWidth + 16, child: Text(widget.text, maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: style))))));
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      fontFamily: 'Josefin',
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF221A1B),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF08078), brightness: Brightness.dark),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFFFB8A5), foregroundColor: Color(0xFF161515)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: const Color(0xFF372825),
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
  static const Color activeEqAccent = Color(0xFFF08078);
  Timer? eqDebounce;
  final favorites = <String>{};
  final playlists = <String, List<String>>{};
  String? activePlaylist;
  String? error;
  String listeningOutput = '';
  int outputGeneration = 0;
  String listeningCodec = '';
  bool sourceLossless = false;
  int outputInfoTicks = 0;
  int currentIndex = -1;
  List<String> queuedPaths = [];
  final songDSP = <String, List<double>>{};
  bool globalDSP = false;
  final searchController = TextEditingController();
  int dspRequestGeneration = 0;
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
  Timer? dspSaveDebounce;
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
    dspSaveDebounce?.cancel();
    searchController.dispose();
    waveformLevels.dispose();
    nativeDsp.setMethodCallHandler(null);
    // The iOS audio session owns playback lifecycle; hiding this widget must not
    // accidentally stop audio playing in the background.
    super.dispose();
  }

  Future<void> refreshOutputInfo() async {
    final generation = ++outputGeneration;
    if (files.isEmpty) return;
    try {
      final info = await nativeDsp.invokeMapMethod<String, dynamic>('getOutputInfo');
      if (info == null || !mounted || generation != outputGeneration) return;
      final device = info['output'] as String? ?? '';
      final codec = info['codec'] as String? ?? '';
      final lossless = info['lossless'] == true;
      if (device != listeningOutput || codec != listeningCodec || lossless != sourceLossless) {
        setState(() { listeningOutput = device; listeningCodec = codec; sourceLossless = lossless; });
      }
    } on PlatformException catch (_) { /* Keep playback independent of route reporting. */ }
  }

  Future<void> pollNative() async {
    if (pollBusy || files.isEmpty) return;
    pollBusy = true;
    try {
      final response = await nativeDsp.invokeMapMethod<String, dynamic>('getState');
      if (!mounted || response == null) return;
      tick++;
      if (++outputInfoTicks >= 60) {
        outputInfoTicks = 0;
        refreshOutputInfo();
      }
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
    final nativeIndex = (state['index'] as num?)?.toInt();
    final newIndex = nativeIndex != null && nativeIndex >= 0 && nativeIndex < queuedPaths.length
        ? files.indexOf(queuedPaths[nativeIndex]) : -1;
    final indexChanged = newIndex != null && newIndex >= 0 &&
        newIndex < files.length && newIndex != currentIndex;
    void apply() {
      if (newIndex != null && newIndex >= -1 && newIndex < files.length) {
        if (currentIndex != newIndex) { currentIndex = newIndex; refreshOutputInfo(); loadSongDSP(); }
      }
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

  String manifestTrackKey(String absolutePath) =>
      'Music/' + Uri.file(absolutePath).pathSegments.last;

  Future<void> saveLibrary() async {
    final manifest = await libraryManifest();
    final content = jsonEncode({
      'files': files.map(manifestTrackKey).toList(),
      'favorites': favorites.map(manifestTrackKey).toList(),
      'playlists': playlists.map((name, tracks) =>
          MapEntry(name, tracks.map(manifestTrackKey).toList())),
      'shuffle': shuffle, 'repeat': repeat, 'speed': playbackSpeed,
      'globalDSP': globalDSP, 'songDSP': songDSP,
      'pitchCents': pitchCents, 'pitchSemitones': pitchSemitones,
      'originalNames': originalNames.map((path, name) =>
          MapEntry(manifestTrackKey(path), name)),
      'eqGains': eqGains, 'eqEnabled': eqEnabled,
      'eqPreset': eqPreset, 'customEqPresets': customEqPresets,
      'sortMode': sortMode, 'sortAscending': sortAscending,
      'dateAdded': dateAdded.map((path, added) =>
          MapEntry(manifestTrackKey(path), added)),
      'trackDurations': trackDurations.map((path, duration) =>
          MapEntry(manifestTrackKey(path), duration)),
    });
    final pending = File(manifest.path + '.pending');
    await pending.writeAsString(content, flush: true);
    await pending.rename(manifest.path);
  }

  int compareTracks(int a, int b) {
    int comparison;
    switch (sortMode) {
      case 'fileType':
        comparison = files[a].split('.').last.toLowerCase().compareTo(files[b].split('.').last.toLowerCase());
        if (comparison == 0) comparison = displayName(files[a]).toLowerCase().compareTo(displayName(files[b]).toLowerCase());
        break;
      case 'dateAdded':
        comparison = (dateAdded[files[a]] ?? 0).compareTo(dateAdded[files[b]] ?? 0);
        break;
      case 'length':
        comparison = (trackDurations[files[a]] ?? -1).compareTo(trackDurations[files[b]] ?? -1);
        break;
      default:
        comparison = displayName(files[a]).toLowerCase().compareTo(displayName(files[b]).toLowerCase());
    }
    if (comparison == 0) comparison = a.compareTo(b);
    return sortAscending ? comparison : -comparison;
  }

  List<int> orderedTrackIndices() => List<int>.generate(files.length, (i) => i)
    .where((i) => (activePlaylist == null || (playlists[activePlaylist]?.contains(files[i]) ?? false))
      && (!favoritesOnly || favorites.contains(files[i]))
      && displayName(files[i]).toLowerCase().contains(query.toLowerCase()))
    .toList()..sort(compareTracks);

  Future<void> syncQueue() async {
    final ordered = orderedTrackIndices().map((i) => files[i]).toList();
    // Preserve the active audio source even when a search/playlist hides it.
    if (currentIndex >= 0 && currentIndex < files.length &&
        !ordered.contains(files[currentIndex])) ordered.add(files[currentIndex]);
    queuedPaths = ordered;
    await nativeDsp.invokeMethod('setQueue', {
      'paths': ordered, 'shuffle': shuffle, 'repeat': repeat,
    });
  }

  void saveSongDSP() {
    if (!globalDSP && currentIndex >= 0 && currentIndex < files.length) {
      songDSP[manifestTrackKey(files[currentIndex])] = [
        pitchSemitones.toDouble(), pitchCents, playbackSpeed,
      ];
    }
  }

  Future<void> loadSongDSP() async {
    if (!globalDSP && currentIndex >= 0 && currentIndex < files.length) {
      final settings = songDSP[manifestTrackKey(files[currentIndex])];
      pitchSemitones = settings == null ? 0 : settings[0].toInt();
      pitchCents = settings == null ? 0 : settings[1];
      playbackSpeed = settings == null ? 1 : settings[2];
    }
    await updateNativePitchTempo();
  }

  void scheduleNativePitchTempoUpdate() {
    dspWheelDebounce?.cancel();
    dspWheelDebounce = Timer(const Duration(milliseconds: 35), () {
      updateNativePitchTempo();
    });
  }

  Future<void> updateNativePitchTempo() async {
    dspWheelDebounce?.cancel();
    dspSaveDebounce?.cancel();
    final request = ++dspRequestGeneration;
    final tempo = playbackSpeed;
    final cents = (pitchSemitones * 100 + pitchCents).clamp(-1200.0, 1200.0).toDouble();
    saveSongDSP();
    try {
      await nativeDsp.invokeMethod('setTimePitch', {'tempo': tempo, 'cents': cents});
      if (request == dspRequestGeneration) {
        dspSaveDebounce = Timer(const Duration(milliseconds: 650), saveLibrary);
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = 'Audio processing: ${e.message}');
    }
  }

  // Remove duplicate library references without deleting or modifying audio files.
  // Bytes are compared only for tracks of equal size; differing masters survive.
  Future<int> hideDuplicateLibraryEntries() async {
    final lengths = <int, List<String>>{};
    final duplicates = <String, String>{};
    for (final path in List<String>.of(files)) {
      final file = File(path);
      if (!await file.exists()) continue;
      final size = await file.length();
      String? existing;
      for (final candidate in lengths[size] ?? <String>[]) {
        if (await isSameAudio(file, File(candidate))) { existing = candidate; break; }
      }
      if (existing == null) {
        lengths.putIfAbsent(size, () => []).add(path);
      } else {
        duplicates[path] = existing;
      }
    }
    if (duplicates.isEmpty) return 0;
    // Keep a favorite or playlist reference if either identical copy had it.
    for (final duplicate in duplicates.keys) {
      final kept = duplicates[duplicate]!;
      if (favorites.contains(duplicate)) favorites.add(kept);
      for (final entries in playlists.values) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i] == duplicate) entries[i] = kept;
        }
        final unique = entries.toSet().toList();
        entries..clear()..addAll(unique);
      }
      dateAdded.remove(duplicate);
      trackDurations.remove(duplicate);
      originalNames.remove(duplicate);
    }
    files.removeWhere(duplicates.containsKey);
    await syncQueue();
    await saveLibrary();
    return duplicates.length;
  }

  Future<void> restoreLibrary() async {
    try {
      final musicDir = await musicDirectory();
      String localFilePath(String stored) =>
        musicDir.path + '/' + stored.replaceAll(String.fromCharCode(92), '/').split('/').last;
      final manifest = await libraryManifest();
      if (await manifest.exists()) {
        final decoded = jsonDecode(await manifest.readAsString());
        final saved = (decoded is List ? decoded : decoded['files'] as List).cast<String>();
        if (decoded is Map) {
          if (decoded['favorites'] is List) favorites.addAll((decoded['favorites'] as List).whereType<String>());
          shuffle = decoded['shuffle'] == true;
          globalDSP = decoded['globalDSP'] == true;
          if (decoded['songDSP'] is Map) {
            (decoded['songDSP'] as Map).forEach((key, values) {
              if (key is String && values is List && values.length == 3 && values.every((v) => v is num)) {
                songDSP[key] = values.map((v) => (v as num).toDouble()).toList();
              }
            });
          }
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
          if (storedMode is String && ['alphabetical', 'dateAdded', 'length', 'fileType'].contains(storedMode)) {
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
        final migrated = <String, String>{};
        for (final old in saved) {
          final mapped = localFilePath(old);
          if (await File(mapped).exists()) {
            migrated[old] = mapped;
            if (!files.contains(mapped)) files.add(mapped);
          }
        }
        // A new iOS sandbox UUID must never strand audio already in Documents.
        await for (final entry in musicDir.list()) {
          if (entry is File && RegExp(r'\.(flac|mp3|m4a|wav|aac)$',
              caseSensitive: false).hasMatch(entry.path) &&
              !files.contains(entry.path)) files.add(entry.path);
        }
        final migratedFavorites = favorites.map((path) =>
          migrated[path] ?? localFilePath(path)).where(files.contains).toSet();
        favorites..clear()..addAll(migratedFavorites);
        final names = <String, String>{};
        originalNames.forEach((path, name) {
          final mapped = migrated[path] ?? localFilePath(path);
          if (files.contains(mapped)) names[mapped] = name;
        });
        originalNames..clear()..addAll(names);
        final dates = <String, int>{};
        dateAdded.forEach((path, timestamp) {
          final mapped = migrated[path] ?? localFilePath(path);
          if (files.contains(mapped)) dates[mapped] = timestamp;
        });
        dateAdded..clear()..addAll(dates);
        final lengths = <String, double>{};
        trackDurations.forEach((path, seconds) {
          final mapped = migrated[path] ?? localFilePath(path);
          if (files.contains(mapped)) lengths[mapped] = seconds;
        });
        trackDurations..clear()..addAll(lengths);
        playlists.updateAll((name, tracks) =>
          tracks.map((path) => migrated[path] ?? localFilePath(path)).toList());
        for (final path in files) {
          dateAdded.putIfAbsent(path, () =>
            File(path).lastModifiedSync().millisecondsSinceEpoch);
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
      } else {
        await for (final entry in musicDir.list()) {
          if (entry is File && RegExp(r'\.(flac|mp3|m4a|wav|aac)$',
              caseSensitive: false).hasMatch(entry.path)) {
            files.add(entry.path);
            dateAdded[entry.path] = entry.lastModifiedSync().millisecondsSinceEpoch;
          }
        }
      }
      await hideDuplicateLibraryEntries();
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
      if (imported > 0) {
        await hideDuplicateLibraryEntries();
        await syncQueue();
      }
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
      if (queuedPaths.isEmpty || !queuedPaths.contains(files[index])) await syncQueue();
      final queueIndex = queuedPaths.indexOf(files[index]);
      await nativeDsp.invokeMethod('playIndex', {'index': queueIndex >= 0 ? queueIndex : index});
      if (mounted) setState(() {
        currentIndex = index; isPlaying = true; positionSeconds = 0; error = null;
      });
      refreshOutputInfo();
      await loadSongDSP();
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
      if (next != null && mounted && next >= 0 && next < queuedPaths.length) {
        setState(() => currentIndex = files.indexOf(queuedPaths[next]));
        await loadSongDSP();
      }
      refreshOutputInfo();
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
    await syncQueue();
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
    await syncQueue();
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
        const ListTile(title: Text('Up Next'), subtitle: Text('Following the current library sort order')),
        Expanded(child: ListView.builder(
          itemCount: queuedPaths.length,
          itemBuilder: (_, position) {
            final index = files.indexOf(queuedPaths[position]);
            if (index < 0) return const SizedBox.shrink();
            return ListTile(
              key: ValueKey(queuedPaths[position]),
              leading: Icon(index == currentIndex ? Icons.graphic_eq : Icons.music_note),
              title: Text(displayName(files[index]), maxLines: 2, overflow: TextOverflow.fade,
                  style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              subtitle: index == currentIndex ? const Text('Now playing') : null,
              onTap: () async { Navigator.pop(sheet); await selectAndPlayTrack(index); },
            );
          },
        )),
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
    final values = eqPresets[name] ?? customEqPresets[name];
    if (values == null) return;
    eqDebounce?.cancel();
    refresh(() {
      eqPreset = name;
      eqEnabled = true;
      for (var i = 0; i < eqGains.length; i++) {
        eqGains[i] = values[i];
      }
    });
    setState(() {});
    applyNativeEQ();
  }

  Future<void> saveCurrentEQPreset(StateSetter refresh) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save custom EQ preset'),
        content: TextField(
          controller: controller,
          maxLength: 40,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Preset name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    if (eqPresets.containsKey(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a different name from the built-in presets.')));
      return;
    }
    if (customEqPresets.containsKey(name)) {
      final replaceExisting = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Replace "$name"?'),
          content: const Text('Overwrite the saved settings for this preset?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace')),
          ],
        ),
      );
      if (replaceExisting != true || !mounted) return;
    }
    refresh(() {
      customEqPresets[name] = List<double>.of(eqGains);
      eqPreset = name;
    });
    await saveLibrary();
  }

  Future<void> deleteCustomEQPreset(String name, StateSetter refresh) async {
    if (!customEqPresets.containsKey(name)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text('This will delete the saved preset, not your current EQ adjustments.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    refresh(() {
      customEqPresets.remove(name);
      if (eqPreset == name) eqPreset = 'Custom';
    });
    await saveLibrary();
  }

  void setManualEQBand(int index, double gain, StateSetter refresh) {
    final adjusted = (gain * 2).round() / 2.0;
    if (eqGains[index] == adjusted && eqEnabled) return;
    refresh(() {
      eqGains[index] = adjusted.clamp(-12.0, 12.0);
      eqPreset = 'Custom';
      // Editing any slider should immediately affect the sound.
      eqEnabled = true;
    });
    // Apply on each drag frame, not only when the thumb is released.
    setState(() {});
    scheduleEQUpdate();
  }

  void showEqualizer() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF352729),
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          const accent = activeEqAccent;
          final screenHeight = MediaQuery.sizeOf(sheetContext).height;
          return SafeArea(
            child: SizedBox(
              height: screenHeight * 0.80,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
                child: Column(children: [
                  Row(children: [
                    const Icon(Icons.equalizer, color: accent, size: 27),
                    const SizedBox(width: 12),
                    const Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Audio Equalizer', style: TextStyle(
                          fontSize: 21, fontWeight: FontWeight.bold)),
                        Text('10-band • native audio processing',
                          style: TextStyle(fontSize: 12, color: Colors.white70)),
                      ],
                    )),
                    Switch.adaptive(
                      value: eqEnabled,
                      activeColor: accent,
                      onChanged: (enabled) {
                        refresh(() => eqEnabled = enabled);
                        applyNativeEQ();
                      },
                    ),
                  ]),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: ValueKey('eq-$eqPreset'),
                    initialValue: eqPreset == 'Custom' ? null : eqPreset,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'EQ preset'),
                    hint: const Text('Custom (unsaved)'),
                    items: [
                      for (final name in eqPresets.keys)
                        DropdownMenuItem(value: name, child: Text(name)),
                      for (final name in customEqPresets.keys)
                        DropdownMenuItem(value: name, child: Text(name)),
                    ],
                    onChanged: (name) { if (name != null) chooseEQPreset(name, refresh); },
                  ),
                  if (customEqPresets.containsKey(eqPreset))
                    Align(alignment: Alignment.centerRight,
                      child: TextButton.icon(onPressed: () => deleteCustomEQPreset(eqPreset, refresh),
                        icon: const Icon(Icons.delete_outline), label: const Text('Delete preset'))),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Stack(children: [
                      Positioned.fill(child: CustomPaint(
                        painter: const EqGridPainter(accent: accent),
                      )),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < 10; i++)
                            Expanded(child: EqBandControl(
                              key: ValueKey('eq-band-$i'),
                              label: eqFrequencies[i],
                              gain: eqGains[i],
                              accent: accent,
                              onChanged: (value) => setManualEQBand(i, value, refresh),
                              onChangeEnd: () => applyNativeEQ(),
                            )),
                        ],
                      ),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => saveCurrentEQPreset(refresh),
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('Save as preset'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () => chooseEQPreset('Flat', refresh),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset'),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(eqEnabled ? 'EQ enabled' : 'EQ bypassed',
                        style: const TextStyle(color: Colors.white70)),
                      TextButton.icon(
                        onPressed: () {
                          refresh(() => eqEnabled = !eqEnabled);
                          applyNativeEQ();
                        },
                        icon: Icon(eqEnabled ? Icons.toggle_on : Icons.toggle_off),
                        label: Text(eqEnabled ? 'Bypass EQ' : 'Enable EQ'),
                      ),
                    ],
                  ),
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
              child: GestureDetector(
                onDoubleTapDown: (_) { refresh(() { pitchSemitones = 0; pitchCents = 0; }); updateNativePitchTempo(); },
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
                  // The dedicated Fine tune button opens the wheels; single
                  // taps here must not interrupt a double-tap reset.
                  if (wasTap) {}
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
            ),
            TextButton.icon(
              onPressed: () => showPitchWheel(refresh),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Fine tune: semitones / cents'),
            ),
            TextButton(onPressed: () => showTempoWheel(refresh),
              child: Text('Tempo: ${(playbackSpeed * 100).round()}%')),
            GestureDetector(onDoubleTapDown: (_) { refresh(() => playbackSpeed = 1); updateNativePitchTempo(); },
              child: Slider(value: playbackSpeed, min: 0.5, max: 2.0, divisions: 150,
                onChanged: (value) { refresh(() => playbackSpeed = value); setState(() {}); scheduleNativePitchTempoUpdate(); },
                onChangeEnd: (_) => updateNativePitchTempo())),
            SwitchListTile.adaptive(title: const Text('Use global pitch and tempo'), value: globalDSP,
              onChanged: (enabled) async { refresh(() => globalDSP = enabled); await loadSongDSP(); await saveLibrary(); }),
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
    syncQueue();
    if (value == 'length') loadMissingDurations();
  }


  /// An unsigned IPA update preserves sandbox data only when installed IN PLACE
  /// with the same final bundle identifier. Deleting an iOS app deletes its
  /// private music storage. These portable ZIPs survive in Files outside the app.
  Future<void> exportLibraryBackup() async {
    if (isLibraryExporting) return;
    setState(() => isLibraryExporting = true);
    try {
      await saveLibrary();
      final temp = await getTemporaryDirectory();
      final backup = File(temp.path + '/AuraLocal-Library-Backup.zip');
      final manifest = await libraryManifest();
      final portable = Map<String, dynamic>.from(
        jsonDecode(await manifest.readAsString()) as Map);
      String portableName(String file) {
        return 'Music/' + Uri.file(file).pathSegments.last;
      }
      portable['files'] = files.map(portableName).toList();
      portable['favorites'] = favorites.map(portableName).toList();
      portable['playlists'] = playlists.map((name, tracks) =>
        MapEntry(name, tracks.map(portableName).toList()));
      portable['originalNames'] = originalNames.map((path, title) =>
        MapEntry(portableName(path), title));
      portable['dateAdded'] = dateAdded.map((path, value) =>
        MapEntry(portableName(path), value));
      portable['trackDurations'] = trackDurations.map((path, value) =>
        MapEntry(portableName(path), value));
      final portableManifest = File(temp.path + '/auralocal-backup.json');
      await portableManifest.writeAsString(jsonEncode(portable));

      final zip = ZipFileEncoder();
      zip.create(backup.path, level: 0); // Store FLAC unchanged.
      try {
        for (final song in files) {
          final file = File(song);
          if (await file.exists()) {
            await zip.addFile(file, portableName(song), 0);
          }
        }
        await zip.addFile(portableManifest, 'auralocal-backup.json', 0);
      } finally {
        await zip.close();
      }
      if (!mounted) return;
      final showingPicker = await nativeDsp.invokeMethod<bool>(
        'exportBackup', {'path': backup.path});
      if (showingPicker != true) throw Exception('Unable to open Files');
    } catch (e) {
      if (mounted) setState(() => error = 'Backup export: $e');
    } finally {
      if (mounted) setState(() => isLibraryExporting = false);
    }
  }

  Future<void> restoreLibraryBackup() async {
    if (isLibraryRestoring) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['zip'],
      allowMultiple: false);
    final path = picked?.files.single.path;
    if (path == null) return;
    setState(() => isLibraryRestoring = true);
    try {
      final temp = await getTemporaryDirectory();
      final staging = Directory(temp.path + '/auralocal-restore-' +
        DateTime.now().millisecondsSinceEpoch.toString());
      await staging.create(recursive: true);
      final input = InputFileStream(path);
      final archive = ZipDecoder().decodeStream(input);
      if (archive.files.length > 20000) throw FormatException('Backup has too many files');
      var hasManifest = false;
      for (final item in archive.files) {
        if (!item.isFile) continue;
        final name = item.name;
        if (name == 'auralocal-backup.json') {
          hasManifest = true;
        } else if (name.startsWith('Music/')) {
          final base = name.substring('Music/'.length);
          if (base.isEmpty || base == '.' || base == '..' ||
              base.contains('/') || base.contains(r'\')) {
            throw FormatException('Backup contains unsafe filenames');
          }
        } else {
          throw FormatException('This is not an AuraLocal library backup');
        }
        final output = OutputFileStream(staging.path + '/' + name);
        item.writeContent(output);
        output.closeSync();
      }
      if (!hasManifest) throw FormatException('Backup manifest not found');
      final backupManifest = File(staging.path + '/auralocal-backup.json');
      if (await backupManifest.length() > 10000000) {
        throw FormatException('Backup manifest is too large');
      }
      final decoded = jsonDecode(await backupManifest.readAsString());
      if (decoded is! Map || decoded['files'] is! List) {
        throw FormatException('Invalid library backup');
      }
      final oldPaths = (decoded['files'] as List).whereType<String>();
      final destination = await musicDirectory();
      final restored = <String, String>{};
      for (final oldPath in oldPaths) {
        if (!oldPath.startsWith('Music/')) continue;
        final basename = oldPath.substring(6);
        if (basename.isEmpty || basename.contains('/') ||
            basename.contains(r'\') || basename == '.' || basename == '..') {
          throw FormatException('Backup contains an unsafe file path');
        }
        final from = File(staging.path + '/' + oldPath);
        if (!await from.exists()) continue;
        var target = File(destination.path + '/' + basename);
        if (await target.exists() && !await isSameAudio(from, target)) {
          final dot = basename.lastIndexOf('.');
          final name = dot > 0 ? basename.substring(0, dot) : basename;
          final ext = dot > 0 ? basename.substring(dot) : '';
          var suffix = 1;
          do {
            target = File(destination.path + '/' + name +
              '_restored' + (suffix++).toString() + ext);
          } while (await target.exists());
        }
        if (!await target.exists()) await from.copy(target.path);
        restored[oldPath] = target.path;
        if (!files.contains(target.path)) files.add(target.path);
      }
      final names = decoded['originalNames'];
      if (names is Map) {
        names.forEach((path, title) {
          if (path is String && title is String && restored.containsKey(path)) {
            originalNames[restored[path]!] = title;
          }
        });
      }
      final backedUpFavorites = decoded['favorites'];
      if (backedUpFavorites is List) {
        for (final path in backedUpFavorites.whereType<String>()) {
          if (restored[path] != null) favorites.add(restored[path]!);
        }
      }
      final backedUpPlaylists = decoded['playlists'];
      if (backedUpPlaylists is Map) {
        backedUpPlaylists.forEach((key, value) {
          if (key is! String || value is! List) return;
          final existing = playlists.putIfAbsent(key, () => []);
          for (final old in value.whereType<String>()) {
            final mapped = restored[old];
            if (mapped != null && !existing.contains(mapped)) existing.add(mapped);
          }
        });
      }
      final added = decoded['dateAdded'];
      if (added is Map) {
        added.forEach((path, value) {
          if (path is String && value is num && restored.containsKey(path)) {
            dateAdded[restored[path]!] = value.toInt();
          }
        });
      }
      final lengths = decoded['trackDurations'];
      if (lengths is Map) {
        lengths.forEach((path, value) {
          if (path is String && value is num && restored.containsKey(path)) {
            trackDurations[restored[path]!] = value.toDouble();
          }
        });
      }
      if (decoded['customEqPresets'] is Map) {
        (decoded['customEqPresets'] as Map).forEach((name, values) {
          if (name is String && values is List && values.length == 10 &&
              values.every((v) => v is num)) {
            customEqPresets[name] = values.map(
              (v) => (v as num).toDouble().clamp(-12.0, 12.0).toDouble()).toList();
          }
        });
      }
      await hideDuplicateLibraryEntries();
      await syncQueue();
      await saveLibrary();
      await loadMissingDurations();
      if (mounted) {
        setState(() => error = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Library restored: ' + restored.length.toString() +
            ' tracks available.'),
        ));
      }
      try { await staging.delete(recursive: true); } catch (_) {}
    } catch (e) {
      if (mounted) setState(() => error = 'Backup restore: $e');
    } finally {
      if (mounted) setState(() => isLibraryRestoring = false);
    }
  }

  Widget buildLibrary() {
    final matches = orderedTrackIndices();
    return Scaffold(
      appBar: AppBar(title: const Text('Your Library'), actions: [
        IconButton(tooltip: 'New playlist', icon: const Icon(Icons.playlist_add), onPressed: createPlaylist),
        IconButton(tooltip: 'Import music', icon: const Icon(Icons.add), onPressed: import),
        PopupMenuButton<String>(
          tooltip: 'Library backup and restore',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'backup') {
              exportLibraryBackup();
            } else if (value == 'restore') {
              restoreLibraryBackup();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'backup',
              child: ListTile(leading: Icon(Icons.backup_outlined),
                title: Text('Back up library'),
                subtitle: Text('Save music & playlists to Files'))),
            const PopupMenuItem(value: 'restore',
              child: ListTile(leading: Icon(Icons.restore),
                title: Text('Restore backup'),
                subtitle: Text('Import an AuraLocal backup ZIP'))),
          ],
        ),
      ]),
      body: SafeArea(child: Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: TextField(
          controller: searchController,
          onChanged: (value) { setState(() => query = value); syncQueue(); },
          decoration: InputDecoration(hintText: 'Search songs', prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(80)), borderSide: BorderSide.none),
            suffixIcon: query.isNotEmpty ? IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close),
              onPressed: () { searchController.clear(); setState(() => query = ''); syncQueue(); }) : null),
        )),
        SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          ChoiceChip(label: const Text('Library'), selected: activePlaylist == null,
            onSelected: (_) { setState(() => activePlaylist = null); syncQueue(); }),
          const SizedBox(width: 8),
          for (final name in playlists.keys) ...[
            InputChip(label: Text(name), selected: activePlaylist == name,
              onSelected: (_) { setState(() => activePlaylist = name); syncQueue(); },
              onDeleted: () => playlistMenu(name), deleteIcon: const Icon(Icons.more_horiz, size: 18)),
            const SizedBox(width: 8),
          ],
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          ChoiceChip(label: const Text('All songs'), selected: !favoritesOnly,
            onSelected: (_) { setState(() => favoritesOnly = false); syncQueue(); }),
          const SizedBox(width: 8),
          ChoiceChip(label: const Text('Favorites'), selected: favoritesOnly,
            onSelected: (_) { setState(() => favoritesOnly = true); syncQueue(); }),
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
                ('fileType', 'File type'),
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
              style: const TextStyle(color: Colors.white70)))),
        Expanded(child: files.isEmpty
          ? Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(onPressed: import, icon: const Icon(Icons.add),
                  label: const Text('Import your music')),
                const SizedBox(height: 14),
                TextButton.icon(onPressed: restoreLibraryBackup,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore saved AuraLocal backup')),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('iOS deletes an app’s private music when you uninstall it.\n'
                    'Back up to Files before changing your signing or installation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12))),
              ]))
          : ListView.builder(itemCount: matches.length, itemBuilder: (_, row) {
              final index = matches[row];
              final extension = files[index].split('.').last.toUpperCase();
              final previousExtension = row > 0 ? files[matches[row - 1]].split('.').last.toUpperCase() : '';
              final groupStart = sortMode == 'fileType' && extension != previousExtension;
              return Column(mainAxisSize: MainAxisSize.min, children: [
                if (groupStart) Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                  color: const Color(0xFFF08078), child: Text('$extension FILES',
                    style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, color: Colors.black))),
                ListTile(
                tileColor: index == currentIndex ? const Color(0x665A3A18) : null,
                shape: const Border(left: BorderSide(color: Color(0xFF221A1B), width: 2)),
                leading: Icon(index == currentIndex ? Icons.graphic_eq : Icons.music_note,
                  color: index == currentIndex ? const Color(0xFFF08078) : Colors.white70),
                title: Text(displayName(files[index]), maxLines: 2, overflow: TextOverflow.fade,
                  style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
                subtitle: Text(
                  index == currentIndex ? 'Now playing'
                      : trackDurations.containsKey(files[index])
                        ? clock(trackDurations[files[index]]!)
                        : 'Local audio',
                  style: const TextStyle(color: Colors.white70)),
                trailing: IconButton(tooltip: 'Song options', icon: const Icon(Icons.more_vert),
                  onPressed: () => trackMenu(files[index])),
                onTap: () async {
                  await selectAndPlayTrack(index);
                  if (mounted) showPlayer();
                },
              ),
              ]);
            })),
        if (currentIndex >= 0 && currentIndex < files.length) GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => startMiniSwipe(),
          onVerticalDragUpdate: updateMiniSwipe,
          onVerticalDragEnd: finishMiniSwipe,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            color: const Color(0xFF5D3031),
            child: ListTile(
            leading: const Icon(Icons.graphic_eq, color: Color(0xFFFFB8A5)),
            title: ScrollingTrackTitle(text: title, style: const TextStyle(fontWeight: FontWeight.w700)),
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
        if (isLibraryExporting || isLibraryRestoring)
          const LinearProgressIndicator(minHeight: 2),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
      ])),
    );
  }

  Widget buildPlayer() {
    final effectivePosition = draggingSeek && scrubPosition != null ? scrubPosition! : positionSeconds;
    final maximum = math.max(durationSeconds, 0.001);
    return Scaffold(
      backgroundColor: const Color(0xFF221A1B),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(tooltip: 'Minimize player', icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: showLibrary),
        title: const Text('Now Playing'),
        actions: [
          IconButton(tooltip: 'Toggle live waveform', onPressed: toggleWaveform,
            color: waveformVisible ? const Color(0xFFFFB8A5) : Colors.white,
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
              gradient: const LinearGradient(colors: [Color(0xFFF08078), Color(0xFFF2CB47)])),
            child: const Center(child: Icon(Icons.music_note, size: 120, color: Color(0xFF221A1B))),
          )),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: ScrollingTrackTitle(text: title, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: Color(0xFFFFB8A5)))),
            if (currentIndex >= 0 && currentIndex < files.length)
              IconButton(tooltip: 'Favorite',
                onPressed: () => toggleFavorite(files[currentIndex]),
                icon: Icon(favorites.contains(files[currentIndex]) ? Icons.favorite : Icons.favorite_border,
                  color: const Color(0xFFFFB8A5))),
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
          AnimatedSwitcher(duration: const Duration(milliseconds: 360),
            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
            child: listeningOutput.isEmpty ? const SizedBox(height: 12, key: ValueKey('empty-route')) :
              Padding(key: ValueKey('$listeningOutput/$listeningCodec/$sourceLossless'),
                padding: const EdgeInsets.only(bottom: 5), child: Text(
                [listeningOutput, if (listeningCodec.isNotEmpty) listeningCodec,
                  if (sourceLossless) 'Lossless source'].join('  ·  '),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xFFFFB8A5))))),
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
            IconButton(tooltip: 'Shuffle', color: shuffle ? const Color(0xFFFFB8A5) : Colors.white,
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
              IconButton(tooltip: 'Repeat mode', color: repeat == 0 ? Colors.white : const Color(0xFFFFB8A5),
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
    // One centered oscilloscope-like line; movement follows the native
    // post-EQ audio tap rather than showing a collection of vertical bars.
    final baseline = size.height * 0.5;
    final span = size.height * 0.32;
    final points = <Offset>[
      for (var i = 0; i < samples.length; i++)
        Offset(
          size.width * i / (samples.length - 1),
          baseline + math.sin(i * math.pi * 0.54) *
              samples[i].clamp(0.0, 1.0).toDouble() * span,
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
      ..color = isPlaying ? const Color(0xFFFFB8A5) : const Color(0xFFF08078)
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

class EqBandControl extends StatelessWidget {
  final String label;
  final double gain;
  final Color accent;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;
  const EqBandControl({super.key, required this.label,
    required this.gain, required this.accent,
    required this.onChanged, required this.onChangeEnd});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const top = 25.0;
      const bottom = 22.0;
      final height = math.max(20.0, constraints.maxHeight - top - bottom);
      void setAt(Offset global) {
        final local = (context.findRenderObject() as RenderBox).globalToLocal(global);
        final percentage = ((local.dy - top) / height).clamp(0.0, 1.0).toDouble();
        // Screen top: +12dB; center: 0dB; bottom: -12dB.
        onChanged(12.0 - percentage * 24.0);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (details) {
          final y = details.localPosition.dy;
          final thumb = top + (12.0 - gain) / 24.0 * height;
          if ((y - thumb).abs() < 24) { onChanged(0); onChangeEnd(); }
        },
        onTapDown: (details) {
          setAt(details.globalPosition);
          onChangeEnd();
        },
        onVerticalDragStart: (details) => setAt(details.globalPosition),
        onVerticalDragUpdate: (details) => setAt(details.globalPosition),
        onVerticalDragEnd: (_) => onChangeEnd(),
        onVerticalDragCancel: onChangeEnd,
        child: Stack(children: [
          Positioned(
            left: 0, right: 0, top: 1,
            child: Center(child: Text(
              '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)}',
              style: TextStyle(fontSize: 9.0, fontWeight: FontWeight.w700,
                color: accent),
            )),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: EqBandTrackPainter(
                gain: gain, accent: accent,
                top: top, bottom: bottom,
              ),
            ),
          ),
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Center(child: Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.white70))),
          ),
        ]),
      );
    });
  }
}

class EqBandTrackPainter extends CustomPainter {
  final double gain;
  final Color accent;
  final double top;
  final double bottom;
  const EqBandTrackPainter({required this.gain, required this.accent,
    required this.top, required this.bottom});

  @override
  void paint(Canvas canvas, Size size) {
    final middleX = size.width / 2;
    final trackBottom = size.height - bottom;
    final travel = math.max(1.0, trackBottom - top);
    final thumbY = top + (12.0 - gain) / 24.0 * travel;
    final zeroY = top + travel / 2;
    final base = Paint()
      ..color = Colors.white24
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(middleX, top),
      Offset(middleX, trackBottom), base);
    final selected = Paint()
      ..color = accent
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(middleX, zeroY),
      Offset(middleX, thumbY), selected);
    final ring = Paint()..color = const Color(0xFF352729);
    canvas.drawCircle(Offset(middleX, thumbY), 8, ring);
    canvas.drawCircle(Offset(middleX, thumbY), 6,
      Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant EqBandTrackPainter old) =>
    old.gain != gain || old.accent != accent;
}
