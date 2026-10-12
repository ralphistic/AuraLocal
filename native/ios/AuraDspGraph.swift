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
    // Playback position is wall-clock based, scaled by TimePitch tempo. AVAudioPlayerNode
    // sample times can stall or drift after iOS audio-session interruptions.
    private var anchorSeconds: Double = 0
    private var anchorUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private(set) var paused = true
    private(set) var finished = false
    private var generation: Int = 0
    // Interruptions may discard scheduled buffers even though AVAudioPlayerNode
    // still reports a loaded file. Reprime that same file when playback resumes.
    private var needsInterruptionReprime = false
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
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - anchorUptime)
        return min(durationSeconds, max(0, anchorSeconds + elapsed * Double(timePitch.rate)))
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
            // A live *spectrum analyzer*, not a frozen overview of the track.
            // Goertzel filters estimate log-spaced musical frequency bands from
            // the latest PCM window. Fast attack / slower release prevents jitter.
            let size = self.waveValues.count
            let window = min(frames, 512)
            guard channels > 0, window > 32 else { return }
            let rate = Double(buffer.format.sampleRate)
            for band in 0..<size {
                let hz = 55.0 * pow(13500.0 / 55.0, Double(band) / Double(max(1, size - 1)))
                let coefficient = Float(2.0 * cos(2.0 * Double.pi * hz / rate))
                var q1: Float = 0
                var q2: Float = 0
                for frame in 0..<window {
                    var sample: Float = 0
                    for channel in 0..<channels { sample += audio[channel][frame] }
                    sample /= Float(channels)
                    let taper = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(frame) / Double(window - 1)))
                    let q0 = sample * taper + coefficient * q1 - q2
                    q2 = q1
                    q1 = q0
                }
                let power = max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2)
                let amplitude = sqrt(power) * (4.0 / Float(window))
                let target = min(1, sqrt(max(0, amplitude * 4.5)))
                let previous = self.waveValues[band]
                self.waveValues[band] = previous + (target - previous) * (target > previous ? 0.65 : 0.13)
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
        anchorSeconds = Double(start) / rate
        anchorUptime = ProcessInfo.processInfo.systemUptime
        paused = false
        finished = false
        needsInterruptionReprime = false
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
        // iOS can already have stopped the underlying player by the time its
        // interruption notification arrives; always record the paused state.
        guard activeFile != nil, !paused else { return }
        pausedFrame = AVAudioFramePosition(positionSeconds * sampleRate)
        paused = true
        if source.isPlaying { source.pause() }
    }
    func interruptedByAnotherApp() {
        pausePlayback()
        needsInterruptionReprime = activeFile != nil
    }
    func resumePlayback() throws {
        guard activeFile != nil else {
            throw NSError(domain: "AuraDSP", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "No track is loaded"])
        }
        guard paused, !finished else { return }
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        // Required after YouTube or another app takes over the output session.
        try session.setActive(true)
#endif
        if needsInterruptionReprime, let path = activeFile?.url.path {
            let savedPosition = min(max(0, Double(pausedFrame) / sampleRate),
                                    max(0, durationSeconds - 0.001))
            // Audio session recovery requires scheduling a fresh segment. Simply
            // calling source.play() can return success but produce silence.
            try playFile(at: path, positionSeconds: savedPosition)
            needsInterruptionReprime = false
            return
        }
        if !engine.isRunning { try engine.start() }
        source.play()
        guard source.isPlaying else {
            throw NSError(domain: "AuraDSP", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "The iOS audio engine did not resume"])
        }
        anchorSeconds = Double(pausedFrame) / sampleRate
        anchorUptime = ProcessInfo.processInfo.systemUptime
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
        needsInterruptionReprime = false
        paused = true
        finished = false
        startFrame = 0
        pausedFrame = 0
        anchorSeconds = 0
        anchorUptime = ProcessInfo.processInfo.systemUptime
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
        let currentPosition = positionSeconds
        timePitch.rate = tempo
        timePitch.pitch = semitones * 100
        anchorSeconds = currentPosition
        anchorUptime = ProcessInfo.processInfo.systemUptime
    }
}
