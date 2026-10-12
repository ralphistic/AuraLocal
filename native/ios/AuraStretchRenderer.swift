import AVFoundation

@_silgen_name("AuraStretchCreate")
private func auraStretchCreate(_ channels: Int32, _ sampleRate: Int32, _ semitones: Float) -> UnsafeMutableRawPointer?
@_silgen_name("AuraStretchDestroy")
private func auraStretchDestroy(_ state: UnsafeMutableRawPointer)
@_silgen_name("AuraStretchOutputLatency")
private func auraStretchOutputLatency(_ state: UnsafeMutableRawPointer) -> Int32
@_silgen_name("AuraStretchProcess")
private func auraStretchProcess(_ state: UnsafeMutableRawPointer, _ input: UnsafePointer<Float>?,
                                _ inputFrames: Int32, _ output: UnsafeMutablePointer<Float>?,
                                _ outputFrames: Int32)

/// Converts the source to a cached, independently pitch/tempo-adjusted float PCM file.
/// Rendering is deliberately separate from the realtime audio callback.
enum AuraStretchRenderer {
    static func render(source: URL, tempo: Double, cents: Double) throws -> URL {
        guard tempo >= 0.5 && tempo <= 2, cents >= -1200 && cents <= 1200 else {
            throw NSError(domain: "AuraStretch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pitch or tempo outside supported range"])
        }
        if abs(tempo - 1) < 0.00001 && abs(cents) < 0.00001 { return source }
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(file.processingFormat.channelCount)
        let sampleRate = file.processingFormat.sampleRate
        guard let state = auraStretchCreate(Int32(channels), Int32(sampleRate), Float(cents / 100)) else {
            throw NSError(domain: "AuraStretch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not initialize Signalsmith"])
        }
        defer { auraStretchDestroy(state) }
        let key = "\(source.path.hashValue)_\(file.length)_\(Int(tempo * 10000))_\(Int(cents))"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("aura-stretch-\(key).caf")
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false)!
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 4096
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(16384))!
        let totalOutput = Int((Double(file.length) / tempo).rounded())
        var outputWritten = 0
        var discard = Int(auraStretchOutputLatency(state))
        var ratioCarry = 0.0
        var inputFinished = false
        while outputWritten < totalOutput {
            var frames = 0
            if !inputFinished {
                try file.read(into: inputBuffer, frameCount: AVAudioFrameCount(chunk))
                frames = Int(inputBuffer.frameLength)
                if frames == 0 { inputFinished = true }
            }
            if frames == 0 { frames = chunk }
            var input = [Float](repeating: 0, count: frames * channels)
            if !inputFinished, let data = inputBuffer.floatChannelData {
                for f in 0..<frames {
                    for c in 0..<channels { input[f * channels + c] = data[c][f] }
                }
            }
            let desired = Double(frames) / tempo + ratioCarry
            let outFrames = Int(desired)
            ratioCarry = desired - Double(outFrames)
            var output = [Float](repeating: 0, count: outFrames * channels)
            input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    auraStretchProcess(state, src.baseAddress, Int32(frames), dst.baseAddress, Int32(outFrames))
                }
            }
            let skip = min(discard, outFrames)
            discard -= skip
            let available = min(outFrames - skip, totalOutput - outputWritten)
            if available > 0, let data = outputBuffer.floatChannelData {
                for f in 0..<available {
                    for c in 0..<channels { data[c][f] = output[(f + skip) * channels + c] }
                }
                outputBuffer.frameLength = AVAudioFrameCount(available)
                try outputFile.write(from: outputBuffer)
                outputWritten += available
            }
        }
        return outputURL
    }
}
