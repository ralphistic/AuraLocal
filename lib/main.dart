import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'metadata_art.dart';
import 'google_letter_palette.dart';
import 'blurred_surfaces.dart';

// Replaced with the GitHub Actions run number before every iOS build.
const String auraBuildNumber = 'DEV';

/// Scroll long titles smoothly without changing button placement.
class ScrollingTrackTitle extends StatefulWidget {
  final String text;
  final TextStyle style;
  const ScrollingTrackTitle({super.key, required this.text, required this.style});
  @override
  State<ScrollingTrackTitle> createState() => _ScrollingTrackTitleState();
}

class _ScrollingTrackTitleState extends State<ScrollingTrackTitle> with TickerProviderStateMixin {
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
    // Measure with the same inherited Josefin font as the rendered Text.
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final painter = TextPainter(text: TextSpan(text: widget.text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context), maxLines: 1)..layout();
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
      sliderTheme: SliderThemeData(trackHeight: 5, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9), overlayShape: const RoundSliderOverlayShape(overlayRadius: 19), activeTrackColor: GoogleLetterPalette.yellow, inactiveTrackColor: GoogleLetterPalette.creamDivider, thumbColor: GoogleLetterPalette.yellow),
      // Tighter, more substantial 1970s-inspired typography throughout.
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -1.6),
        displayMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -1.2),
        headlineLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -1.0),
        headlineMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.8),
        titleLarge: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.65),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.45),
        titleSmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.3),
        bodyLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.35),
        bodyMedium: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.25),
        bodySmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.15),
        labelLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.35),
        labelMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      ),
      brightness: Brightness.light,
      scaffoldBackgroundColor: GoogleLetterPalette.cream,
      colorScheme: ColorScheme.fromSeed(seedColor: GoogleLetterPalette.red,
        brightness: Brightness.light, surface: GoogleLetterPalette.cream),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
        foregroundColor: GoogleLetterPalette.creamText)),
      listTileTheme: const ListTileThemeData(textColor: GoogleLetterPalette.creamText,
        iconColor: GoogleLetterPalette.creamText),
      appBarTheme: const AppBarTheme(backgroundColor: GoogleLetterPalette.blue,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Color(0xFF161515), elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: const Color(0xFFFFFAEF),
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

class _MusicPageState extends State<MusicPage> with TickerProviderStateMixin {
  static const nativeDsp = MethodChannel('auralocal/native_dsp');
  static const fileReferences = MethodChannel('auralocal/file_references');
  final files = <String>[];
  final ScrollController libraryScroll = ScrollController();
  final originalNames = <String, String>{};
  final trackMetadata = <String, Map<String, String>>{};
  final embeddedArt = <String, Uint8List?>{};
  final localThumbnailBytes = <String, Uint8List>{};
  final eqGains = List<double>.filled(10, 0);
  final customEqPresets = <String, List<double>>{};
  bool eqEnabled = false;
  double preampDb = 0;
  final manualQueue = <String>[];
  bool manualQueueActive = false;
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
  static const Color activeEqAccent = GoogleLetterPalette.red;
  Timer? eqDebounce;
  final favorites = <String>{};
  final playlists = <String, List<String>>{};
  String? activePlaylist;
  bool libraryPlaylistsPage = false;
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
  bool linkedPitchTempo = false;
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
  bool waveformVisible = false; // Legacy persisted setting; EQ analyzer runs independently.
  final waveformLevels = ValueNotifier<List<double>>(List.filled(48, 0));
  List<double> waveformTarget = List.filled(48, 0);
  Ticker? spectrumTicker;
  Duration? lastSpectrumTick;
  Timer? pollTimer;
  bool pollBusy = false;
  int tick = 0;
  double playerDrag = 0;
  late final AnimationController playerMotion;
  final GlobalKey miniPlayerPositionKey = GlobalKey(debugLabel: 'mini-player-position');
  // The physical top edge of the footer is the only collapsed endpoint.
  double _measuredCollapsedOffset = 0;
  bool _playerGestureStarted = false;
  int _selectionEpoch = 0;
  // The mini footer retains its gesture recognizer during every transition.
  // The full player floats above the same footer without a second preview.
  bool draggingPlayer = false;
  bool dismissingPlayer = false;
  double miniSwipeTravel = 0;
  Timer? dspWheelDebounce;
  Timer? dspSaveDebounce;
  Offset? pitchTouchStart;
  bool pitchTouchMoved = false;
  int lastPitchTapAt = 0;
  int lastTempoTapAt = 0;
  Offset? tempoTouchStart;
  bool tempoTouchMoved = false;

  @override
  void initState() {
    super.initState();
    playerMotion = AnimationController(vsync: this, value: 0,
      duration: const Duration(milliseconds: 300));
    playerMotion.addListener(() {
      if (mounted) setState(() {});
    });
    playerMotion.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && !draggingPlayer) {
        _completePlayerCollapse();
      }
    });
    nativeDsp.setMethodCallHandler((call) async {
      if (call.method != 'nativePlaybackEvent' || !mounted) return;
      final state = Map<String, dynamic>.from(call.arguments as Map);
      applyNativeState(state);
      if (state['error'] is String) setState(() => error = state['error'] as String);
    });
    restoreLibrary();
    spectrumTicker = createTicker((elapsed) {
      if (!mounted) return;
      final dt = lastSpectrumTick == null ? 1 / 60 :
        ((elapsed - lastSpectrumTick!).inMicroseconds / 1000000.0)
          .clamp(0.001, 0.05);
      lastSpectrumTick = elapsed;
      final previous = waveformLevels.value;
      final next = List<double>.generate(waveformTarget.length, (i) {
        final target = isPlaying ? waveformTarget[i] : 0.0;
        final before = previous[i];
        final responseTime = target > before ? 0.060 : 0.110;
        final fraction = 1 - math.exp(-dt / responseTime);
        return before + (target - before) * fraction;
      });
      waveformLevels.value = next;
    });
    // Spectrum stays available for the Equalizer visualization; not toggled
    // by Now Playing or tied to a hidden player waveform state.
    spectrumTicker?.start();
    nativeDsp.invokeMethod('setWaveformEnabled', {'enabled': true});
    pollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) => pollNative());
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    transportHoldTimer?.cancel();
    dspWheelDebounce?.cancel();
    eqDebounce?.cancel();
    spectrumTicker?.dispose();
    playerMotion.dispose();
    dspSaveDebounce?.cancel();
    libraryScroll.dispose();
    searchController.dispose();
    waveformLevels.dispose();
    nativeDsp.setMethodCallHandler(null);
    // The iOS audio session owns playback lifecycle; hiding this widget must not
    // accidentally stop audio playing in the background.
    super.dispose();
  }

  void showOutputPicker() {
    showAuraSheet<void>(context: context,
      backgroundColor: GoogleLetterPalette.cream,
      showDragHandle: true,
      builder: (sheet) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 25),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Audio output', style: TextStyle(
            color: GoogleLetterPalette.ink, fontSize: 23,
            fontWeight: FontWeight.w900)),
          const SizedBox(height: 15),
          Text(listeningOutput.isEmpty ? 'Current output' : listeningOutput,
            style: const TextStyle(fontSize: 16,
              color: GoogleLetterPalette.ink, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          const Text('Choose another speaker or headphones using the iOS output picker.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GoogleLetterPalette.creamText)),
          const SizedBox(height: 15),
          SizedBox(height: 62, width: 170,
            child: UiKitView(viewType: 'auralocal/output-picker')),
        ]))));
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
      {
        final values = response['waveform'];
        if (values is List) {
          waveformTarget = values.map((v) => (v as num).toDouble().clamp(0.0, 1.0).toDouble()).toList();
        }
      }
      applyNativeState(response, repaint: (!libraryHome && !dismissingPlayer) || tick % 5 == 0);
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
        if (currentIndex != newIndex) {
          currentIndex = newIndex;
          refreshOutputInfo();
          loadSongDSP();
          if (newIndex >= 0 && newIndex < files.length) probeEmbeddedArt(files[newIndex]);
        }
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
      absolutePath.startsWith('External/') || absolutePath.startsWith('Music/')
          ? absolutePath :
      (absolutePath.contains('/Documents/Music/') ? 'Music/' : 'External/') +
      Uri.file(absolutePath).pathSegments.last;

  Future<void> saveLibrary() async {
    final manifest = await libraryManifest();
    final content = jsonEncode({
      'files': files.map(manifestTrackKey).toList(),
      'favorites': favorites.map(manifestTrackKey).toList(),
      'playlists': playlists.map((name, tracks) =>
          MapEntry(name, tracks.map(manifestTrackKey).toList())),
      'shuffle': shuffle, 'repeat': repeat, 'speed': playbackSpeed,
      'globalDSP': globalDSP, 'songDSP': songDSP, 'linkedPitchTempo': linkedPitchTempo,
      'trackMetadata': trackMetadata,
      'pitchCents': pitchCents, 'pitchSemitones': pitchSemitones,
      'originalNames': originalNames.map((path, name) =>
          MapEntry(manifestTrackKey(path), name)),
      'eqGains': eqGains, 'eqEnabled': eqEnabled,
      'preampDb': preampDb,
      'manualQueue': manualQueue.map(manifestTrackKey).toList(),
      'manualQueueActive': manualQueueActive,
      'eqPreset': eqPreset, 'customEqPresets': customEqPresets,
      'sortMode': sortMode, 'sortAscending': sortAscending,
      'dateAdded': dateAdded.map((path, added) =>
          MapEntry(manifestTrackKey(path), added)),
      'trackDurations': trackDurations.map((path, duration) =>
          MapEntry(manifestTrackKey(path), duration)),
    });
    final pending = File(manifest.path + '.pending');
    await pending.writeAsString(content, flush: true);
    // Retain the previous good index so a failed or interrupted write cannot
    // make the entire library disappear on the next launch.
    if (await manifest.exists()) {
      await manifest.copy(manifest.path + '.backup');
    }
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

  List<int> orderedTrackIndices() {
    final needle = query.trim().toLowerCase();
    final indices = List<int>.generate(files.length, (i) => i);
    if (libraryPlaylistsPage) return [];
    return indices.where((i) {
      final path = files[i];
      if (activePlaylist != null &&
          !(playlists[activePlaylist]?.contains(path) ?? false)) return false;
      if (favoritesOnly && !favorites.contains(path)) return false;
      if (needle.isEmpty) return true;
      return displayName(path).toLowerCase().contains(needle) ||
          (originalNames[path] ?? path.split('/').last).toLowerCase().contains(needle);
    }).toList()..sort(compareTracks);
  }

  Future<void> syncQueue() async {
    final ordered = List<int>.generate(files.length, (i) => i)..sort(compareTracks);
    final libraryOrder = ordered.map((i) => files[i]).toList();
    // A manually edited queue must not be destroyed by a sort, a search,
    // an active playlist, or by simply toggling shuffle on and off.
    manualQueue.removeWhere((path) => !files.contains(path));
    if (manualQueueActive && manualQueue.isEmpty) manualQueueActive = false;
    if (manualQueueActive) {
      queuedPaths = List<String>.of(manualQueue);
    } else {
      queuedPaths = libraryOrder;
    }
    await nativeDsp.invokeMethod('setQueue', {
      'paths': queuedPaths, 'shuffle': shuffle, 'repeat': repeat,
    });
  }

  Future<void> editQueue(List<String> ordered) async {
    manualQueueActive = true;
    manualQueue..clear()..addAll(ordered.where(files.contains));
    await syncQueue();
    await saveLibrary();
    if (mounted) setState(() {});
  }

  Future<void> appendCurrentSongToQueue() async {
    if (currentIndex < 0 || currentIndex >= files.length) return;
    final snapshot = List<String>.of(queuedPaths);
    snapshot.add(files[currentIndex]);
    await editQueue(snapshot);
  }

  Future<void> resetQueueToLibraryOrder() async {
    manualQueueActive = false;
    manualQueue.clear();
    await syncQueue();
    await saveLibrary();
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
    final cents = linkedPitchTempo ? 0.0 : (pitchSemitones * 100 + pitchCents).clamp(-1200.0, 1200.0).toDouble();
    saveSongDSP();
    try {
      await nativeDsp.invokeMethod('setTimePitch', {'tempo': tempo, 'cents': cents, 'linked': linkedPitchTempo});
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
    // This is an explicit maintenance operation, never called automatically.
    // Preserve original file references; do not remove items merely because
    // two different files have the same title or filename.
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
        dynamic decoded;
        try {
          decoded = jsonDecode(await manifest.readAsString());
          if (decoded is! Map && decoded is! List) throw const FormatException('Invalid library');
          if (decoded is Map && decoded['files'] is! List) throw const FormatException('Missing songs');
        } catch (_) {
          final backup = File(manifest.path + '.backup');
          if (!await backup.exists()) rethrow;
          decoded = jsonDecode(await backup.readAsString());
        }
        final saved = (decoded is List ? decoded : decoded['files'] as List).cast<String>();
        if (decoded is Map) {
          if (decoded['favorites'] is List) favorites.addAll((decoded['favorites'] as List).whereType<String>());
          shuffle = decoded['shuffle'] == true;
          if (decoded['trackMetadata'] is Map) {
            (decoded['trackMetadata'] as Map).forEach((key, value) {
              if (key is String && value is Map) {
                trackMetadata[key] = value.map((k, v) => MapEntry(k.toString(), v.toString()));
              }
            });
          }
          globalDSP = decoded['globalDSP'] == true;
          linkedPitchTempo = decoded['linkedPitchTempo'] == true;
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
          preampDb = (decoded['preampDb'] is num
              ? (decoded['preampDb'] as num).toDouble() : 0.0)
              .clamp(-12.0, 12.0).toDouble();
          manualQueueActive = decoded['manualQueueActive'] == true;
          if (decoded['manualQueue'] is List) {
            manualQueue.addAll((decoded['manualQueue'] as List)
                .whereType<String>());
          }
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
        // Reopen security-scoped bookmarks. A moved file can resolve to its new
        // location when its Files provider supports persistent document IDs.
        final referenced = <String, String>{};
        try {
          final recovered = await fileReferences.invokeListMethod<dynamic>('restoreReferences');
          for (final raw in recovered ?? <dynamic>[]) {
            if (raw is Map && raw['name'] is String && raw['path'] is String) {
              referenced['External/' + raw['name']] = raw['path'];
            }
          }
        } catch (_) {}
        for (final old in saved) {
          final external = old.startsWith('External/');
          final mapped = external
            ? (referenced[old] ?? old) : localFilePath(old);
          // A temporary Files provider hydration failure must not silently
          // drop bookmarked tracks from the library and the saved manifest.
          if (external || await File(mapped).exists()) {
            migrated[old] = mapped;
            if (!files.contains(mapped)) files.add(mapped);
          }
        }
        if (manualQueue.isNotEmpty) {
          final stored = List<String>.of(manualQueue);
          manualQueue.clear();
          for (final old in stored) {
            final restored = migrated[old];
            if (restored != null && files.contains(restored)) manualQueue.add(restored);
          }
        }
        // Respect the saved library selection. Never silently re-add old
        // sandbox imports after the user removes them from the list.
        final migratedFavorites = favorites.map((path) =>
          migrated[path] ?? (path.startsWith('External/') ? (referenced[path] ?? '') : localFilePath(path))).where(files.contains).toSet();
        favorites..clear()..addAll(migratedFavorites);
        // Keep unresolved external identities for later manual relinking.
        for (final stored in (decoded is Map && decoded['favorites'] is List
            ? (decoded['favorites'] as List).whereType<String>() : <String>[])) {
          if (stored.startsWith('External/') && !migrated.containsKey(stored)) favorites.add(stored);
        }
        final names = <String, String>{};
        originalNames.forEach((path, name) {
          final mapped = migrated[path] ?? (path.startsWith('External/') ? (referenced[path] ?? '') : localFilePath(path));
          if (files.contains(mapped)) names[mapped] = name;
        });
        originalNames..clear()..addAll(names);
        final dates = <String, int>{};
        dateAdded.forEach((path, timestamp) {
          final mapped = migrated[path] ?? (path.startsWith('External/') ? (referenced[path] ?? '') : localFilePath(path));
          if (files.contains(mapped)) dates[mapped] = timestamp;
        });
        dateAdded..clear()..addAll(dates);
        final lengths = <String, double>{};
        trackDurations.forEach((path, seconds) {
          final mapped = migrated[path] ?? (path.startsWith('External/') ? (referenced[path] ?? '') : localFilePath(path));
          if (files.contains(mapped)) lengths[mapped] = seconds;
        });
        trackDurations..clear()..addAll(lengths);
        playlists.updateAll((name, tracks) =>
          tracks.map((path) => migrated[path] ??
            (path.startsWith('External/') ? (referenced[path] ?? path) : localFilePath(path))).toList());
        for (final path in files) {
          dateAdded.putIfAbsent(path, () {
            try { return File(path).lastModifiedSync().millisecondsSinceEpoch; }
            on FileSystemException { return DateTime.now().millisecondsSinceEpoch; }
          });
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
        // Unresolved external entries remain in playlists until the user
        // grants access again; do not silently erase playlist membership.
        for (final songs in playlists.values) {
          songs.removeWhere((path) => !files.contains(path) && !path.startsWith('External/'));
        }
      } else {
        await for (final entry in musicDir.list()) {
          if (entry is File && RegExp(r'\.(flac|mp3|m4a|wav|aac)$',
              caseSensitive: false).hasMatch(entry.path)) {
            files.add(entry.path);
            dateAdded[entry.path] = entry.lastModifiedSync().millisecondsSinceEpoch;
          }
        }
      }
      // Never scan entire audio files or mutate the library during startup.
      // Large libraries can otherwise stall the UI and discard references.
      final uniquePaths = files.toSet().toList(growable: false);
      files..clear()..addAll(uniquePaths);
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

  // A tiny library-only index survives reinstall when explicitly saved to Files.
  // No audio is included; relink originals through Files after restoring it.
  Future<void> exportLibraryIndex() async {
    try {
      await saveLibrary();
      final manifest = await libraryManifest();
      await FilePicker.platform.saveFile(
        dialogTitle: 'Save AuraLocal library index (no audio copies)',
        fileName: 'AuraLocal-Library-Index.json',
        type: FileType.custom, allowedExtensions: ['json'],
        bytes: Uint8List.fromList(await manifest.readAsBytes()),
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library index saved to Files. Keep it outside the app.')));
    } catch (e) { if (mounted) setState(() => error = 'Could not export index: $e'); }
  }

  Future<void> restoreLibraryIndex() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['json'], withData: true);
      if (picked == null || picked.files.isEmpty) return;
      final entry = picked.files.first;
      final data = entry.bytes ?? (entry.path == null ? null : await File(entry.path!).readAsBytes());
      if (data == null || data.length > 40000000) throw const FormatException('Invalid index');
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map || decoded['files'] is! List) throw const FormatException('Invalid index');
      final manifest = await libraryManifest();
      await nativeDsp.invokeMethod('stopFile');
      await manifest.writeAsBytes(data, flush: true);
      // Reload and reconnect available bookmarks. Missing originals can be
      // relinked with Link music from Files, without copying the audio.
      files.clear();
      manualQueue.clear(); manualQueueActive = false;
      favorites.clear();
      playlists.clear();
      originalNames.clear();
      trackMetadata.clear();
      songDSP.clear();
      dateAdded.clear();
      trackDurations.clear();
      currentIndex = -1;
      await restoreLibrary();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Index restored. Relink any missing files using + (no copies).')));
    } catch (e) { if (mounted) setState(() => error = 'Could not restore index: $e'); }
  }

  Future<void> clearLibraryList() async {
    final confirmed = await showAuraDialog<bool>(context: context, builder: (dialog) =>
      AlertDialog(title: const Text('Clear remembered songs?'),
        content: const Text('Remove all old song references from this library. Audio files in Files are NOT deleted. Then link only the 9 songs you want using +.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Clear list'))]));
    if (confirmed != true) return;
    await nativeDsp.invokeMethod('stopFile');
    setState(() {
      files.clear(); queuedPaths.clear(); favorites.clear(); playlists.clear();
      originalNames.clear(); trackDurations.clear(); dateAdded.clear();
      currentIndex = -1; isPlaying = false; activePlaylist = null;
      favoritesOnly = false; query = ''; searchController.clear();
    });
    await syncQueue();
    manualQueue.clear(); manualQueueActive = false;
    await saveLibrary();
  }

  Future<void> importInPlace() async {
    try {
      final picked = await fileReferences.invokeListMethod<dynamic>('pickInPlace');
      if (picked == null) return;
      if (picked.isEmpty) return; // User closed Files without selecting audio.
      var added = 0;
      for (final raw in picked) {
        if (raw is! Map || raw['path'] is! String) continue;
        final path = raw['path'] as String;
        // File-provider URLs may be accessible through an open security scope
        // even when Dart's immediate exists() check races provider hydration.
        if (files.contains(path)) continue;
        // Replace an unresolved bookmark instead of creating a ghost duplicate.
        files.remove(manifestTrackKey(path));
        // Do not make a second audio copy; keep the Files provider's URL.
        files.add(path);
        final identity = manifestTrackKey(path);
        if (favorites.remove(identity)) favorites.add(path);
        for (final tracks in playlists.values) {
          for (var i = 0; i < tracks.length; i++) {
            if (tracks[i] == identity) tracks[i] = path;
          }
        }
        originalNames[path] = (raw['name'] as String?) ?? path.split('/').last;
        dateAdded[path] = DateTime.now().millisecondsSinceEpoch;
        added++;
      }
      if (added > 0) {
        if (mounted) setState(() => error = null);
        await syncQueue();
        await saveLibrary();
        await loadMissingDurations();
        if (mounted) setState(() => error = null);
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Could not link Files audio: $e');
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
        // Import already checks exact audio duplicates. Do not run a second
        // destructive full-library deduplication during an active session.
        await syncQueue();
      }
      await saveLibrary();
      if (imported > 0) await loadMissingDurations();
      if (mounted) {
        setState(() => error = null);
        if (skipped > 0) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(skipped == 1 ? 'Already imported  -  original title preserved.'
              : '$skipped existing tracks skipped  -  original titles preserved.'),
        ));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> selectAndPlayTrack(int index) async {
    if (index < 0 || index >= files.length) return;
    try {
      if (queuedPaths.isEmpty || !queuedPaths.contains(files[index])) {
        if (manualQueueActive) {
          await editQueue([...queuedPaths, files[index]]);
        } else {
          await syncQueue();
        }
      }
      final queueIndex = queuedPaths.indexOf(files[index]);
      if (queueIndex < 0) throw PlatformException(code: 'QUEUE',
        message: 'Selected song is not present in playback queue');
      await nativeDsp.invokeMethod('playIndex', {'index': queueIndex});
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
    await nativeDsp.invokeMethod('setNowPlaying', {
      'title': displayName(files[currentIndex]),
      'artist': metadataFor(files[currentIndex])['artist'] ?? '',
    });
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

  Timer? transportHoldTimer;
  int transportHoldTicks = 0;

  void startTransportHold(int direction) {
    HapticFeedback.selectionClick();
    transportHoldTimer?.cancel();
    transportHoldTicks = 0;
    if (currentIndex < 0 || durationSeconds <= 0) return;
    transportHoldTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || currentIndex < 0 || durationSeconds <= 0) {
        stopTransportHold();
        return;
      }
      transportHoldTicks++;
      final step = transportHoldTicks < 5 ? 2 : transportHoldTicks < 15 ? 4 : 8;
      seekSeconds(direction * step);
    });
  }

  void stopTransportHold() {
    transportHoldTimer?.cancel();
    transportHoldTimer = null;
    transportHoldTicks = 0;
  }

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
    // Keep the existing scroll controller mounted and clamp stale positions
    // after the full-screen player returns.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && libraryScroll.hasClients) {
        final position = libraryScroll.position;
        if (position.pixels > position.maxScrollExtent ||
            position.pixels < position.minScrollExtent) {
          libraryScroll.jumpTo(position.pixels.clamp(
            position.minScrollExtent, position.maxScrollExtent).toDouble());
        }
      }
    });
    // Return to the full, stable library even after a playlist, search, or
    // metadata edit. No song files or manifest entries are ever deleted here.
    searchController.clear();
    if (mounted) setState(() {
      query = ''; favoritesOnly = false; activePlaylist = null;
      libraryPlaylistsPage = false;
    });
    // Preserve the existing song directory and scroll position when returning
    // from Now Playing; do not remount the entire list after each minimize.
    dismissPlayer();
  }

  // A single progress source owns translation, blur, color and completion.
  // Measure the footer's actual global top rather than assume a 73px height.
  double _collapsedPlayerOffset() {
    final render = miniPlayerPositionKey.currentContext?.findRenderObject();
    if (render is RenderBox && render.hasSize) {
      final location = render.localToGlobal(Offset.zero);
      final root = context.findRenderObject();
      if (root is RenderBox && root.hasSize) {
        final y = root.globalToLocal(location).dy;
        if (y > 0 && y.isFinite) _measuredCollapsedOffset = y;
      }
    }
    if (_measuredCollapsedOffset > 0) return _measuredCollapsedOffset;
    return math.max(1.0, MediaQuery.sizeOf(context).height - 95);
  }

  void _completePlayerCollapse() {
    if (!mounted) return;
    // Reconcile a stale retained ListView offset after the footer reappears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !libraryScroll.hasClients) return;
      final position = libraryScroll.position;
      if (!position.hasContentDimensions) return;
      final bounded = position.pixels.clamp(
        position.minScrollExtent, position.maxScrollExtent).toDouble();
      if ((bounded - position.pixels).abs() > 0.5) {
        libraryScroll.jumpTo(bounded);
      }
    });
    _playerGestureStarted = false;
    draggingPlayer = false;
    dismissingPlayer = false;
    if (!libraryHome) setState(() => libraryHome = true);
  }

  void dismissPlayer() {
    if (libraryHome) return;
    draggingPlayer = false;
    dismissingPlayer = true;
    if (playerMotion.value <= 0.001) {
      playerMotion.value = 0;
      _completePlayerCollapse();
      return;
    }
    playerMotion.animateTo(0, duration: Duration(
      milliseconds: (120 + 180 * playerMotion.value).round()),
      curve: Curves.easeOutCubic).whenComplete(() {
        if (mounted && playerMotion.value <= 0.001 && !draggingPlayer) {
          _completePlayerCollapse();
        }
      });
  }

  void showPlayer() {
    if (!mounted) return;
    _collapsedPlayerOffset();
    setState(() { libraryHome = false; dismissingPlayer = false; draggingPlayer = false; });
    playerMotion.animateTo(1, duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic);
  }

  void startMiniSwipe() {
    if (!libraryHome) return;
    _collapsedPlayerOffset();
    playerMotion.stop();
    _playerGestureStarted = true;
    miniSwipeTravel = 0;
    setState(() { libraryHome = false; draggingPlayer = true; dismissingPlayer = false; });
  }

  void updateMiniSwipe(DragUpdateDetails details) {
    if (!_playerGestureStarted) return;
    miniSwipeTravel += details.delta.dy;
    final height = _collapsedPlayerOffset();
    playerMotion.value = (playerMotion.value - details.delta.dy / height).clamp(0.0, 1.0);
  }

  void finishMiniSwipe(DragEndDetails details) {
    _playerGestureStarted = false;
    draggingPlayer = false;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -260 || (velocity <= 260 && playerMotion.value > 0.12)) {
      playerMotion.animateTo(1, duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic);
    } else {
      dismissPlayer();
    }
  }

  void startPlayerDrag(DragStartDetails details) {
    playerMotion.stop();
    draggingPlayer = true;
    _playerGestureStarted = true;
  }

  void updatePlayerDrag(DragUpdateDetails details) {
    if (!_playerGestureStarted) return;
    playerMotion.value = (playerMotion.value - details.delta.dy / _collapsedPlayerOffset())
      .clamp(0.0, 1.0);
  }

  void cancelPlayerDrag() {
    _playerGestureStarted = false;
    draggingPlayer = false;
    if (playerMotion.value > 0.5) {
      playerMotion.animateTo(1, curve: Curves.easeOutCubic);
    } else {
      dismissPlayer();
    }
  }

  void finishPlayerDrag(DragEndDetails details) {
    _playerGestureStarted = false;
    draggingPlayer = false;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 260 || (velocity >= -260 && playerMotion.value < 0.75)) {
      dismissPlayer();
    } else {
      playerMotion.animateTo(1, duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic);
    }
  }

  String displayName(String path) {
    final edited = trackMetadata[manifestTrackKey(path)]?['title'];
    if (edited != null && edited.trim().isNotEmpty) return edited.trim();
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
    final name = await showAuraDialog<String>(context: context, builder: (context) => AlertDialog(
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
    setState(() { playlists[name] = []; if (!libraryPlaylistsPage) activePlaylist = name; });
    await syncQueue();
    await saveLibrary();
  }

  Future<void> addToPlaylist(String path) async {
    if (playlists.isEmpty) await createPlaylist();
    if (!mounted || playlists.isEmpty) return;
    final selected = await showAuraSheet<String>(
      context: context,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Add to playlist')),
        ListTile(leading: const Icon(Icons.add_circle_rounded),
          title: const Text('New playlist'),
          onTap: () => Navigator.pop(context, '__create__')),
        for (final name in playlists.keys)
          ListTile(leading: const Icon(Icons.playlist_add_rounded), title: Text(name),
            onTap: () => Navigator.pop(context, name)),
      ])),
    );
    if (selected == null) return;
    if (selected == '__create__') {
      final before = playlists.keys.toSet();
      await createPlaylist();
      if (!mounted) return;
      final created = playlists.keys.where((name) => !before.contains(name)).toList();
      if (created.isEmpty) return;
      setState(() { if (!playlists[created.first]!.contains(path)) playlists[created.first]!.add(path); });
    } else {
      if (!playlists.containsKey(selected)) return;
      setState(() { if (!playlists[selected]!.contains(path)) playlists[selected]!.add(path); });
    }
    await saveLibrary();
    await syncQueue();
  }

  Future<void> renamePlaylist(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showAuraDialog<String>(context: context, builder: (context) => AlertDialog(
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
    showAuraSheet<void>(context: context, builder: (sheet) => SafeArea(child:
      Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.edit), title: const Text('Rename playlist'), onTap: () {
          Navigator.pop(sheet); renamePlaylist(name);
        }),
        ListTile(leading: const Icon(Icons.delete_outline_rounded), title: const Text('Delete playlist'), onTap: () async {
          Navigator.pop(sheet);
          setState(() { playlists.remove(name); if (activePlaylist == name) activePlaylist = null; });
          await saveLibrary();
        }),
      ])));
  }

  Future<void> _renameTrack(String path) async {
    final controller = TextEditingController(text: displayName(path));
    final renamed = await showAuraDialog<String>(context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(controller: controller, autofocus: true,
          decoration: const InputDecoration(labelText: 'Track title')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('Save')),
        ]));
    controller.dispose();
    if (renamed == null || renamed.trim().isEmpty) return;
    await saveTrackMetadata(path, {...metadataFor(path), 'title': renamed});
  }

  void trackMenu(String path) {
    showBlurredActionSheet((sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(15, 15, 15, 22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _settingsSection('Track actions', [
            _settingsOption(label: favorites.contains(path)
                ? 'Remove from Favorites' : 'Add to Favorites',
              icon: favorites.contains(path) ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
              accent: GoogleLetterPalette.red,
              onTap: () { Navigator.pop(sheet); toggleFavorite(path); }),
            _settingsOption(label: 'Add to Playlist',
              icon: Icons.playlist_add_rounded,
              accent: GoogleLetterPalette.yellow,
              onTap: () { Navigator.pop(sheet); addToPlaylist(path); }),
            _settingsOption(label: 'Get Info',
              icon: Icons.info_rounded,
              accent: GoogleLetterPalette.green,
              onTap: () { Navigator.pop(sheet); showTrackDetails(path); }),
            _settingsOption(label: 'Rename',
              icon: Icons.edit_rounded,
              accent: GoogleLetterPalette.blue,
              onTap: () { Navigator.pop(sheet); _renameTrack(path); }),
            _settingsOption(label: 'Edit Metadata',
              icon: Icons.description_rounded,
              accent: GoogleLetterPalette.red,
              onTap: () {
                Navigator.pop(sheet);
                showAuraSheet<void>(context: context,
                  isScrollControlled: true,
                  backgroundColor: GoogleLetterPalette.cream,
                  builder: (editor) => SafeArea(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(height: 280, child: Center(child: AspectRatio(
                        aspectRatio: 1, child: ArtworkFlipCard(
                          trackName: displayName(path), metadata: metadataFor(path),
                          onSave: (data) => saveTrackMetadata(path, data))))),
                      const Text('Tap artwork to add or search metadata.'),
                    ]))));
              }),
          ]),
        ])));
  }

  Future<void> moveQueuedTrack(int from, int to) async {
    if (from < 0 || from >= queuedPaths.length ||
        to < 0 || to >= queuedPaths.length) return;
    final next = List<String>.of(queuedPaths);
    final path = next.removeAt(from);
    next.insert(to, path);
    await editQueue(next);
  }

  void showQueue() {
    showAuraSheet<void>(context: context, isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, redraw) => SafeArea(
        child: FractionallySizedBox(heightFactor: 0.78, child: Column(children: [
          ListTile(title: const Text('Up Next'),
            subtitle: Text(manualQueueActive ? 'Custom playback order' :
              (shuffle ? 'Shuffling library order' : 'Following the current library sort order')),
            trailing: PopupMenuButton<String>(
              tooltip: 'Queue actions',
              onSelected: (action) async {
                if (action == 'clear') await resetQueueToLibraryOrder();
                if (action == 'reset') await resetQueueToLibraryOrder();
                if (action == 'add' && currentIndex >= 0 && currentIndex < files.length) {
                  await editQueue([...queuedPaths, files[currentIndex]]);
                }
                redraw(() {});
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: Text('Add current song')),
                PopupMenuItem(value: 'clear', child: Text('Clear queue')),
                PopupMenuItem(value: 'reset', child: Text('Restore library order')),
              ], icon: const Icon(Icons.more_vert_rounded))),
          Expanded(child: ReorderableListView.builder(
            itemCount: queuedPaths.length,
            onReorder: (oldIndex, newIndex) async {
              final items = List<String>.of(queuedPaths);
              if (newIndex > oldIndex) newIndex--;
              final moved = items.removeAt(oldIndex);
              items.insert(newIndex, moved);
              await editQueue(items);
              redraw(() {});
            },
            itemBuilder: (_, position) {
              final path = queuedPaths[position];
              final index = files.indexOf(path);
              if (index < 0) return SizedBox.shrink(key: ValueKey('missing-$position'));
              return ListTile(
                key: ValueKey('queue-$position-$path'),
                leading: Icon(index == currentIndex
                  ? Icons.graphic_eq_rounded : Icons.music_note_rounded),
                title: Text(displayName(path), maxLines: 1,
                  softWrap: false, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700,
                    letterSpacing: -0.5)),
                subtitle: index == currentIndex ? const Text('Now playing') : null,
                trailing: IconButton(icon: const Icon(Icons.close_rounded),
                  tooltip: 'Remove from queue', onPressed: () async {
                    final items = List<String>.of(queuedPaths)..removeAt(position);
                    await editQueue(items);
                    redraw(() {});
                  }),
                onTap: () async {
                  Navigator.pop(sheet);
                  if (manualQueueActive) {
                    await nativeDsp.invokeMethod('playIndex', {'index': position});
                  } else {
                    await selectAndPlayTrack(index);
                  }
                },
              );
            },
          )),
        ])))));
  }

  Future<void> showPitchWheel(StateSetter refresh) async {
    await showAuraSheet<void>(context: context, backgroundColor: GoogleLetterPalette.cream,
      isScrollControlled: true, builder: (sheet) => SafeArea(child: SizedBox(height: 340,
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close_rounded)),
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
    await showAuraSheet<void>(context: context, backgroundColor: GoogleLetterPalette.cream,
      isScrollControlled: true, builder: (sheet) => SafeArea(child: SizedBox(height: 330,
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => Navigator.pop(sheet), icon: const Icon(Icons.close_rounded)),
            const Expanded(child: Text('Adjust Tempo', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(width: 48),
          ]),
          Expanded(child: CupertinoPicker(
            scrollController: FixedExtentScrollController(initialItem: (playbackSpeed * 100).round() - 50),
            itemExtent: 44,
            onSelectedItemChanged: (i) {
              refresh(() {
                playbackSpeed = (i + 50) / 100;
                if (linkedPitchTempo) {
                  final cents = (1200 * math.log(playbackSpeed) / math.ln2)
                      .round().clamp(-1200, 1200);
                  pitchSemitones = (cents / 100).truncate();
                  pitchCents = (cents - pitchSemitones * 100).toDouble();
                }
              });
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
        'preampDb': preampDb,
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
    final name = await showAuraDialog<String>(
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
      final replaceExisting = await showAuraDialog<bool>(
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
    final confirmed = await showAuraDialog<bool>(
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

  int? activeEqBand;

  void updateCurve(Offset point, Size size, StateSetter refresh) {
    if (size.width <= 0 || size.height <= 0) return;
    final index = activeEqBand ??
        ((point.dx / size.width) * 10 - 0.5).round().clamp(0, 9);
    final gain = (12 - point.dy / size.height * 24).clamp(-12.0, 12.0);
    setManualEQBand(index, gain.toDouble(), refresh);
  }

  void showEqualizer() {
    showAuraSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: GoogleLetterPalette.cream,
      enableDrag: false, // EQ pan gestures must not dismiss the sheet.
      showDragHandle: false,
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
                    const Icon(Icons.equalizer_rounded, color: accent, size: 27),
                    const SizedBox(width: 12),
                    const Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Audio Equalizer', style: TextStyle(
                          fontSize: 21, fontWeight: FontWeight.bold)),

                      ],
                    )),
                    IconButton(tooltip: 'Close equalizer',
                      icon: const Icon(Icons.close_rounded, color: GoogleLetterPalette.ink),
                      onPressed: () => Navigator.pop(sheetContext)),
                    Switch.adaptive(
                      value: eqEnabled,
                      activeColor: accent,
                      onChanged: (enabled) {
                        refresh(() => eqEnabled = enabled);
                        applyNativeEQ();
                      },
                    ),
                  ]),
                  const SizedBox(height: 12),
                  const Align(alignment: Alignment.centerLeft,
                    child: Padding(padding: EdgeInsets.only(left: 6, bottom: 7),
                      child: Text('EQ preset', style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800,
                        color: GoogleLetterPalette.creamText)))),
                  DropdownButtonFormField<String>(
                    key: ValueKey('eq-$eqPreset'),
                    initialValue: eqPreset == 'Custom' ? null : eqPreset,
                    isExpanded: true,
                    decoration: InputDecoration(
                      filled: true, fillColor: GoogleLetterPalette.creamDivider.withValues(alpha: 0.40),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none)),
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
                        icon: const Icon(Icons.delete_outline_rounded), label: const Text('Delete preset'))),
                  const SizedBox(height: 6),
                  const SizedBox(height: 12),
                  const Text('Drag a dot up to boost, down to cut',
                    style: TextStyle(color: GoogleLetterPalette.creamText, fontSize: 12)),
                  const SizedBox(height: 14),
                  Expanded(child: LayoutBuilder(builder: (_, bounds) =>
                    GestureDetector(behavior: HitTestBehavior.opaque,
                      onPanDown: (details) {
                        activeEqBand = ((details.localPosition.dx / bounds.maxWidth) * 10 - 0.5)
                            .round().clamp(0, 9);
                      },
                      onPanStart: (details) {
                        activeEqBand = ((details.localPosition.dx / bounds.maxWidth) * 10 - 0.5)
                            .round().clamp(0, 9);
                        updateCurve(details.localPosition, bounds.biggest, refresh);
                      },
                      onPanUpdate: (details) => updateCurve(details.localPosition, bounds.biggest, refresh),
                      onPanEnd: (_) { activeEqBand = null; applyNativeEQ(); },
                      onPanCancel: () => activeEqBand = null,
                      child: CustomPaint(size: bounds.biggest,
                        painter: EditableEqCurvePainter(gains: List.of(eqGains), accent: accent)))),
                  ),
                  const SizedBox(height: 7),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [for (final hz in eqFrequencies)
                      Expanded(child: Text(hz, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, color: GoogleLetterPalette.creamText)))]),
                  const SizedBox(height: 14),
                  Row(children: [
                    const Text('Preamp', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: GoogleLetterPalette.ink)),
                    const Spacer(),
                    Text('${preampDb >= 0 ? '+' : ''}${preampDb.toStringAsFixed(1)} dB'),
                  ]),
                  dragOnlySlider(value: preampDb, min: -12, max: 12, divisions: 48,
                    onReset: () {
                      refresh(() => preampDb = 0);
                      setState(() {});
                      applyNativeEQ();
                    },
                    onChanged: (value) {
                      refresh(() => preampDb = value);
                      setState(() {});
                      scheduleEQUpdate();
                    },
                    onChangeEnd: (_) => applyNativeEQ()),
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
                        style: const TextStyle(color: GoogleLetterPalette.creamText)),
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

  Widget dragOnlySlider({required double value, required double min,
    required double max, int? divisions, required ValueChanged<double> onChanged,
    VoidCallback? onReset, ValueChanged<double>? onChangeEnd}) {
    return LayoutBuilder(builder: (context, bounds) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onReset,
      onHorizontalDragUpdate: (details) {
        if (bounds.maxWidth <= 0) return;
        final next = (value + details.delta.dx / bounds.maxWidth * (max - min))
            .clamp(min, max).toDouble();
        onChanged(next);
      },
      onHorizontalDragEnd: (_) => onChangeEnd?.call(value),
      child: IgnorePointer(child: Slider(value: value, min: min, max: max,
        divisions: divisions, onChanged: (_) {})),
    ));
  }

  Future<void> showThreePrecisionWheels(StateSetter parentRefresh) async {
    await showAuraSheet<void>(context: context,
      isScrollControlled: true,
      backgroundColor: GoogleLetterPalette.cream,
      builder: (sheet) => StatefulBuilder(builder: (wheelContext, wheelRefresh) =>
        SafeArea(child: Padding(padding: const EdgeInsets.all(14),
          child: SizedBox(height: 350, child: Column(children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(sheet)),
              const Expanded(child: Text('Fine tuning', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              const SizedBox(width: 48),
            ]),
            Row(children: [
              Expanded(child: Center(child: Text(linkedPitchTempo ? 'Tapespeed' : 'Tempo'))),
              if (!linkedPitchTempo) const Expanded(child: Center(child: Text('Semitones'))),
              if (!linkedPitchTempo) const Expanded(child: Center(child: Text('Cents'))),
              const Expanded(child: Center(child: Text('Preamp'))),
            ]),
            Expanded(child: Row(children: [
              Expanded(child: CupertinoPicker(
                scrollController: FixedExtentScrollController(
                  initialItem: (playbackSpeed * 100).round().clamp(50, 200) - 50),
                itemExtent: 40,
                onSelectedItemChanged: (value) {
                  parentRefresh(() {
                    playbackSpeed = (value + 50) / 100;
                    if (linkedPitchTempo) {
                      final cents = (1200 * math.log(playbackSpeed) / math.ln2)
                          .round().clamp(-1200, 1200);
                      pitchSemitones = (cents / 100).truncate();
                      pitchCents = (cents - pitchSemitones * 100).toDouble();
                    }
                  });
                  wheelRefresh(() {});
                  setState(() {});
                  scheduleNativePitchTempoUpdate();
                },
                children: [for (var i = 50; i <= 200; i++) Center(child: Text('$i%'))])),
              if (!linkedPitchTempo) Expanded(child: CupertinoPicker(
                scrollController: FixedExtentScrollController(
                  initialItem: pitchSemitones.clamp(-12, 12) + 12),
                itemExtent: 40,
                onSelectedItemChanged: (value) {
                  parentRefresh(() => pitchSemitones = value - 12);
                  wheelRefresh(() {});
                  setState(() {});
                  scheduleNativePitchTempoUpdate();
                },
                children: [for (var i = -12; i <= 12; i++)
                  Center(child: Text('${i >= 0 ? '+' : ''}$i'))])),
              if (!linkedPitchTempo) Expanded(child: CupertinoPicker(
                scrollController: FixedExtentScrollController(
                  initialItem: pitchCents.round().clamp(-99, 99) + 99),
                itemExtent: 40,
                onSelectedItemChanged: (value) {
                  parentRefresh(() => pitchCents = (value - 99).toDouble());
                  wheelRefresh(() {});
                  setState(() {});
                  scheduleNativePitchTempoUpdate();
                },
                children: [for (var i = -99; i <= 99; i++)
                  Center(child: Text('${i >= 0 ? '+' : ''}$i'))])),
              Expanded(child: CupertinoPicker(
                scrollController: FixedExtentScrollController(
                  initialItem: ((preampDb + 12) * 2).round().clamp(0, 48)),
                itemExtent: 40,
                onSelectedItemChanged: (value) {
                  parentRefresh(() => preampDb = value / 2 - 12);
                  wheelRefresh(() {});
                  setState(() {});
                  scheduleEQUpdate();
                },
                children: [for (var i = 0; i <= 48; i++)
                  Center(child: Text('${(i / 2 - 12).toStringAsFixed(1)} dB',
                    style: const TextStyle(fontSize: 12)))])),
            ])),
          ]))))));
  }

  Widget _audioControlRow({required IconData icon, required Color accent,
      required String name, required String reading, required Widget control}) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 58, child: Icon(icon, color: GoogleLetterPalette.ink, size: 39)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900,
              color: GoogleLetterPalette.ink)),
            const Spacer(),
            Text(reading, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              color: GoogleLetterPalette.creamText)),
          ]),
          const SizedBox(height: 5),
          SliderTheme(data: Theme.of(context).sliderTheme.copyWith(
            trackHeight: 7,
            activeTrackColor: accent,
            thumbColor: accent,
            inactiveTrackColor: GoogleLetterPalette.creamDivider,
            overlayColor: accent.withValues(alpha: 0.18),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12)),
            child: control),
        ])),
      ]));
  }

  void showAudioSettings() {
    showAuraSheet<void>(context: context,
      isScrollControlled: true,
      backgroundColor: GoogleLetterPalette.cream,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, refresh) =>
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 16),
            _audioControlRow(icon: Icons.speed_rounded,
              accent: GoogleLetterPalette.yellow,
              name: linkedPitchTempo ? 'Tapespeed' : 'Tempo',
              reading: '${(playbackSpeed * 100).round()}%',
              control: dragOnlySlider(
                value: playbackSpeed < 1 ? (playbackSpeed - 1) * 2 : playbackSpeed - 1,
                min: -1, max: 1, divisions: 200,
                onReset: () {
                  refresh(() {
                    playbackSpeed = 1;
                    if (linkedPitchTempo) { pitchSemitones = 0; pitchCents = 0; }
                  });
                  setState(() {});
                  updateNativePitchTempo();
                },
                onChanged: (value) {
                  refresh(() {
                    playbackSpeed = value < 0 ? 1 + value / 2 : 1 + value;
                    if (linkedPitchTempo) {
                      final cents = (1200 * math.log(playbackSpeed) / math.ln2)
                          .round().clamp(-1200, 1200);
                      pitchSemitones = (cents / 100).truncate();
                      pitchCents = (cents - pitchSemitones * 100).toDouble();
                    }
                  });
                  setState(() {});
                  scheduleNativePitchTempoUpdate();
                }, onChangeEnd: (_) => updateNativePitchTempo())),
            IconButton(
              tooltip: linkedPitchTempo ? 'Unlink pitch and tempo' : 'Link pitch and tempo',
              icon: Icon(linkedPitchTempo ? Icons.link_rounded : Icons.link_off_rounded,
                size: 36, color: GoogleLetterPalette.yellow),
              onPressed: () {
                HapticFeedback.selectionClick();
                refresh(() {
                  linkedPitchTempo = !linkedPitchTempo;
                  if (linkedPitchTempo) {
                    final cents = (1200 * math.log(playbackSpeed) / math.ln2)
                        .round().clamp(-1200, 1200);
                    pitchSemitones = (cents / 100).truncate();
                    pitchCents = (cents - pitchSemitones * 100).toDouble();
                  }
                });
                setState(() {});
                updateNativePitchTempo();
              }),
            if (!linkedPitchTempo)
              _audioControlRow(icon: Icons.music_note_rounded,
                accent: GoogleLetterPalette.red,
                name: 'Pitch',
                reading: (pitchSemitones + pitchCents / 100).toStringAsFixed(2),
                control: dragOnlySlider(
                  value: (pitchSemitones + pitchCents / 100).clamp(-12.0, 12.0).toDouble(),
                  min: -12, max: 12,
                  onReset: () {
                    refresh(() { pitchSemitones = 0; pitchCents = 0; });
                    setState(() {});
                    updateNativePitchTempo();
                  },
                  onChanged: (value) {
                    final cents = (value * 100).round().clamp(-1200, 1200);
                    refresh(() {
                      pitchSemitones = (cents / 100).truncate();
                      pitchCents = (cents - pitchSemitones * 100).toDouble();
                    });
                    setState(() {});
                    scheduleNativePitchTempoUpdate();
                  }, onChangeEnd: (_) => updateNativePitchTempo())),
            _audioControlRow(icon: Icons.volume_up_rounded,
              accent: GoogleLetterPalette.green,
              name: 'Preamp',
              reading: '${preampDb.toStringAsFixed(1)} dB',
              control: dragOnlySlider(value: preampDb, min: -12, max: 12, divisions: 48,
                onReset: () {
                  refresh(() => preampDb = 0);
                  setState(() {});
                  applyNativeEQ();
                },
                onChanged: (value) {
                  refresh(() => preampDb = value);
                  setState(() {});
                  scheduleEQUpdate();
                }, onChangeEnd: (_) => applyNativeEQ())),
            const SizedBox(height: 16),
            const Divider(color: GoogleLetterPalette.creamDivider, thickness: 1),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              Column(children: [
                IconButton(tooltip: 'Open precision tuning wheels',
                  iconSize: 72,
                  style: IconButton.styleFrom(backgroundColor: GoogleLetterPalette.creamDivider,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
                  icon: const Padding(padding: EdgeInsets.all(14), child: _TuningForkIcon()),
                  onPressed: () => showThreePrecisionWheels(refresh)),
                const SizedBox(height: 5),
                const Text('Fine tuning', style: TextStyle(
                  fontWeight: FontWeight.w800, color: GoogleLetterPalette.ink)),
              ]),
              Expanded(child: Padding(padding: const EdgeInsets.only(left: 20),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: GoogleLetterPalette.red,
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13)),
                  icon: const Icon(Icons.restart_alt_rounded),
                  onPressed: () async {
                    refresh(() { pitchSemitones = 0; pitchCents = 0; playbackSpeed = 1; });
                    setState(() {});
                    await updateNativePitchTempo();
                  },
                  label: const Text('Reset pitch & tempo', maxLines: 2,
                    textAlign: TextAlign.center)),
              )),
            ]),
          ])))));
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
      if (sortMode == 'length') await syncQueue();
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

  Future<void> probeEmbeddedArt(String path) async {
    if (embeddedArt.containsKey(path)) return;
    embeddedArt[path] = null;
    try {
      final encoded = await nativeDsp.invokeMethod<String>('embeddedArtwork', {'path': path});
      if (encoded != null && encoded.isNotEmpty && encoded.length < 24000000) {
        embeddedArt[path] = base64Decode(encoded);
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Map<String, String> metadataFor(String path) =>
    trackMetadata[manifestTrackKey(path)] ?? const <String, String>{};

  Widget songArtworkThumbnail(String path) {
    const fallback = ColoredBox(color: Color(0xFF352729),
      child: Icon(Icons.music_note_rounded, size: 23, color: Colors.white70));
    final meta = metadataFor(path);
    final local = meta['artworkData'] ?? '';
    final remote = meta['artworkUrl'] ?? '';
    final embedded = embeddedArt[path];
    Widget photo = fallback;
    if (local.isNotEmpty) {
      try {
        final bytes = localThumbnailBytes.putIfAbsent(path,
          () => base64Decode(local));
        photo = Image.memory(bytes, fit: BoxFit.cover,
          cacheWidth: 128, cacheHeight: 128, gaplessPlayback: true,
          errorBuilder: (_, __, ___) => fallback);
      } catch (_) { photo = fallback; }
    } else if (embedded != null && embedded.isNotEmpty) {
      photo = Image.memory(embedded, fit: BoxFit.cover,
        cacheWidth: 128, cacheHeight: 128, gaplessPlayback: true,
        errorBuilder: (_, __, ___) => fallback);
    } else if (remote.isNotEmpty) {
      photo = Image.network(remote, fit: BoxFit.cover,
        cacheWidth: 128, cacheHeight: 128, gaplessPlayback: true,
        errorBuilder: (_, __, ___) => fallback);
    }
    // Query native embedded-art metadata only for on-screen rows.
    if (!embeddedArt.containsKey(path) && local.isEmpty && remote.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && files.contains(path)) probeEmbeddedArt(path);
      });
    }
    return SizedBox(width: 40, height: 40, child: ClipRRect(
      borderRadius: BorderRadius.circular(6), child: photo));
  }


  Future<void> showTrackDetails(String path) async {
    Map<dynamic, dynamic>? probe;
    try { probe = await nativeDsp.invokeMapMethod<dynamic, dynamic>('probeFileDetails', {'path': path}); }
    on PlatformException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Cannot inspect this file')));
      return;
    }
    if (!mounted) return;
    final details = <String, String>{
      'Filename': originalNames[path] ?? path.split('/').last,
      'Format': path.split('.').last.toUpperCase(),
      for (final entry in (probe ?? const <dynamic, dynamic>{}).entries)
        if (entry.value != null && entry.value.toString().trim().isNotEmpty &&
            !['unknown', 'null', 'n/a', 'none', 'unavailable']
                .contains(entry.value.toString().trim().toLowerCase()))
          entry.key.toString(): entry.value.toString(),
      'Duration': clock(trackDurations[path] ??
          (path == (currentIndex >= 0 && currentIndex < files.length ? files[currentIndex] : '')
              ? durationSeconds : 0)),
      for (final entry in metadataFor(path).entries)
        if (entry.value.trim().isNotEmpty &&
            !['unknown', 'null', 'n/a', 'none'].contains(entry.value.trim().toLowerCase()))
          entry.key: entry.value,
    };
    await showAuraSheet<void>(context: context, isScrollControlled: true,
      builder: (sheet) => SafeArea(child: Padding(padding: const EdgeInsets.all(18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Technical file details', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.60),
            child: ListView(shrinkWrap: true, children: [for (final entry in details.entries)
              ListTile(dense: true, title: Text(entry.key), subtitle: SelectableText(entry.value))])),
        ]))));
  }

  Future<void> saveTrackMetadata(String path, Map<String, String> data) async {
    localThumbnailBytes.remove(path);
    if (mounted) setState(() => trackMetadata[manifestTrackKey(path)] = Map.of(data));
    await saveLibrary();
    if (currentIndex >= 0 && currentIndex < files.length && files[currentIndex] == path) {
      await setNativeTitle();
    }
    if (sortMode == 'alphabetical') await syncQueue();
    if (mounted) setState(() {});
  }

  Future<void> showBlurredActionSheet(Widget Function(BuildContext) builder) async {
    await showAuraSheet<void>(context: context,
      backgroundColor: GoogleLetterPalette.cream,
      builder: (sheet) => Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 11),
        child: builder(sheet)));
  }

  Widget _settingsOption({required String label, required IconData icon,
      required Color accent, required VoidCallback onTap, String? detail}) =>
    ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: DecoratedBox(decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12)),
        child: SizedBox.square(dimension: 42,
          child: Icon(icon, color: accent, size: 25))),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w800,
        fontSize: 15, color: GoogleLetterPalette.ink)),
      subtitle: detail == null ? null : Text(detail,
        style: const TextStyle(fontSize: 12, color: GoogleLetterPalette.creamText)),
      trailing: const Icon(Icons.chevron_right_rounded,
        size: 20, color: GoogleLetterPalette.creamText),
      onTap: onTap);

  Widget _settingsSection(String heading, List<Widget> items) =>
    Padding(padding: const EdgeInsets.only(bottom: 19), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 9),
          child: Text(heading, style: const TextStyle(fontSize: 13,
            fontWeight: FontWeight.w900, color: GoogleLetterPalette.creamText))),
        DecoratedBox(decoration: BoxDecoration(
          color: const Color(0xFFFFFAEF), borderRadius: BorderRadius.circular(18)),
          child: Column(children: [for (var i = 0; i < items.length; i++) ...[
            if (i != 0) const Divider(indent: 64, endIndent: 12,
              height: 1, thickness: 0.7, color: GoogleLetterPalette.creamDivider),
            items[i],
          ]])),
      ]));

  void showLibraryOptionsPane() {
    showGeneralDialog<void>(context: context,
      barrierDismissible: true,
      barrierLabel: 'Close library settings',
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 290),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
        SafeArea(child: Align(alignment: Alignment.centerRight,
          child: Padding(padding: const EdgeInsets.all(13),
            child: Material(color: Colors.transparent,
              child: Container(
                width: math.min(385, MediaQuery.sizeOf(dialogContext).width - 26),
                height: MediaQuery.sizeOf(dialogContext).height * 0.82,
                decoration: BoxDecoration(color: GoogleLetterPalette.cream,
                  borderRadius: BorderRadius.circular(29)),
                child: ClipRRect(borderRadius: BorderRadius.circular(29),
                  child: Column(children: [
                    Padding(padding: const EdgeInsets.fromLTRB(22, 18, 11, 9),
                      child: Row(children: [
                        const Expanded(child: Text('Library settings',
                          style: TextStyle(color: GoogleLetterPalette.ink,
                            fontSize: 25, fontWeight: FontWeight.w900))),
                        IconButton(icon: const Icon(Icons.close_rounded),
                          tooltip: 'Close library settings',
                          onPressed: () => Navigator.pop(dialogContext)),
                      ])),
                    Expanded(child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                      children: [
                        _settingsSection('Music import', [
                          _settingsOption(label: 'Link music from Files',
                            detail: 'No duplicate audio copies',
                            icon: Icons.link_rounded,
                            accent: GoogleLetterPalette.yellow,
                            onTap: () { Navigator.pop(dialogContext); importInPlace(); }),
                          _settingsOption(label: 'Copy music into app',
                            icon: Icons.file_copy_rounded,
                            accent: GoogleLetterPalette.green,
                            onTap: () { Navigator.pop(dialogContext); import(); }),
                        ]),
                        _settingsSection('Library index', [
                          _settingsOption(label: 'Export library index',
                            icon: Icons.ios_share_rounded,
                            accent: GoogleLetterPalette.yellow,
                            onTap: () { Navigator.pop(dialogContext); exportLibraryIndex(); }),
                          _settingsOption(label: 'Restore library index',
                            icon: Icons.folder_open_rounded,
                            accent: GoogleLetterPalette.green,
                            onTap: () { Navigator.pop(dialogContext); restoreLibraryIndex(); }),
                        ]),
                        _settingsSection('Backup and restore', [
                          _settingsOption(label: 'Back up entire library',
                            icon: Icons.cloud_upload_rounded,
                            accent: GoogleLetterPalette.yellow,
                            onTap: () { Navigator.pop(dialogContext); exportLibraryBackup(); }),
                          _settingsOption(label: 'Restore full backup',
                            icon: Icons.restore_rounded,
                            accent: GoogleLetterPalette.green,
                            onTap: () { Navigator.pop(dialogContext); restoreLibraryBackup(); }),
                        ]),
                        _settingsSection('Maintenance', [
                          _settingsOption(label: 'Clear remembered song list',
                            detail: 'Does not delete original audio files',
                            icon: Icons.playlist_remove_rounded,
                            accent: GoogleLetterPalette.red,
                            onTap: () { Navigator.pop(dialogContext); clearLibraryList(); }),
                        ]),
                        Center(child: Text('AuraLocal Build $auraBuildNumber',
                          style: const TextStyle(fontSize: 12,
                            color: GoogleLetterPalette.creamText))),
                      ])),
                  ]))))))),
      transitionBuilder: (_, animation, __, child) =>
        Stack(children: [
          Positioned.fill(child: IgnorePointer(child: AnimatedBuilder(
            animation: animation,
            builder: (_, __) => BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: 5 * animation.value, sigmaY: 5 * animation.value),
              child: const SizedBox.expand())))),
          FadeTransition(opacity: animation, child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0.20, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child)),
        ]));
  }

  void showQuickAddMenu() {
    showBlurredActionSheet((sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Align(alignment: Alignment.centerLeft,
            child: Padding(padding: EdgeInsets.fromLTRB(8, 8, 8, 15),
              child: Text('Add to your library', style: TextStyle(
                fontSize: 23, fontWeight: FontWeight.w900)))),
          _settingsSection('Choose an action', [
            _settingsOption(label: 'Link a song from Files',
              detail: 'No audio copy; keeps the original file',
              icon: Icons.link_rounded, accent: GoogleLetterPalette.yellow,
              onTap: () { Navigator.pop(sheet); importInPlace(); }),
            _settingsOption(label: 'Import a song as a copy',
              detail: 'Keep a copy inside AuraLocal',
              icon: Icons.file_copy_rounded, accent: GoogleLetterPalette.green,
              onTap: () { Navigator.pop(sheet); import(); }),
            _settingsOption(label: 'Create a playlist',
              icon: Icons.playlist_add_rounded, accent: GoogleLetterPalette.red,
              onTap: () { Navigator.pop(sheet); createPlaylist(); }),
          ]),
        ])));
  }

  Widget buildLibrary() {
    final matches = orderedTrackIndices();
    return Scaffold(
      appBar: AppBar(titleSpacing: 8, title: TextButton.icon(
        onPressed: () => setState(() {
          libraryPlaylistsPage = !libraryPlaylistsPage;
          if (!libraryPlaylistsPage) { activePlaylist = null; favoritesOnly = false; }
        }),
        label: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(libraryPlaylistsPage ? 'Your Playlists' : 'Your Library',
            maxLines: 1, softWrap: false,
            style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w900,
              color: Color(0xFF221A1B)))),
        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 21,
          color: Color(0xFF221A1B))), actions: [
        IconButton(tooltip: 'New playlist', icon: const Icon(Icons.playlist_add_rounded, size: 29), onPressed: createPlaylist),
        IconButton(tooltip: 'Add music or playlist', icon: const ChunkyPlusIcon(), onPressed: showQuickAddMenu),
        IconButton(tooltip: 'Library options', icon: const Icon(Icons.more_vert_rounded, size: 29),
          onPressed: showLibraryOptionsPane),
      ]),
      body: SafeArea(bottom: false, child: Column(children: [
        // No colored stripe: clean mustard header against cream library.
        ColoredBox(color: GoogleLetterPalette.cream,
          child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SizedBox(height: 46, child: TextField(
          style: const TextStyle(fontSize: 14, color: GoogleLetterPalette.ink,
            fontWeight: FontWeight.w700),
          textAlignVertical: TextAlignVertical.center,
          controller: searchController,
          onChanged: (value) { setState(() => query = value); syncQueue(); },
          decoration: InputDecoration(hintText: 'Search',
            hintStyle: const TextStyle(color: GoogleLetterPalette.creamText),
            prefixIcon: const Icon(Icons.search_rounded, color: GoogleLetterPalette.ink),
            border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(80)), borderSide: BorderSide.none),
            isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 32),
            suffixIcon: query.isNotEmpty ? IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded),
              onPressed: () { searchController.clear(); setState(() => query = ''); syncQueue(); }) : null),
        )))),
        Expanded(child: Material(color: GoogleLetterPalette.cream,
          child: libraryPlaylistsPage
            ? ListView(key: const ValueKey('playlist-directory'), children: [
          ListTile(leading: const Icon(Icons.add_circle_rounded),
            title: const Text('Create a playlist'), onTap: createPlaylist),
          for (final name in playlists.keys)
            ListTile(leading: const Icon(Icons.queue_music_rounded), title: Text(name),
              subtitle: Text('${playlists[name]?.length ?? 0} songs'),
              trailing: IconButton(icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => playlistMenu(name)),
              onTap: () => setState(() {
                libraryPlaylistsPage = false; activePlaylist = name;
                favoritesOnly = false; query = ''; searchController.clear();
              })),
        ]) : Theme(data: Theme.of(context).copyWith(
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(
            seedColor: GoogleLetterPalette.red, brightness: Brightness.light),
          textTheme: Theme.of(context).textTheme.apply(
            bodyColor: GoogleLetterPalette.creamText,
            displayColor: GoogleLetterPalette.creamText),
        ), child: Column(key: const ValueKey('song-directory'), children: [
        // Compact library navigation: one menu instead of stacked chip rows.
        SizedBox(height: 42, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
          PopupMenuButton<String>(
            tooltip: 'Choose music view',
            onSelected: (value) {
              setState(() {
                if (value == 'all') { activePlaylist = null; favoritesOnly = false; }
                else if (value == 'favorites') { activePlaylist = null; favoritesOnly = true; }
                else { activePlaylist = value; favoritesOnly = false; }
              });
              syncQueue();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'all', child: Text('All songs')),
              const PopupMenuItem(value: 'favorites', child: Text('Favorites')),
              for (final name in playlists.keys) PopupMenuItem(value: name, child: Text(name)),
            ],
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(activePlaylist ?? (favoritesOnly ? 'Favorites' : 'All songs'),
                  style: const TextStyle(fontWeight: FontWeight.w800,
                    color: GoogleLetterPalette.creamText, fontSize: 14)),
                const SizedBox(width: 3), const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: GoogleLetterPalette.creamText),
              ])),
          ),
          if (activePlaylist != null) IconButton(tooltip: 'Playlist options',
            visualDensity: VisualDensity.compact, icon: const Icon(Icons.more_horiz, size: 18),
            onPressed: () => playlistMenu(activePlaylist!)),
          const Spacer(),
          Text('${matches.length} songs', style: const TextStyle(
            color: GoogleLetterPalette.creamText, fontSize: 12)),
          PopupMenuButton<String>(
            tooltip: 'Sort tracks',
            constraints: const BoxConstraints(minWidth: 190),
            icon: const Icon(Icons.sort, size: 20, color: GoogleLetterPalette.creamText),
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
        ]))),
        if (files.isNotEmpty && matches.isEmpty)
          Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.filter_alt_off, size: 44),
            const SizedBox(height: 12),
            const Text('No songs match this view'),
            TextButton(onPressed: () {
              searchController.clear();
              setState(() { query = ''; favoritesOnly = false; activePlaylist = null; });
              syncQueue();
            }, child: const Text('Show all songs')),
          ])))
        else Expanded(child: files.isEmpty
          ? Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(onPressed: importInPlace, icon: const Icon(Icons.add_rounded),
                  label: const Text('Link music from Files (no copies)')),
                TextButton(onPressed: import, child: const Text('Copy music into app instead')),
                const SizedBox(height: 14),
                TextButton.icon(onPressed: restoreLibraryBackup,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore saved AuraLocal backup')),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('iOS deletes an app\'s private music when you uninstall it.\n'
                    'Back up to Files before changing your signing or installation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12))),
              ]))
          : ListView.builder(primary: false,
              controller: libraryScroll,
              key: const PageStorageKey<String>('persistent-song-library'),
              cacheExtent: files.length <= 20 ? 12000 : 700,
              physics: const ClampingScrollPhysics(),
              itemCount: matches.length, itemBuilder: (_, row) {
              final index = matches[row];
              final extension = files[index].split('.').last.toUpperCase();
              final previousExtension = row > 0 ? files[matches[row - 1]].split('.').last.toUpperCase() : '';
              final groupStart = sortMode == 'fileType' && extension != previousExtension;
              return Column(mainAxisSize: MainAxisSize.min, children: [
                if (groupStart) Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                  color: GoogleLetterPalette.red, child: Text('$extension files',
                    style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, color: Colors.black))),
                ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -1),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
                shape: const Border(bottom: BorderSide(
                  color: GoogleLetterPalette.creamDivider, width: 0.7)),
                leading: songArtworkThumbnail(files[index]),
                title: Row(children: [
                  if (index == currentIndex) ...[
                    ValueListenableBuilder<List<double>>(valueListenable: waveformLevels,
                      builder: (_, levels, __) => SizedBox(width: 22, height: 26,
                        child: CustomPaint(painter: MiniMusicBarsPainter(
                          levels: levels, active: isPlaying)))),
                    const SizedBox(width: 5),
                  ],
                  Flexible(child: Align(alignment: Alignment.centerLeft,
                  child: Container(padding: const EdgeInsets.fromLTRB(5, 3, 5, 2),
                    decoration: BoxDecoration(
                      color: index == currentIndex
                        ? GoogleLetterPalette.red.withValues(alpha: 0.14)
                        : Colors.transparent,
                      borderRadius: BorderRadius.circular(8)),
                    child: Text(displayName(files[index]), maxLines: 1,
                      softWrap: false, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w700,
                        color: index == currentIndex
                          ? GoogleLetterPalette.red : GoogleLetterPalette.creamText,
                        letterSpacing: -0.5))))),
                ]),
                subtitle: Text([
                  if ((metadataFor(files[index])['artist'] ?? '').trim().isNotEmpty)
                    metadataFor(files[index])['artist']!.trim(),
                  if (index == currentIndex) 'Now playing'
                  else if ((metadataFor(files[index])['artist'] ?? '').trim().isEmpty &&
                      sortMode != 'length') 'Local audio',
                  if (sortMode == 'length' && trackDurations.containsKey(files[index]))
                    clock(trackDurations[files[index]]!),
                ].join('  -  '), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: index == currentIndex
                    ? GoogleLetterPalette.green : GoogleLetterPalette.creamText.withValues(alpha: 0.67))),
                trailing: IconButton(tooltip: 'Song options', color: GoogleLetterPalette.creamText,
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () => trackMenu(files[index])),
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  showTrackDetails(files[index]);
                },
                onTap: () {
                  final selectedPath = files[index];
                  final epoch = ++_selectionEpoch;
                  // Navigate first. Native DSP/metadata awaits must never decide
                  // when the player is presented or replace Library content.
                  if (query.isNotEmpty || favoritesOnly || activePlaylist != null || libraryPlaylistsPage) {
                    setState(() {
                      query = ''; favoritesOnly = false; activePlaylist = null;
                      libraryPlaylistsPage = false;
                    });
                    searchController.clear();
                  }
                  final selectedIndex = files.indexOf(selectedPath);
                  if (selectedIndex < 0) return;
                  setState(() => currentIndex = selectedIndex);
                  showPlayer();
                  () async {
                    if (selectedIndex < 0 || epoch != _selectionEpoch) return;
                    await selectAndPlayTrack(selectedIndex);
                  }();
                },
              ),
              ]);
            })),
        ])))),
        if (currentIndex >= 0 && currentIndex < files.length) IgnorePointer(
          ignoring: !libraryHome && !_playerGestureStarted,
          child: Opacity(opacity: libraryHome || playerMotion.value < 0.15 ? 1.0 : 0.0,
            child: ColoredBox(
          color: GoogleLetterPalette.cream, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => startMiniSwipe(),
          onVerticalDragUpdate: updateMiniSwipe,
          onVerticalDragEnd: finishMiniSwipe,
          onVerticalDragCancel: () {
            _playerGestureStarted = false;
            draggingPlayer = false;
            if (!libraryHome) dismissPlayer();
          },
          child: AnimatedContainer(
            key: miniPlayerPositionKey,
            duration: const Duration(milliseconds: 240),
            margin: EdgeInsets.zero,
            decoration: const BoxDecoration(color: GoogleLetterPalette.blue,
              borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
            child: Padding(padding: EdgeInsets.fromLTRB(12, 0, 12,
              MediaQuery.paddingOf(context).bottom * 0.6), child: ListTile(
            leading: ValueListenableBuilder<List<double>>(
              valueListenable: waveformLevels,
              builder: (_, levels, __) => SizedBox(width: 26, height: 28,
                child: CustomPaint(painter: MiniMusicBarsPainter(
                  levels: levels, active: isPlaying)))),
            title: ScrollingTrackTitle(text: title, style: const TextStyle(
              fontWeight: FontWeight.w800, color: Color(0xFF161515))),
            onTap: showPlayer,
            trailing: IconButton(
              icon: AnimatedSwitcher(duration: const Duration(milliseconds: 180),
                child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: const Color(0xFF161515), key: ValueKey(isPlaying))),
              onPressed: togglePlayback,
            ),
          )),
          ),
        )))),
        if (isLibraryExporting || isLibraryRestoring)
          const LinearProgressIndicator(minHeight: 2),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
      ])),
    );
  }

  Widget buildPlayer({double? expansion}) {
    final stage = expansion ?? (1.0 - playerDrag / _collapsedPlayerOffset())
        .clamp(0.0, 1.0).toDouble();
    // The mini-player itself expands: its mustard surface gradually becomes
    // the cream player rather than a separate cream sheet arriving from below.
    final transition = ((stage - 0.03) / 0.32).clamp(0.0, 1.0).toDouble();
    final surface = Color.lerp(GoogleLetterPalette.blue,
        GoogleLetterPalette.cream, Curves.easeInOut.transform(transition))!;
    final effectivePosition = draggingSeek && scrubPosition != null ? scrubPosition! : positionSeconds;
    final maximum = math.max(durationSeconds, 0.001);
    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: surface,
        toolbarOpacity: ((stage - 0.32) / 0.53).clamp(0.0, 1.0).toDouble(),
        foregroundColor: GoogleLetterPalette.ink,
        leading: IconButton(tooltip: 'Minimize player', icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: showLibrary),
        title: const Text('', maxLines: 1, softWrap: false,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        titleSpacing: 0,
        actions: [
          Opacity(opacity: ((stage - 0.32) / 0.53).clamp(0.0, 1.0).toDouble(),
            child: TextButton(onPressed: showEqualizer,
              child: const Text('EQ', style: TextStyle(color: GoogleLetterPalette.ink,
                fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 0.8)))),
          PopupMenuButton<String>(tooltip: 'More player actions',
            onSelected: (value) {
              if (value == 'queue') showQueue();
              if (value == 'import') importInPlace();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'queue', child: Text('Queue')),
              PopupMenuItem(value: 'import', child: Text('Import from Files')),
            ], icon: const Icon(Icons.more_vert_rounded)),
        ],
      ),
      body: IgnorePointer(ignoring: stage < 0.92,
        child: Opacity(opacity: ((stage - 0.32) / 0.53).clamp(0.0, 1.0).toDouble(),
          child: SafeArea(
        child: LayoutBuilder(builder: (context, viewport) =>
        Stack(children: [ListView(
          key: const PageStorageKey<String>('now-playing-content'),
          primary: false,
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 28),
          children: [
          SizedBox(height: math.max(8.0, viewport.maxHeight * 0.015)),
          SizedBox(height: math.min(viewport.maxHeight * 0.46, 410),
            child: Center(child: LayoutBuilder(builder: (_, bounds) {
            final side = math.max(0.0, math.min(bounds.maxWidth, bounds.maxHeight));
            if (currentIndex < 0 || currentIndex >= files.length) {
              return SizedBox.square(dimension: side, child: const ColoredBox(
                color: GoogleLetterPalette.red, child: Icon(Icons.music_note_rounded, size: 100)));
            }
            final path = files[currentIndex];
            return SizedBox.square(dimension: side, child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              // The artwork's ListView competes with the outer dismiss gesture.
              onVerticalDragStart: startPlayerDrag,
              onVerticalDragUpdate: updatePlayerDrag,
              onVerticalDragEnd: finishPlayerDrag,
              onVerticalDragCancel: cancelPlayerDrag,
              child: ArtworkFlipCard(
                key: ValueKey(path), trackName: displayName(path),
                metadata: metadataFor(path), embeddedArtwork: embeddedArt[path],
                onSave: (data) => saveTrackMetadata(path, data))));
          }))),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: SizedBox(height: 43, child: ScrollingTrackTitle(text: title, style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w900, color: GoogleLetterPalette.ink)))),
            if (currentIndex >= 0 && currentIndex < files.length)
              IconButton(tooltip: 'Technical metadata', icon: const Icon(Icons.info_outline_rounded),
                onPressed: () => showTrackDetails(files[currentIndex])),
            if (currentIndex >= 0 && currentIndex < files.length)
              IconButton(tooltip: 'Favorite',
                onPressed: () => toggleFavorite(files[currentIndex]),
                icon: Icon(favorites.contains(files[currentIndex]) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: GoogleLetterPalette.red)),
          ]),
          if (currentIndex >= 0 && currentIndex < files.length &&
              (metadataFor(files[currentIndex])['artist'] ?? '').trim().isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(metadataFor(files[currentIndex])['artist']!.trim(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700,
                  color: GoogleLetterPalette.creamText, fontSize: 15))),
          GestureDetector(behavior: HitTestBehavior.opaque,
            onTap: showOutputPicker,
            child: AnimatedSwitcher(duration: const Duration(milliseconds: 360),
            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
            child: listeningOutput.isEmpty ? const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('Choose audio output', key: ValueKey('empty-route'),
                style: TextStyle(color: GoogleLetterPalette.ink, fontSize: 12))) :
              Padding(key: ValueKey('$listeningOutput/$listeningCodec/$sourceLossless'),
                padding: const EdgeInsets.only(bottom: 5), child: Text(
                [listeningOutput, if (listeningCodec.isNotEmpty) listeningCodec,
                  if (sourceLossless) 'Lossless source'].join('  •  '),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: GoogleLetterPalette.creamText)))),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: dragOnlySlider(value: effectivePosition.clamp(0.0, maximum).toDouble(),
            min: 0, max: maximum,
            onChanged: (value) => setState(() {
              draggingSeek = true; scrubPosition = value;
            }),
            onChangeEnd: (value) async {
              await seekTo(value);
              if (mounted) setState(() { draggingSeek = false; scrubPosition = null; });
            })),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(clock(effectivePosition), style: TextStyle(color: GoogleLetterPalette.creamText.withValues(alpha: 0.68))),
            Text(clock(durationSeconds), style: TextStyle(color: GoogleLetterPalette.creamText.withValues(alpha: 0.68))),
          ])),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(tooltip: 'Shuffle', color: shuffle ? GoogleLetterPalette.green : GoogleLetterPalette.creamText,
              onPressed: () async {
                setState(() => shuffle = !shuffle);
                await syncQueue(); await saveLibrary();
              }, icon: const ChunkyShuffleIcon()),
            GestureDetector(behavior: HitTestBehavior.opaque,
              onTap: files.isEmpty ? null : () => skipTrack(-1),
              onLongPressStart: currentIndex < 0 ? null : (_) => startTransportHold(-1),
              onLongPressEnd: (_) => stopTransportHold(),
              onLongPressCancel: stopTransportHold,
              child: const SizedBox(width: 52, height: 56,
                child: Center(child: Icon(Icons.skip_previous_rounded, size: 43)))),
            IconButton(onPressed: files.isEmpty ? import : togglePlayback,
              style: IconButton.styleFrom(foregroundColor: GoogleLetterPalette.ink),
              icon: AnimatedSwitcher(duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
                child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(isPlaying), size: 49))),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: files.isEmpty ? null : () => skipTrack(1),
              onLongPressStart: currentIndex < 0 ? null : (_) => startTransportHold(1),
              onLongPressEnd: (_) => stopTransportHold(),
              onLongPressCancel: stopTransportHold,
              child: Semantics(label: 'Next track; hold to scrub forward',
                button: true,
                child: const SizedBox(width: 52, height: 56,
                  child: Center(child: Icon(Icons.skip_next_rounded, size: 43))))),
            Column(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Repeat mode', color: repeat == 0 ? GoogleLetterPalette.creamText : GoogleLetterPalette.red,
                onPressed: () async {
                  setState(() => repeat = (repeat + 1) % 3);
                  await syncQueue(); await saveLibrary();
                }, icon: ChunkyRepeatIcon(one: repeat == 2)),
              Text(['OFF', 'ALL', 'ONE'][repeat],
                style: const TextStyle(fontSize: 10, color: GoogleLetterPalette.creamText)),
            ]),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton.icon(onPressed: showLibrary, icon: const Icon(Icons.library_music_rounded),
              label: const Text('Library')),
            TextButton.icon(onPressed: showQueue, icon: const Icon(Icons.queue_music_rounded),
              label: const Text('Queue')),
            if (currentIndex >= 0 && currentIndex < files.length)
              TextButton.icon(icon: const Icon(Icons.playlist_add_rounded, size: 21),
                label: const Text('Playlist'),
                onPressed: () => addToPlaylist(files[currentIndex])),
          ]),
          const SizedBox(height: 4),
          TextButton.icon(onPressed: showAudioSettings, icon: const Icon(Icons.tune_rounded),
            label: const Text('Pitch and tempo')),
          if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 22),
        ],
      ),
      ]))))),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The full-screen player must never be translated beyond the viewport.
    // Keep exactly one visible page, so a cancelled drag cannot leave a grey
    // full-screen overlay blocking the music library.
    return ColoredBox(color: GoogleLetterPalette.cream, child: Stack(children: [
      // Keep Library text and rows live beneath the animated player layer.
      // A retained raster layer can show dividers but lose glyphs on iOS.
      buildLibrary(),
      if (!libraryHome && playerMotion.value > 0.001)
        Builder(builder: (context) {
          final progress = playerMotion.value.clamp(0.0, 1.0).toDouble();
          final top = (1.0 - progress) * _collapsedPlayerOffset();
          final blur = ((progress - 0.20) / 0.80).clamp(0.0, 1.0).toDouble();
          // The sheet is positioned at its *visible* top, not translated
          // inside a full-screen hit-test box. Everything above the sheet
          // remains fully interactive in the Library.
          return Stack(children: [
            // Avoid filtering the live song list into an offscreen backdrop
            // layer while the player animates. iOS may retain that layer after
            // collapse, hiding text and artwork while dividers remain.
            Positioned.fill(child: IgnorePointer(child: ColoredBox(
              color: GoogleLetterPalette.cream.withValues(alpha: blur * 0.12)))),
            Positioned(top: top, left: 0, right: 0,
              child: SizedBox(height: MediaQuery.sizeOf(context).height,
                child: ClipRRect(borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20)), child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: startPlayerDrag,
                onVerticalDragUpdate: updatePlayerDrag,
                onVerticalDragEnd: finishPlayerDrag,
                onVerticalDragCancel: cancelPlayerDrag,
                child: buildPlayer(expansion: progress),
              )))),
          ]);
        }),
    ]));
  }
}

/// Rounded heavy strokes avoid the sharp hairline glyphs on a compact screen.
class ChunkyShuffleIcon extends StatelessWidget {
  const ChunkyShuffleIcon({super.key});
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(29, 29),
    painter: _ChunkyTransportPainter(
      color: IconTheme.of(context).color ?? GoogleLetterPalette.ink,
      kind: 0));
}

class ChunkyRepeatIcon extends StatelessWidget {
  final bool one;
  const ChunkyRepeatIcon({super.key, required this.one});
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(29, 29),
    painter: _ChunkyTransportPainter(
      color: IconTheme.of(context).color ?? GoogleLetterPalette.ink,
      kind: one ? 2 : 1));
}

class _ChunkyTransportPainter extends CustomPainter {
  final Color color;
  final int kind;
  const _ChunkyTransportPainter({required this.color, required this.kind});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 29, size.height / 29);
    final paint = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeWidth = 3.6..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (kind == 0) {
      final path = Path()
        ..moveTo(3.5, 7.5)..lineTo(7, 7.5)
        ..quadraticBezierTo(12, 7.5, 15, 14.5)
        ..quadraticBezierTo(19, 22, 22.5, 22)
        ..lineTo(25.5, 22)
        ..moveTo(22, 18.3)..lineTo(25.5, 22)..lineTo(22, 25.7)
        ..moveTo(3.5, 22)..lineTo(7, 22)
        ..quadraticBezierTo(12, 22, 15, 14.5)
        ..quadraticBezierTo(19, 7.5, 22.5, 7.5)
        ..lineTo(25.5, 7.5)
        ..moveTo(22, 3.8)..lineTo(25.5, 7.5)..lineTo(22, 11.2);
      canvas.drawPath(path, paint);
    } else {
      final loop = Path()
        ..moveTo(6, 10)..lineTo(6, 9)
        ..quadraticBezierTo(6, 5.5, 10, 5.5)
        ..lineTo(21, 5.5)
        ..quadraticBezierTo(24.5, 5.5, 24.5, 9)
        ..lineTo(24.5, 14)
        ..moveTo(20.7, 10.5)..lineTo(24.5, 14)..lineTo(27, 10.5)
        ..moveTo(23, 19)..lineTo(23, 20)
        ..quadraticBezierTo(23, 24.2, 19.2, 24.2)
        ..lineTo(8, 24.2)
        ..quadraticBezierTo(4.5, 24.2, 4.5, 20.7)
        ..lineTo(4.5, 15)
        ..moveTo(1.5, 18.5)..lineTo(4.5, 15)..lineTo(8, 18.5);
      canvas.drawPath(loop, paint);
      if (kind == 2) {
        final textPainter = TextPainter(
          text: TextSpan(text: '1', style: TextStyle(color: color,
            fontSize: 14, fontWeight: FontWeight.w900)),
          textDirection: TextDirection.ltr)..layout();
        textPainter.paint(canvas, Offset(14.5 - textPainter.width / 2,
          14.8 - textPainter.height / 2));
      }
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _ChunkyTransportPainter old) =>
    old.color != color || old.kind != kind;
}

/// A compact actual tuning fork, drawn rather than substituting a music note.
class _TuningForkIcon extends StatelessWidget {
  const _TuningForkIcon();
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: 34,
    child: CustomPaint(painter: _TuningForkPainter(
      Theme.of(context).colorScheme.onSurface)));
}

class _TuningForkPainter extends CustomPainter {
  final Color color;
  const _TuningForkPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    final x = size.width / 2;
    final fork = Path()
      ..moveTo(x - 8, 3)..lineTo(x - 8, 15)
      ..quadraticBezierTo(x - 8, 23, x, 23)
      ..quadraticBezierTo(x + 8, 23, x + 8, 15)
      ..lineTo(x + 8, 3);
    canvas.drawPath(fork, paint);
    canvas.drawLine(Offset(x, 23), Offset(x, 31), paint);
  }
  @override
  bool shouldRepaint(covariant _TuningForkPainter old) => old.color != color;
}

/// A single repeating row of red / blue / green / yellow tiles.
class _ColorTileBorder extends CustomPainter {
  const _ColorTileBorder();
  @override
  void paint(Canvas canvas, Size size) {
    const colors = [GoogleLetterPalette.red, GoogleLetterPalette.yellow,
      GoogleLetterPalette.green, GoogleLetterPalette.blue];
    const tileWidth = 12.0;
    for (var x = 0.0, i = 0; x < size.width; x += tileWidth, i++) {
      canvas.drawRect(Rect.fromLTWH(x, 0, tileWidth, size.height),
        Paint()..color = colors[i % colors.length]);
    }
  }
  @override
  bool shouldRepaint(covariant _ColorTileBorder old) => false;
}

/// Deliberately thicker than Material's regular plus glyph, no enclosing ring.
class ChunkyPlusIcon extends StatelessWidget {
  const ChunkyPlusIcon({super.key});
  @override
  Widget build(BuildContext context) => SizedBox(width: 30, height: 30,
    child: CustomPaint(painter: _ChunkyPlusPainter(
      Theme.of(context).appBarTheme.foregroundColor ?? const Color(0xFF221A1B))));
}

class _ChunkyPlusPainter extends CustomPainter {
  final Color color;
  const _ChunkyPlusPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: size.width * 0.88, height: 7),
      const Radius.circular(2)), paint);
    canvas.drawRRect(RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: 7, height: size.height * 0.88),
      const Radius.circular(2)), paint);
  }
  @override
  bool shouldRepaint(covariant _ChunkyPlusPainter old) => old.color != color;
}

/// Single live horizontal EQ-frequency contour, driven by actual PCM analysis.
class MiniMusicBarsPainter extends CustomPainter {
  final List<double> levels;
  final bool active;
  const MiniMusicBarsPainter({required this.levels, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = GoogleLetterPalette.red
      ..strokeWidth = 3.5..strokeCap = StrokeCap.round;
    for (var i = 0; i < 4; i++) {
      final start = i * 11;
      var strength = 0.0;
      for (var k = start; k < math.min(start + 11, levels.length); k++) {
        strength = math.max(strength, levels[k]);
      }
      strength = strength.clamp(0.0, 1.0).toDouble();
      final height = active ? 5 + strength * (size.height - 6) : 4.0;
      final x = size.width * (i + 0.5) / 4;
      canvas.drawLine(Offset(x, size.height - height),
        Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant MiniMusicBarsPainter old) =>
      old.active != active || old.levels != levels;
}

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
    final span = size.height * 0.47;
    // Each X coordinate maps to a real spectral band, bass on the left and
    // treble on the right. Varying values, not a repeated sine wave, determine
    // the contour; no decorative oscillation is injected into silent audio.
    final points = <Offset>[
      for (var i = 0; i < samples.length; i++)
        Offset(size.width * i / (samples.length - 1),
          baseline - math.pow(samples[i].clamp(0.0, 1.0), 0.75).toDouble() * span),
    ];
    final curve = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset((points[i].dx + points[i + 1].dx) / 2,
          (points[i].dy + points[i + 1].dy) / 2);
      curve.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    curve.lineTo(points.last.dx, points.last.dy);
    final paint = Paint()
      ..color = isPlaying ? GoogleLetterPalette.blue : GoogleLetterPalette.red
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

class EditableEqCurvePainter extends CustomPainter {
  final List<double> gains;
  final Color accent;
  const EditableEqCurvePainter({required this.gains, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = GoogleLetterPalette.creamDivider..strokeWidth = 1;
    for (final db in [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      final y = (12 - db) / 24 * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      final text = TextPainter(text: TextSpan(text: '${db.toInt() > 0 ? '+' : ''}${db.toInt()} dB',
        style: const TextStyle(fontSize: 10, color: GoogleLetterPalette.creamText)),
        textDirection: TextDirection.ltr)..layout();
      text.paint(canvas, Offset(3, math.max(0, y - 13)));
    }
    for (var i = 0; i < gains.length; i++) {
      final x = size.width * (i + 0.5) / gains.length;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
        Paint()..color = GoogleLetterPalette.creamDivider..strokeWidth = 1);
    }
    final path = Path();
    for (var i = 0; i < gains.length; i++) {
      final pos = Offset(size.width * (i + 0.5) / gains.length,
          (12 - gains[i]) / 24 * size.height);
      if (i == 0) { path.moveTo(pos.dx, pos.dy); }
      else { path.lineTo(pos.dx, pos.dy); }
      canvas.drawCircle(pos, 9, Paint()..color = GoogleLetterPalette.yellow);
      canvas.drawCircle(pos, 3, Paint()..color = GoogleLetterPalette.cream);
    }
    canvas.drawPath(path, Paint()..color = accent..strokeWidth = 3
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(covariant EditableEqCurvePainter old) =>
      old.accent != accent ||
      old.gains.length != gains.length ||
      List.generate(gains.length, (i) => i).any((i) => old.gains[i] != gains[i]);
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
