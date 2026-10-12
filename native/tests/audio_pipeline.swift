import Foundation
import AVFoundation

// This test deliberately fails if FLAC cannot be decoded by AVAudioFile.
// A successful iOS compilation is not proof of a functional FLAC pitch path.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: audio_pipeline <test.flac>") }
let path = CommandLine.arguments[1]
do {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard file.length > 0 else { fatalError("FLAC decoded to zero frames") }
    let frames = AVAudioFrameCount(min(file.length, 8192))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
        fatalError("Cannot allocate decoded PCM")
    }
    try file.read(into: buffer, frameCount: frames)
    guard buffer.frameLength > 0 else { fatalError("FLAC PCM buffer is empty") }
    print("PASS: decoded FLAC into \(buffer.frameLength) PCM frames")
} catch {
    fputs("FAIL: native FLAC decode unavailable: \(error)\n", stderr)
    exit(1)
}

let engine = AVAudioEngine()
let source = AVAudioPlayerNode()
let pitch = AVAudioUnitTimePitch()
engine.attach(source)
engine.attach(pitch)
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
engine.connect(source, to: pitch, format: format)
engine.connect(pitch, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
try engine.start()

func renderTone(cents: Float) throws -> Float {
    source.stop()
    pitch.pitch = cents
    pitch.rate = 1
    let n = 44100 * 2
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buffer.frameLength = AVAudioFrameCount(n)
    for i in 0..<n {
        buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / 44100)
    }
    source.scheduleBuffer(buffer)
    source.play()
    var samples = [Float]()
    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    while samples.count < 60000 {
        let status = try engine.renderOffline(4096, to: out)
        if status == .success, let p = out.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        } else if status == .error { fatalError("Offline DSP render failed") }
    }
    let region = Array(samples[22050..<60000])
    let crossings = zip(region, region.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
    return Float(crossings) * 44100 / Float(region.count)
}
let base = try renderTone(cents: 0)
let raised = try renderTone(cents: 1200)
print("DSP frequencies: unshifted=\(base)Hz, +12 semitones=\(raised)Hz")
guard abs(base - 440) < 25, abs(raised - 880) < 45 else {
    fatalError("Native pitch processing did not measurably change output frequency")
}
print("PASS: decoded audio and measurable pitch processing")
