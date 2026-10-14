import Flutter
import UIKit
import MediaPlayer
import AVFoundation
import AVKit

/// One transport, one AVAudioEngine and one file player. Flutter never opens audio output.
final class AuraPitchBridge {
    private let graph = AuraDspGraph()
    private let channel: FlutterMethodChannel
    private var queue: [String] = []
    private var currentIndex = -1
    private var repeatMode = 0
    private var shuffle = false
    private var shuffleBag: [Int] = []
    private var displayedTitle: String?
    private var displayedArtist: String?
    private var lastInfoUpdate = Date.distantPast

    #if os(iOS)
    private final class OutputPickerFactory: NSObject, FlutterPlatformViewFactory {
        func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
            FlutterStandardMessageCodec.sharedInstance()
        }
        func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
                    arguments args: Any?) -> FlutterPlatformView {
            OutputPickerView(frame: frame)
        }
    }

    private final class OutputPickerView: NSObject, FlutterPlatformView {
        private let picker: UIView
        init(frame: CGRect) {
            // AVRoutePickerView invokes Apple's standard AirPlay/Bluetooth route
            // sheet. iOS owns which nearby or paired outputs can be selected.
            let route = AVRoutePickerView(frame: frame)
            route.activeTintColor = UIColor(red: 0.34, green: 0.64, blue: 0.36, alpha: 1)
            route.tintColor = UIColor.darkGray
            route.prioritizesVideoDevices = false
            let container = UIView(frame: frame)
            container.backgroundColor = .clear
            route.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(route)
            NSLayoutConstraint.activate([
                route.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                route.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                route.widthAnchor.constraint(equalToConstant: 54),
                route.heightAnchor.constraint(equalToConstant: 54),
            ])
            picker = container
        }
        func view() -> UIView { picker }
    }
    #endif

    init(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar? = nil) {
        channel = FlutterMethodChannel(name: "auralocal/native_dsp", binaryMessenger: messenger)
        #if os(iOS)
        if let registrar = registrar {
            registrar.register(OutputPickerFactory(), withId: "auralocal/output-picker")
        }
        #endif
        graph.onFinished = { [weak self] in self?.handleFinished() }
        registerRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "UNAVAILABLE", message: "Bridge released", details: nil))
                return
            }
            do {
                switch call.method {
                case "setQueue":
                    guard let args = call.arguments as? [String: Any],
                          let paths = args["paths"] as? [String] else {
                        throw self.argumentError("Missing file paths")
                    }
                    let oldPath = self.currentIndex >= 0 && self.currentIndex < self.queue.count
                        ? self.queue[self.currentIndex] : nil
                    if self.queue != paths { self.shuffleBag.removeAll() }
                    self.queue = paths
                    self.repeatMode = (args["repeat"] as? Int ?? self.repeatMode)
                    self.shuffle = (args["shuffle"] as? Bool ?? self.shuffle)
                    if let oldPath = oldPath, let newIndex = paths.firstIndex(of: oldPath) {
                        self.currentIndex = newIndex
                    } else if !self.graph.isPlaying {
                        self.currentIndex = -1
                    }
                    result(true)
                case "playIndex":
                    guard let index = (call.arguments as? [String: Any])?["index"] as? Int else {
                        throw self.argumentError("Missing track index")
                    }
                    try self.start(index: index, at: 0)
                    result(true)
                case "playFile":
                    guard let args = call.arguments as? [String: Any],
                          let path = args["path"] as? String else {
                        throw self.argumentError("Missing file path")
                    }
                    self.displayedTitle = nil
                    self.displayedArtist = nil
                    try self.graph.playFile(at: path, positionSeconds: (args["position"] as? NSNumber)?.doubleValue ?? 0)
                    self.currentIndex = self.queue.firstIndex(of: path) ?? -1
                    self.updateNowPlaying(force: true)
                    self.report()
                    result(true)
                case "stopFile":
                    self.graph.stopPlayback()
                    self.updateNowPlaying(force: true)
                    self.report()
                    result(true)
                case "pauseFile":
                    self.graph.pausePlayback()
                    self.updateNowPlaying(force: true)
                    self.report()
                    result(true)
                case "resumeFile":
                    try self.graph.resumePlayback()
                    self.updateNowPlaying(force: true)
                    self.report()
                    result(self.graph.isPlaying)
                case "seekFile":
                    guard let seconds = (call.arguments as? [String: Any])?["position"] as? NSNumber else {
                        throw self.argumentError("Missing position")
                    }
                    try self.graph.seekPlayback(to: seconds.doubleValue)
                    self.updateNowPlaying(force: true)
                    self.report()
                    result(true)
                case "skipFile":
                    let delta = (call.arguments as? [String: Any])?["delta"] as? Int ?? 1
                    try self.skip(by: delta)
                    result(self.currentIndex)
                case "getPosition":
                    result(self.graph.positionSeconds)
                case "getOutputInfo":
                    result(self.outputInfo())
                case "getState":
                    self.updateNowPlaying(force: false)
                    result([
                        "index": self.currentIndex,
                        "position": self.graph.positionSeconds,
                        "duration": self.graph.durationSeconds,
                        "playing": self.graph.isPlaying,
                        "finished": self.graph.finished,
                        "waveform": self.graph.waveform()
                    ] as [String: Any])
                case "exportBackup":
                    guard let args = call.arguments as? [String: Any],
                          let path = args["path"] as? String,
                          FileManager.default.fileExists(atPath: path) else {
                        throw self.argumentError("Backup archive is not available")
                    }
                    DispatchQueue.main.async {
                        let url = URL(fileURLWithPath: path)
                        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                        guard let root = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene })
                            .flatMap({ $0.windows })
                            .first(where: { $0.isKeyWindow })?.rootViewController else {
                            result(FlutterError(code: "BACKUP", message: "No active iOS window", details: nil))
                            return
                        }
                        var presenter = root
                        while let next = presenter.presentedViewController { presenter = next }
                        presenter.present(picker, animated: true)
                        result(true)
                    }
                case "probeFileDetails":
                    guard let args = call.arguments as? [String: Any],
                          let path = args["path"] as? String else {
                        throw self.argumentError("Missing file path")
                    }
                    DispatchQueue.global(qos: .utility).async {
                        let url = URL(fileURLWithPath: path)
                        var details: [String: String] = [:]
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                           let bytes = attrs[.size] as? NSNumber {
                            details["File size"] = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
                            details["Bitrate (file average)"] = "Unavailable"
                        }
                        if let file = try? AVAudioFile(forReading: url) {
                            let format = file.fileFormat
                            let sampleRate = format.sampleRate
                            details["Sample rate"] = String(format: "%.0f Hz", sampleRate)
                            details["Channels"] = String(format.channelCount)
                            details["Bit depth"] = format.commonFormat == .pcmFormatInt16 ? "16-bit PCM" :
                                format.commonFormat == .pcmFormatInt32 ? "32-bit PCM" :
                                format.commonFormat == .pcmFormatFloat32 ? "32-bit float" :
                                format.commonFormat == .pcmFormatFloat64 ? "64-bit float" : "Not reported"
                            details["Duration"] = String(format: "%.2f s", Double(file.length) / max(1, sampleRate))
                            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
                               file.length > 0, sampleRate > 0 {
                                let kbps = Double(size.int64Value) * 8 * sampleRate / Double(file.length) / 1000
                                details["Bitrate (file average)"] = String(format: "%.0f kbps", kbps)
                            }
                        }
                        DispatchQueue.main.async { result(details) }
                    }
                case "probeDurations":
                    guard let args = call.arguments as? [String: Any],
                          let paths = args["paths"] as? [String] else {
                        throw self.argumentError("Missing track paths")
                    }
                    DispatchQueue.global(qos: .utility).async {
                        let lengths: [Double] = paths.map { path in
                            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                                  file.processingFormat.sampleRate > 0 else { return -1 }
                            return Double(file.length) / file.processingFormat.sampleRate
                        }
                        DispatchQueue.main.async { result(lengths) }
                    }
                case "setWaveformEnabled":
                    let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                    self.graph.setWaveformEnabled(enabled)
                    result(true)
                case "embeddedArtwork":
                    guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
                        throw self.argumentError("Missing artwork file path")
                    }
                    DispatchQueue.global(qos: .utility).async {
                        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                        let art = asset.commonMetadata.first(where: {
                            $0.commonKey == AVMetadataKey.commonKeyArtwork
                        })?.dataValue
                        DispatchQueue.main.async { result(art?.base64EncodedString()) }
                    }
                case "setTemporaryRate":
                    guard let args = call.arguments as? [String: Any],
                          let rate = (args["rate"] as? NSNumber)?.floatValue else {
                        throw self.argumentError("Missing temporary rate")
                    }
                    try self.graph.setTemporaryRate(rate)
                    result(true)
                case "setTimePitch":
                    guard let args = call.arguments as? [String: Any],
                          let tempo = (args["tempo"] as? NSNumber)?.floatValue,
                          let cents = (args["cents"] as? NSNumber)?.floatValue else {
                        throw self.argumentError("Missing tempo or cents")
                    }
                    try self.graph.setTimePitch(tempo: tempo, semitones: cents / 100,
                                                linked: args["linked"] as? Bool ?? false)
                    // Avoid hammering lock-screen metadata during fast drags.
                    self.updateNowPlaying(force: false)
                    result(true)
                case "setEQ":
                    guard let args = call.arguments as? [String: Any],
                          let numbers = args["gains"] as? [NSNumber] else {
                        throw self.argumentError("Missing ten EQ gains")
                    }
                    try self.graph.setEQ(numbers.map { $0.floatValue },
                        enabled: args["enabled"] as? Bool ?? false,
                        preampDb: (args["preampDb"] as? NSNumber)?.floatValue ?? 0)
                    result(true)
                case "setNowPlaying":
                    let args = call.arguments as? [String: Any] ?? [:]
                    self.displayedTitle = args["title"] as? String
                    self.displayedArtist = args["artist"] as? String
                    self.updateNowPlaying(force: true)
                    result(true)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                result(FlutterError(code: "NATIVE_AUDIO", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func outputInfo() -> [String: Any] {
#if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first
        let port = route?.portType
        let label: String
        switch port {
        case .some(.builtInSpeaker): label = "iPhone speaker"
        case .some(.builtInReceiver): label = "iPhone earpiece"
        case .some(.headphones), .some(.headsetMic): label = "Wired headphones"
        default: label = route?.portName ?? "Audio output"
        }
        let path = currentIndex >= 0 && currentIndex < queue.count ? queue[currentIndex] : nil
        let ext = path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let codec = ext == "flac" ? "FLAC" : ext == "mp3" ? "MP3" :
            ext == "wav" ? "WAV" : ext == "aac" ? "AAC" :
            ext == "m4a" ? "M4A" : ""
        // Lossless describes the decoded source, NOT the Bluetooth or DAC link.
        // WAV/M4A require a codec probe before their contents can be certified.
        return ["output": label, "codec": codec, "lossless": ext == "flac"]
#else
        return ["output": "Audio output", "codec": "", "lossless": false]
#endif
    }

    private func argumentError(_ message: String) -> NSError {
        NSError(domain: "AuraDSP", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func start(index: Int, at position: Double) throws {
        guard index >= 0 && index < queue.count else { throw argumentError("Track index outside library") }
        displayedTitle = nil
        displayedArtist = nil
        try graph.playFile(at: queue[index], positionSeconds: position)
        currentIndex = index
        updateNowPlaying(force: true)
        report()
    }

    private func candidateIndex(after delta: Int) -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == 2 && delta > 0 { return currentIndex }
        if shuffle && delta > 0 && queue.count > 1 {
            // Randomized deck: every track plays once before the deck refills.
            // The current song cannot be selected again immediately.
            shuffleBag.removeAll(where: { $0 == currentIndex || $0 >= queue.count })
            if shuffleBag.isEmpty {
                shuffleBag = Array(queue.indices).filter { $0 != currentIndex }.shuffled()
            }
            return shuffleBag.removeLast()
        }
        let proposed = currentIndex + delta
        if proposed >= 0 && proposed < queue.count { return proposed }
        // Manual next/previous always wraps the sorted queue at its edges.
        return (proposed % queue.count + queue.count) % queue.count
    }

    private func skip(by delta: Int) throws {
        if delta < 0 && graph.positionSeconds > 3 {
            try graph.seekPlayback(to: 0)
            updateNowPlaying(force: true)
            report()
            return
        }
        if let index = candidateIndex(after: delta) {
            try start(index: index, at: 0)
        } else {
            graph.stopPlayback()
            updateNowPlaying(force: true)
            report()
        }
    }

    private func handleFinished() {
        do {
            if let index = candidateIndex(after: 1) {
                try start(index: index, at: 0)
            } else {
                graph.stopPlayback()
                updateNowPlaying(force: true)
                report()
            }
        } catch {
            graph.stopPlayback()
            report(error: error.localizedDescription)
        }
    }

    private func report(error: String? = nil) {
        var event: [String: Any] = [
            "index": currentIndex, "playing": graph.isPlaying,
            "position": graph.positionSeconds, "duration": graph.durationSeconds
        ]
        if let error = error { event["error"] = error }
        channel.invokeMethod("nativePlaybackEvent", arguments: event)
    }

    private func updateNowPlaying(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastInfoUpdate) > 1 else { return }
        lastInfoUpdate = now
        let path = currentIndex >= 0 && currentIndex < queue.count ? queue[currentIndex] : nil
        let fileTitle = path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "AuraLocal"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: displayedTitle ?? fileTitle,
            MPMediaItemPropertyArtist: displayedArtist ?? "Unknown Artist",
            MPMediaItemPropertyPlaybackDuration: graph.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: graph.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: graph.isPlaying ? Double(graph.timePitch.rate) : 0.0
        ]
    }

    @objc private func audioRouteChanged(_ notice: Notification) {
        guard let reasonValue = notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue.uintValue),
              reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.graph.outputRouteChanged()
            self.updateNowPlaying(force: true)
            self.report()
        }
    }

    @objc private func audioInterrupted(_ notice: Notification) {
        guard let info = notice.userInfo,
              let number = info[AVAudioSessionInterruptionTypeKey] as? NSNumber,
              let type = AVAudioSession.InterruptionType(rawValue: number.uintValue) else { return }
        if type == .began {
            graph.interruptedByAnotherApp()
            updateNowPlaying(force: true)
            report()
        } else if type == .ended {
            // Do not auto-resume. A user tap must reactivate the session and
            // restart the engine if the competing app stopped it.
            updateNowPlaying(force: true)
            report()
        }
    }

    private func registerRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            do {
                try self.graph.resumePlayback()
                self.updateNowPlaying(force: true)
                self.report()
                return self.graph.isPlaying ? .success : .commandFailed
            } catch { return .commandFailed }
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.graph.pausePlayback(); self.updateNowPlaying(force: true); self.report()
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            do { try self.skip(by: 1); return .success } catch { return .commandFailed }
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            do { try self.skip(by: -1); return .success } catch { return .commandFailed }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let change = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            do {
                try self.graph.seekPlayback(to: change.positionTime)
                self.updateNowPlaying(force: true)
                self.report()
                return .success
            } catch { return .commandFailed }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
