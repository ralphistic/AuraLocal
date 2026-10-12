import AVFoundation

/// FLAC playback flows through source -> EQ -> pitch -> system output.
final class AuraDspGraph {
    let engine = AVAudioEngine()
    let source = AVAudioPlayerNode()
    let equalizer = AVAudioUnitEQ(numberOfBands: 10)
    let timePitch = AVAudioUnitTimePitch()
    private(set) var configured = false
    private var activeFile: AVAudioFile?

    func playFile(at path: String, positionSeconds: Double = 0) throws {
        try configure()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        source.stop()
        let start = AVAudioFramePosition(max(0, positionSeconds) * file.processingFormat.sampleRate)
        guard start < file.length else { throw NSError(domain: "AuraDSP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Start position exceeds file length"]) }
        activeFile = file
        source.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(min(file.length - start, Int64(UInt32.max))), at: nil, completionHandler: nil)
        if !engine.isRunning { try engine.start() }
        source.play()
        guard source.isPlaying else { throw NSError(domain: "AuraDSP", code: 4, userInfo: [NSLocalizedDescriptionKey: "Native player failed to start"]) }
    }

    func stopPlayback() {
        source.stop()
        activeFile = nil
    }
    let centers: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

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
        engine.connect(source, to: equalizer, format: nil)
        engine.connect(equalizer, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        try engine.start()
        configured = true
    }

    func setEQ(_ gains: [Float], enabled: Bool) throws {
        guard gains.count == 10, gains.allSatisfy({ $0.isFinite && (-12...12).contains($0) }) else {
            throw NSError(domain: "AuraDSP", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ten EQ gains from -12 to +12 dB required"])
        }
        try configure()
        for (i, gain) in gains.enumerated() {
            equalizer.bands[i].gain = gain
        }
        equalizer.globalGain = enabled ? -max(0, gains.max() ?? 0) : 0
        equalizer.bypass = !enabled
    }

    func setTimePitch(tempo: Float, semitones: Float) throws {
        guard tempo.isFinite, semitones.isFinite, (0.5...2).contains(tempo),
              (-12...12).contains(semitones) else {
            throw NSError(domain: "AuraDSP", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid tempo or pitch"])
        }
        try configure()
        timePitch.rate = tempo
        timePitch.pitch = semitones * 100
    }
}
