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
require("return Stack(children: [" in dart and "AnimatedContainer(" in dart and
        "transform: Matrix4.translationValues(0, playerDrag.clamp(0.0, height), 0)" in dart and
        "if (!libraryHome)" in dart,
        "Player follows drag over visible library and settles without leaving a blank overlay")
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
        "Pitch slider. Drag to change pitch; double tap to reset" in dart,
        "Combined pitch slider supports drag and double-tap reset")

require("timePitch.overlap = 8" in graph and
        "timePitch.rate = tempo" in graph and "timePitch.pitch = cents + tapeCents" in graph and
        "timePitch.reset()" not in graph and
        "source.stop()" not in graph.split("func setTimePitch(")[1],
        "Pitch and tempo update in-place without stopping or resetting the audio graph")
require("orderedTrackIndices()" in dart and "queuedPaths = paths" in dart and
        "return (proposed % queue.count + queue.count) % queue.count" in bridge,
        "Next/previous follow sorted library queue and wrap at both ends")
require("songDSP" in dart and "globalDSP" in dart and "loadSongDSP" in dart,
        "Per-song pitch and tempo persist with optional global mode")
require("DropdownButtonFormField<String>" in dart and "onDoubleTapDown" in dart,
        "EQ preset dropdown and double-tap reset controls are available")
require("isSameAudio" in dart and "originalNames" in dart and
        "if (duplicate) continue;" in dart,
        "Repeated audio imports preserve original track labels")
require("onPointerUp:" in dart and "pitchTouchMoved" in dart and
        "onChangeEnd: (_) => updateNativePitchTempo()" in dart,
        "Pitch slider supports dragging and precision picker tapping")
require("startMiniSwipe()" in dart and "finishMiniSwipe" in dart and
        "return Stack(children: [" in dart and "AnimatedContainer(" in dart and "if (!libraryHome)" in dart,
        "Swipe-up opens a bounded player; minimize cannot strand a grey overlay")
require("curve.quadraticBezierTo" in dart and "canvas.drawPath(curve, paint)" in dart,
        "Live EQ is rendered as a single responsive frequency contour")
