import Foundation
import AVFoundation

// Run against the production AuraDspGraph, not a separate example graph.
guard CommandLine.arguments.count == 2 else { fatalError("Pass FLAC path") }
let graph = AuraDspGraph()
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
let output = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 4096)!

func measure(_ cents: Float) throws -> Float {
    graph.stopPlayback()
    try graph.setTimePitch(tempo: 1, semitones: cents / 100)
    try graph.playFile(at: CommandLine.arguments[1])
    var samples: [Float] = []
    var attempts = 0
    while samples.count < 110000 && attempts < 140 {
        attempts += 1
        let status = try graph.engine.renderOffline(4096, to: output)
        switch status {
        case .success:
            if let data = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            }
        case .cannotDoInCurrentContext, .insufficientDataFromInputNode: continue
        case .error: fatalError("Production DSP failed to render")
        @unknown default: fatalError("Unexpected render status")
        }
    }
    guard samples.count >= 110000 else { fatalError("No native audio output") }
    let region = Array(samples[65000..<110000])
    let amplitude = region.map { abs($0) }.max() ?? 0
    guard amplitude > 0.001 else { fatalError("Native output is silent") }
    // Counted zero crossings are unreliable after time-stretching because
    // transient windows and waveform discontinuities add false crossings.
    // Measure the dominant musical fundamental using spectral correlation.
    let window = Array(region.prefix(8192))
    var bestHz: Float = 0
    var bestPower: Double = -1
    for hz in stride(from: 350, through: 1000, by: 2) {
        let omega = 2.0 * Double.pi * Double(hz) / 44100.0
        var real = 0.0
        var imag = 0.0
        for i in window.indices {
            let value = Double(window[i]) * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(window.count - 1)))
            real += value * cos(omega * Double(i))
            imag += value * sin(omega * Double(i))
        }
        let power = real * real + imag * imag
        if power > bestPower { bestPower = power; bestHz = Float(hz) }
    }
    return bestHz
}
let normal = try measure(0)
let shifted = try measure(1200)
fputs("PRODUCTION GRAPH: FLAC normal=\(normal)Hz, +12 semitones=\(shifted)Hz\n", stderr)
guard abs(normal - 440) < 30 && abs(shifted - 880) < 60 else {
    fputs("FAIL: Production graph does not audibly shift FLAC pitch\n", stderr)
    exit(1)
}
print("PASS: production graph decoded FLAC and produced audible pitch-shifted PCM")
