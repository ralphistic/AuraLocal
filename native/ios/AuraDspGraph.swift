import AVFoundation

/// The sole audio output path: file -> 10-band EQ -> Apple's TimePitch -> mixer.
final class AuraDspGraph {
    let engine = AVAudioEngine()
    let source = AVAudioPlayerNode()
    let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    let timePitch = AVAudioUnitTimePitch()
    private(set) var configured = false
    private var activeFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var pausedFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private(set) var paused = true
    private(set) var finished = false
    private var generation: Int = 0
    var onFinished: (() -> Void)?
    private let waveLock = NSLock()
    private var waveValues: [Float] = Array(repeating: 0, count: 48)
    private var waveEnabled = false
    let centers: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    var durationSeconds: Double {
        guard let file = activeFile else { return 0 }
        return Double(file.length) / sampleRate
    }
    var isPlaying: Bool { source.isPlaying && !paused && !finished }
    var positionSeconds: Double {
        if paused || finished { return min(durationSeconds, Double(pausedFrame) / sampleRate) }
        guard let renderTime = source.lastRenderTime,
              let playerTime = source.playerTime(forNodeTime: renderTime) else {
            return min(durationSeconds, Double(startFrame) / sampleRate)
        }
        return min(durationSeconds, max(0, Double(startFrame + AVAudioFramePosition(playerTime.sampleTime)) / sampleRate))
    }
    func waveform() -> [Float] {
        waveLock.lock(); defer { waveLock.unlock() }
        return waveValues
    }
    func setWaveformEnabled(_ enabled: Bool) {
        waveLock.lock()
        waveEnabled = enabled
        if !enabled { waveValues = Array(repeating: 0, count: 48) }
        waveLock.unlock()
    }
    func configure() throws {
        guard !configured else { return }
        engine.attach(source)
        engine.attach(equalizer)
        engine.attach(timePitch)
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = centers[index]
            band.bandwidth = 1
            band.gain = 0
        }
        equalizer.bypass = true
        timePitch.rate = 1
        timePitch.pitch = 0
        timePitch.overlap = 32
        engine.connect(source, to: equalizer, format: nil)
        engine.connect(equalizer, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: mixer.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self = self, let audio = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            self.waveLock.lock()
            defer { self.waveLock.unlock() }
            guard self.waveEnabled else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            let size = self.waveValues.count
            for bucket in 0..<size {
                let lower = bucket * frames / size
                let upper = max(lower + 1, (bucket + 1) * frames / size)
                var peak: Float = 0
                for frame in lower..<min(upper, frames) {
                    var mixed: Float = 0
                    for channel in 0..<channels { mixed += abs(audio[channel][frame]) }
                    peak = max(peak, mixed / Float(max(channels, 1)))
                }
                self.waveValues[bucket] = min(1, peak * 3)
            }
        }
        try engine.start()
        configured = true
    }
    func playFile(at path: String, positionSeconds: Double = 0) throws {
        try configure()
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
#endif
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, positionSeconds) * rate)
        guard file.length > 0, start < file.length else {
            throw NSError(domain: "AuraDSP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid start position or empty audio file"])
        }
        generation += 1
        let token = generation
        source.stop()
        activeFile = file
        sampleRate = rate
        startFrame = start
        pausedFrame = start
        paused = false
        finished = false
        source.scheduleSegment(file, startingFrame: start,
                               frameCount: AVAudioFrameCount(min(file.length - start, Int64(UInt32.max))),
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token, !self.paused else { return }
                self.finished = true
                self.pausedFrame = self.activeFile?.length ?? 0
                self.onFinished?()
            }
        }
        if !engine.isRunning { try engine.start() }
        source.play()
    }
    func pausePlayback() {
        guard isPlaying else { return }
        pausedFrame = AVAudioFramePosition(positionSeconds * sampleRate)
        source.pause()
        paused = true
    }
    func resumePlayback() {
        guard paused, activeFile != nil, !finished else { return }
        source.play()
        paused = false
    }
    func seekPlayback(to seconds: Double) throws {
        guard let file = activeFile else { return }
        let path = file.url.path
        let wasPlaying = isPlaying
        try playFile(at: path, positionSeconds: min(max(0, seconds), max(0, durationSeconds - 0.001)))
        if !wasPlaying { pausePlayback() }
    }
    func stopPlayback() {
        generation += 1
        source.stop()
        activeFile = nil
        paused = true
        finished = false
        startFrame = 0
        pausedFrame = 0
    }
    func setEQ(_ gains: [Float], enabled: Bool) throws {
        guard gains.count == 10, gains.allSatisfy({ $0.isFinite && (-12...12).contains($0) }) else {
            throw NSError(domain: "AuraDSP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ten EQ gains from -12 to +12 dB required"])
        }
        try configure()
        for (i, gain) in gains.enumerated() { equalizer.bands[i].gain = gain }
        equalizer.globalGain = enabled ? -max(0, gains.max() ?? 0) : 0
        equalizer.bypass = !enabled
    }
    func setTimePitch(tempo: Float, semitones: Float) throws {
        guard tempo.isFinite, semitones.isFinite, (0.5...2).contains(tempo),
              (-12...12).contains(semitones) else {
            throw NSError(domain: "AuraDSP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid tempo or pitch"])
        }
        try configure()
        timePitch.rate = tempo
        timePitch.pitch = semitones * 100
    }
}
