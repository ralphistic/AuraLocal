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
for method in ("playFile", "stopFile", "setTimePitch"):
    require(f"invokeMethod('{method}'" in dart and f'case "{method}"' in bridge,
            f"{method} is implemented at both ends")
require("await player.pause();" in dart and
        "invokeMethod<bool>('playFile'" in dart and
        "if (started != true) throw PlatformException" in dart,
        "handoff pauses normal player and requires native confirmation")
require("source.scheduleSegment(file" in graph and "source.play()" in graph and
        "engine.connect(equalizer, to: timePitch" in graph,
        "FLAC audio is scheduled through native pitch node")
require("swiftc native/ios/AuraDspGraph.swift" in workflow and
        "/tmp/auralocal-production-graph /tmp/auralocal-tone.flac" in workflow,
        "production graph audio test gates release")
print("PASS: static Flutter/native playback contract")
