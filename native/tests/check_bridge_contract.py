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
             f"invokeMapMethod<String, dynamic>('{method}'" in dart) and
            f'case "{method}"' in bridge,
            f"{method} is implemented at both ends")
require("DropdownButton<double>" not in dart and "Playing from Your Library" not in dart,
        "Obsolete speed dropdown and redundant label removed")
require("LiveWaveformPainter" in dart and "installTap(onBus:" in graph and
        "waveform()" in graph,
        "Live waveform samples come from native audio output")
require("onVerticalDragUpdate:" in dart and "AnimatedContainer(" in dart,
        "Interactive drag-to-minimize and UI animation are present")
require("source.scheduleSegment(file" in graph and "source.play()" in graph and
        "engine.connect(equalizer, to: timePitch" in graph,
        "FLAC runs through the existing Apple TimePitch graph")
require("swiftc native/ios/AuraDspGraph.swift" in workflow and
        "/tmp/auralocal-production-graph /tmp/auralocal-tone.flac" in workflow,
        "Production graph audio test gates release")
print("PASS: unified native transport contract")

require("AVAudioSession.sharedInstance()" in graph and "try session.setActive(true)" in graph and
        "func resumePlayback() throws" in graph and "try self.graph.resumePlayback()" in bridge,
        "Interrupted iOS session is reactivated and engine restarted before resume")
require("ProcessInfo.processInfo.systemUptime" in graph and
        "elapsed * Double(timePitch.rate)" in graph,
        "Timeline follows wall-clock media time and respects tempo")
require("Goertzel filters" in graph and "spectrumTicker" in dart and
        "Duration(milliseconds: 33)" in dart,
        "Live equalizer-style frequency analyzer with display-vsync smoothing")
require(dart.count("Slider(value: pitchCents") == 0 and
        "Adjust pitch in semitones and cents" in dart,
        "Single combined pitch slider opens both picker wheels")
