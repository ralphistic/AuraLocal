from pathlib import Path

dart = Path("lib/main.dart").read_text()
bridge = Path("native/ios/AuraPitchBridge.swift").read_text()
graph = Path("native/ios/AuraDspGraph.swift").read_text()
workflow = Path(".github/workflows/ios.yml").read_text()

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
        "TweenAnimationBuilder<double>(" in dart and
        "Transform.translate(offset: Offset(0, actualOffset)" in dart and
        "buildPlayer(expansion: progress)" in dart and "if (!libraryHome)" in dart,
        "The actual mini-player surface expands and collapses with finger-tracked motion")
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
        "TweenAnimationBuilder<double>" in dart and "if (!libraryHome)" in dart,
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
require("libraryRenderEpoch++" in dart and
        "cacheExtent: files.length <= 20" in dart,
        "Song list remounts after player dismissal and caches small libraries")
require("ui.ImageFilter.blur(sigmaX: strength * 7" in dart and
        "TweenAnimationBuilder<double>" in dart,
        "Backdrop blur grows smoothly with player expansion")

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
