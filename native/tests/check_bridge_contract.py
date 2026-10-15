from pathlib import Path

dart = Path("lib/main.dart").read_text()
bridge = Path("native/ios/AuraPitchBridge.swift").read_text()
graph = Path("native/ios/AuraDspGraph.swift").read_text()
workflow = Path(".github/workflows/ios.yml").read_text()
surfaces = Path("lib/blurred_surfaces.dart").read_text()
metadata = Path("lib/metadata_art.dart").read_text()

def require(ok, message):
    if not ok:
        raise SystemExit("FAIL: " + message)
    print("PASS: " + message)

require("MethodChannel('auralocal/native_dsp')" in dart and
        'name: "auralocal/native_dsp"' in bridge,
        "Flutter and iOS method-channel names match")
require("just_audio" not in dart and "AudioPlayer(" not in dart and
        "nativePitchPreview" not in dart and "nativePitchPreview" not in bridge,
        "Single native playback engine; no secondary player or preview route")
for method in ("playIndex", "setQueue", "getState", "pauseFile", "resumeFile",
               "seekFile", "skipFile", "setTimePitch", "setWaveformEnabled"):
    require((f"invokeMethod('{method}'" in dart or
             f"invokeMethod<int>('{method}'" in dart or
             f"invokeMethod<bool>('{method}'" in dart or
             f"invokeMapMethod<String, dynamic>('{method}'" in dart) and
            f'case "{method}"' in bridge,
            f"{method} is implemented at both ends")
require("DropdownButton<double>" not in dart and "Playing from Your Library" not in dart,
        "Obsolete speed dropdown and redundant label removed")
require("LiveWaveformPainter" in dart and "installTap(onBus:" in graph and
        "waveform()" in graph,
        "Live waveform samples come from native audio output")
require("return ColoredBox(color: GoogleLetterPalette.cream, child: Stack(children: [" in dart and
        "AnimationController(vsync: this" in dart and
        "Positioned(top: top, left: 0, right: 0," in dart and
        "buildPlayer(expansion: progress)" in dart and "if (!libraryHome)" in dart,
        "Player follows thumb via a single explicitly controlled animation")
require("source.scheduleSegment(file" in graph and "source.play()" in graph and
        "engine.connect(equalizer, to: timePitch" in graph,
        "FLAC runs through the existing Apple TimePitch graph")
require("swiftc native/ios/AuraDspGraph.swift" in workflow and
        "/tmp/auralocal-production-graph /tmp/auralocal-tone.flac" in workflow,
        "Production graph audio test gates release")
require("needsInterruptionReprime" in graph and "interruptedByAnotherApp()" in bridge and
        "try playFile(at: path, positionSeconds: savedPosition)" in graph,
        "Interruption recovery reprimes the paused track rather than silently playing a lost schedule")
print("PASS: unified native transport contract")

require("AVAudioSession.sharedInstance()" in graph and "try session.setActive(true)" in graph and
        "func resumePlayback() throws" in graph and "try self.graph.resumePlayback()" in bridge,
        "Interrupted iOS session is reactivated and engine restarted before resume")
require("ProcessInfo.processInfo.systemUptime" in graph and
        "elapsed * Double(timePitch.rate)" in graph,
        "Timeline follows wall-clock media time and respects tempo")
require("Goertzel" in graph and "analysisQueue" in graph and "spectrumTicker" in dart and
        "Duration(milliseconds: 16)" in dart,
        "Live equalizer-style frequency analyzer with display-vsync smoothing")
require(dart.count("Slider(value: pitchCents") == 0 and
        "_audioControlRow(icon: Icons.music_note_rounded" in dart and
        "onDoubleTap: onReset" in dart,
        "Pitch slider supports drag and double-tap reset")

require("timePitch.overlap = 8" in graph and
        "timePitch.rate = tempo" in graph and "timePitch.pitch = cents + tapeCents" in graph and
        "timePitch.reset()" not in graph and
        "source.stop()" not in graph.split("func setTimePitch(")[1],
        "Pitch and tempo update in-place without stopping or resetting the audio graph")
require("orderedTrackIndices()" in dart and "queuedPaths = libraryOrder" in dart and
        "manualQueueActive" in dart and "ReorderableListView.builder" in dart and
        "return (proposed % queue.count + queue.count) % queue.count" in bridge,
        "Sorted library order and persistent editable queue coexist with shuffle")
require("songDSP" in dart and "globalDSP" in dart and "loadSongDSP" in dart,
        "Per-song pitch and tempo persist with optional global mode")
require("DropdownButtonFormField<String>" in dart and "onDoubleTapDown" in dart,
        "EQ preset dropdown and double-tap reset controls are available")
require("isSameAudio" in dart and "originalNames" in dart and
        "if (duplicate) continue;" in dart,
        "Repeated audio imports preserve original track labels")
require("Widget dragOnlySlider(" in dart and "onHorizontalDragUpdate" in dart and
        "onDoubleTap: onReset" in dart and "showThreePrecisionWheels(refresh)" in dart,
        "Pitch slider supports drag-only adjustments, double-tap reset and precision wheel")
require("startMiniSwipe()" in dart and "finishMiniSwipe" in dart and
        "child: Stack(children: [" in dart and "_collapsedPlayerOffset()" in dart and
        "AnimationController(vsync: this" in dart and "if (!libraryHome)" in dart,
        "Swipe-up opens the same yellow player and returns to its mini-player position")
require("curve.quadraticBezierTo" in dart and "canvas.drawPath(curve, paint)" in dart,
        "Live EQ is rendered as a single responsive frequency contour")

# Visual-only feature contract for Google-logo-color iteration.
require("onReset: () => seekTo(0)" not in dart and
        "min: 0, max: maximum," in dart,
        "Playback timeline deliberately ignores double-taps")
require("sortMode == 'length' && trackDurations.containsKey" in dart,
        "Song durations appear in the library only for Track length sorting")
require("songArtworkThumbnail(files[index])" in dart and
        "class MiniMusicBarsPainter" in dart and
        "Offset(x, size.height - height)" in dart,
        "Tracklist artwork thumbnails and upward-only playing spectrum bars")
require("key: const PageStorageKey<String>('persistent-song-library')" in dart and
        "cacheExtent: files.length <= 20" in dart and
        "libraryRenderEpoch++" not in dart,
        "Song list keeps stable scroll identity on minimize and caches small libraries")
require("final blur = ((progress - 0.20) / 0.80)" in dart and
        "color: GoogleLetterPalette.cream.withValues(alpha: blur * 0.12)" in dart and
        "Positioned.fill(child: IgnorePointer(child: BackdropFilter(" not in dart,
        "Player transition avoids iOS backdrop-filter compositing over live library")

require("class _ColorTileBorder extends CustomPainter" in dart and
        "GoogleLetterPalette.cream" in dart,
        "Single-row repeating Google-color tile divider and cream background available")
require("Icons.link_off_rounded" in dart and "Icons.link_rounded" in dart and
        "Future<void> showThreePrecisionWheels" in dart,
        "Pitch and tempo link state preserved with three-wheel precision controls")
require("seekSeconds(-10)" not in dart and "seekSeconds(10)" not in dart,
        "All double-tap jump-forward and jump-back seek gestures removed")

require("const _TuningForkIcon()" in dart and
        "class _TuningForkPainter extends CustomPainter" in dart,
        "Precision control displays a true tuning fork shape")
require("if (!linkedPitchTempo)" in dart and
        "name: linkedPitchTempo ? 'Tapespeed' : 'Tempo'" in dart,
        "Linked pitch/tempo collapses Pitch and renames the remaining slider Tapespeed")
require("Text('Cents')" in dart and "Text('Semitones')" in dart and
        "if (!linkedPitchTempo) const Expanded(child: Center(child: Text('Cents')))" in dart and
        "Text(linkedPitchTempo ? 'Tapespeed' : 'Tempo')" in dart,
        "Precision tuning shows four wheels unlinked or Tapespeed and Preamp linked")
require("child: Text(displayName(files[index]), maxLines: 1" in dart,
        "Every track-list song title remains on exactly one line")

require("enableDrag: false, // EQ pan gestures" in dart and
        "onPanDown: (details)" in dart and
        "icon: const Icon(Icons.close_rounded, color: GoogleLetterPalette.ink)" in dart,
        "EQ sheet cannot steal vertical band drags and has an explicit close button")
require("child: Text('EQ preset'" in dart and
        "fillColor: GoogleLetterPalette.creamDivider.withValues(alpha: 0.40)" in dart,
        "EQ preset field has a separate label and a neutral high-contrast background")
require("external || await File(mapped).exists()" in dart and
        "files.remove(manifestTrackKey(path))" in dart,
        "Files bookmarks remain listed through temporary provider unavailability")
require("_settingsSection('Music import'" in dart and
        "BorderRadius.circular(29)" in dart,
        "Library options open in a rounded settings window retaining import/backup actions")
require("onVerticalDragEnd: finishPlayerDrag" in dart and
        "Color.lerp(GoogleLetterPalette.blue" in dart,
        "Album art supports down-swipe and expanding player morphs mustard to cream")

require("onPressed: showQuickAddMenu" in dart and
        "void showQuickAddMenu()" in dart and
        all(label in dart for label in ["Link a song from Files", "Import a song as a copy", "Create a playlist"]),
        "Chunky plus opens a dedicated music import and playlist action sheet")
require("showBlurredActionSheet((sheet)" in dart and
        "showAuraSheet<void>" in dart and
        "sigmaX: 7 * animation.value" in surfaces,
        "Track action and quick-add windows use shared animated backdrop blur")
require("name: linkedPitchTempo ? 'Tapespeed' : 'Tempo'" in dart and
        "Column(mainAxisSize: MainAxisSize.min" in dart and
        "Text('Fine tuning'" in dart and "Text('Reset pitch & tempo'" in dart,
        "Linked tempo layout self-sizes; fine tuning and reset are distinct actions")

require("void showOutputPicker()" in dart and
        "UiKitView(viewType: 'auralocal/output-picker')" in dart and
        "AVRoutePickerView" in bridge and
        "registrar.register(OutputPickerFactory()" in bridge,
        "Player routes audio through the genuine iOS output picker")
require("hintText: 'Search'" in dart and
        "Color(0xFFFFFAEF)" in dart and
        "EdgeInsets.fromLTRB(16, 8, 16, 0)" in dart,
        "Search field matches the library surface with no lower gap")
require("Key('aura-sheet-grab-zone')" in surfaces and
        "onVerticalDragUpdate: (details)" in surfaces and
        "distance > 110" in surfaces,
        "All bottom sheets follow the finger via a full-width drag zone")
require("Color.lerp(GoogleLetterPalette.blue" in dart and
        "((stage - 0.03) / 0.32)" in dart and
        "((stage - 0.32) / 0.53)" in dart,
        "Warm yellow becomes cream early and artwork and EQ text fade together")

require("onVerticalDragStart: (_) => startMiniSwipe()" in dart and
        "ignoring: !libraryHome && !_playerGestureStarted" in dart and
        "opacity: libraryHome || playerMotion.value < 0.15 ? 1.0 : 0.0" in dart and
        "if (currentIndex >= 0 && currentIndex < files.length) IgnorePointer(" in dart,
        "MiniPlayer recognizer remains mounted throughout opening swipe")
require("math.exp(-dt / responseTime)" in dart and
        "lastSpectrumTick = elapsed" in dart,
        "Waveform smoothing uses vsync timestamps instead of fixed per-frame steps")
require("showAuraSheet<" in metadata and
        "showAuraDialog<" in dart and
        "showModalBottomSheet<" not in dart and
        "showModalBottomSheet<" not in metadata,
        "Metadata, queue, playlist, technical details, pitch and EQ all use blurred surfaces")
require("onTap: showOutputPicker" in dart and
        "'Output: $listeningOutput'" not in dart,
        "Existing audio route codec information is the sole output picker trigger")
require("test/blurred_surfaces_test.dart" in workflow,
        "Finger tracking and backdrop blur are covered by Flutter widget tests")

require("playerMotion.addStatusListener" in dart and
        "AnimationStatus.dismissed" in dart and
        "Future.delayed(const Duration(milliseconds: 355)" not in dart and
        "onVerticalDragEnd: finishPlayerDrag" in dart,
        "Player collapse is completed by controller status, not independent timer")

require("child: Material(color: widget.color" in surfaces,
        "ListTiles render ink on their nearest Material inside blurred sheets")

require("final ScrollController libraryScroll = ScrollController();" in dart and
        "controller: libraryScroll" in dart and
        "RepaintBoundary(child: buildLibrary())" not in dart and
        "if (libraryHome || playerMotion.value < 0.99) buildLibrary()," in dart and
        "IgnorePointer(ignoring: !libraryHome," not in dart,
        "Library scroll position is preserved, clamped, and cannot intercept player touches")
require("BorderRadius.circular(26)" in surfaces and
        "BorderRadius.vertical(" not in surfaces,
        "Floating action panels round all four corners")
require("Center(child: builder(page))" in surfaces and
        "Do not apply viewInsets again" in surfaces,
        "Playlist dialog does not apply a duplicate keyboard inset")
require("if repeatMode == 2 && currentIndex >= 0" in bridge and
        "if repeatMode == 2 && delta > 0 { return currentIndex }" not in bridge,
        "Repeat-one only applies to natural track completion, not manual skip")

require("RepaintBoundary(child: buildLibrary())" not in dart and
        "if (progress < 0.5)" not in dart and
        "child: const SizedBox.expand()" in dart,
        "Library remains live under player and duplicated mini-preview stays removed")
require("SizedBox(height: 42, child: Padding(" in dart and
        "EdgeInsets.fromLTRB(16, 8, 16, 0)" in dart,
        "Fixed-height search navigation eliminates uneven lower gap")
require("child: GestureDetector(" in dart and
        "onVerticalDragEnd: finishPlayerDrag" in dart,
        "Album art has its own full-width dismiss swipe recognizer")

require("playerMotion.value < 0.15" in dart and
        "Positioned(top: top, left: 0, right: 0," in dart and
        "miniPlayerPositionKey" in dart,
        "Player uses one motion progress and measured footer anchor")

require("final selectedPath = files[index];" in dart and
        "setState(() => currentIndex = selectedIndex);" in dart and
        "showPlayer();" in dart and
        "await selectAndPlayTrack(selectedIndex);" in dart,
        "Selecting last song opens player before asynchronous audio initialization")
require("onVerticalDragStart: startPlayerDrag" in dart and
        "onVerticalDragUpdate: updatePlayerDrag" in dart and
        "AnimationController(vsync: this" in dart,
        "Artwork and player use a single drag owner and frame-driven controller")

require("Positioned(top: top, left: 0, right: 0," in dart and
        "if (!libraryHome && playerMotion.value > 0.02)" in dart and
        "IgnorePointer(ignoring: !libraryHome," not in dart,
        "Fullscreen sheet hit area never blocks Library controls outside visible sheet")
require("ignoring: !libraryHome && !_playerGestureStarted" in dart,
        "MiniPlayer recognizer remains active throughout upward drag")

require("void _completePlayerCollapse()" in dart and
        "if (playerMotion.value <= 0.001)" in dart and
        "_completePlayerCollapse();" in dart and
        "playerMotion.animateTo(0" in dart,
        "Collapsed player explicitly restores MiniPlayer even if already at zero")
require("Positioned(top: top, left: 0, right: 0," in dart and
        "SizedBox(height: MediaQuery.sizeOf(context).height" in dart and
        "Positioned(top: top, left: 0, right: 0, bottom: 0" not in dart,
        "Animated player retains full viewport height; slivers do not compress")
