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
        NSLog("AuraStretch: opening source %@", source.path)
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        NSLog("AuraStretch: source opened, frames=%lld", file.length)
        let channels = Int(file.processingFormat.channelCount)
        let sampleRate = file.processingFormat.sampleRate
        guard let state = auraStretchCreate(Int32(channels), Int32(sampleRate), Float(cents / 100)) else {
            throw NSError(domain: "AuraStretch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not initialize Signalsmith"])
        }
        defer { auraStretchDestroy(state) }
        let key = "\(source.path.hashValue)_\(file.length)_\(Int(tempo * 10000))_\(Int(cents))"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("aura-stretch-\(key).wav")
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
        let expectedFrames = Int((Double(file.length) / tempo).rounded())
        let byteCount = expectedFrames * channels * MemoryLayout<Float>.size
        guard byteCount <= Int(UInt32.max) - 36 else {
            throw NSError(domain: "AuraStretch", code: 4, userInfo: [NSLocalizedDescriptionKey: "Audio exceeds WAV output limit"])
        }
        func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        var header = Data("RIFF".utf8)
        appendLE(UInt32(36 + byteCount), to: &header)
        header.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16), to: &header)
        appendLE(UInt16(3), to: &header) // IEEE 32-bit float PCM
        appendLE(UInt16(channels), to: &header)
        appendLE(UInt32(sampleRate), to: &header)
        appendLE(UInt32(sampleRate) * UInt32(channels * 4), to: &header)
        appendLE(UInt16(channels * 4), to: &header)
        appendLE(UInt16(32), to: &header)
        header.append(contentsOf: "data".utf8)
        appendLE(UInt32(byteCount), to: &header)
        NSLog("AuraStretch: creating raw WAV file")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        NSLog("AuraStretch: opening WAV file handle")
        let outputFile = try FileHandle(forWritingTo: outputURL)
        NSLog("AuraStretch: WAV file handle opened")
        defer { try? outputFile.close() }
        try outputFile.write(contentsOf: header)
        NSLog("AuraStretch: WAV header written")
        let chunk = 4096
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        let totalOutput = expectedFrames
        var outputWritten = 0
        var discard = Int(auraStretchOutputLatency(state))
        var ratioCarry = 0.0
        var inputFinished = false
        while outputWritten < totalOutput {
            var frames = 0
            if !inputFinished {
                NSLog("AuraStretch: reading FLAC at %lld", file.framePosition)
                try file.read(into: inputBuffer, frameCount: AVAudioFrameCount(chunk))
                NSLog("AuraStretch: read %d FLAC frames", inputBuffer.frameLength)
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
            NSLog("AuraStretch: processing %d input frames", frames)
            input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    auraStretchProcess(state, src.baseAddress, Int32(frames), dst.baseAddress, Int32(outFrames))
                }
            }
            let skip = min(discard, outFrames)
            discard -= skip
            let available = min(outFrames - skip, totalOutput - outputWritten)
            if available > 0 {
                let first = skip * channels
                let last = (skip + available) * channels
                let samples = Array(output[first..<last])
                let bytes = samples.withUnsafeBufferPointer { ptr in
                    Data(bytes: ptr.baseAddress!, count: samples.count * MemoryLayout<Float>.size)
                }
                try outputFile.write(contentsOf: bytes)
                outputWritten += available
            }
        }
        NSLog("AuraStretch: rendered %d frames", outputWritten)
        return outputURL
    }
}
