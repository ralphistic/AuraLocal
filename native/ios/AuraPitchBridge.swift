import Flutter
import UIKit

final class AuraPitchBridge {
    private let graph = AuraDspGraph()
    private let channel: FlutterMethodChannel
    private var playingNative = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "auralocal/native_dsp", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(FlutterError(code: "UNAVAILABLE", message: "Bridge released", details: nil)); return }
            do {
                switch call.method {
                case "playFile":
                    guard let args = call.arguments as? [String: Any],
                          let path = args["path"] as? String else {
                        result(FlutterError(code: "ARGUMENT", message: "Missing file path", details: nil)); return
                    }
                    let position = (args["position"] as? NSNumber)?.doubleValue ?? 0
                    try self.graph.playFile(at: path, positionSeconds: position)
                    self.playingNative = true
                    result(true)
                case "stopFile":
                    self.graph.stopPlayback()
                    self.playingNative = false
                    result(true)
                case "pauseFile":
                    self.graph.pausePlayback()
                    result(true)
                case "resumeFile":
                    self.graph.resumePlayback()
                    result(true)
                case "seekFile":
                    let seconds = (call.arguments as? [String: Any])?["position"] as? NSNumber
                    guard let seconds else { result(FlutterError(code: "ARGUMENT", message: "Missing position", details: nil)); return }
                    try self.graph.seekPlayback(to: seconds.doubleValue)
                    result(true)
                case "getPosition":
                    result(self.graph.positionSeconds)
                case "setTimePitch":
                    guard let args = call.arguments as? [String: Any],
                          let tempo = (args["tempo"] as? NSNumber)?.floatValue,
                          let cents = (args["cents"] as? NSNumber)?.floatValue else {
                        result(FlutterError(code: "ARGUMENT", message: "Missing tempo or cents", details: nil)); return
                    }
                    try self.graph.setTimePitch(tempo: tempo, semitones: cents / 100)
                    result(self.playingNative)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                result(FlutterError(code: "NATIVE_AUDIO", message: error.localizedDescription, details: nil))
            }
        }
    }
}
