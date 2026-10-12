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
    while samples.count < 60000 && attempts < 100 {
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
    guard samples.count >= 60000 else { fatalError("No native audio output") }
    let region = Array(samples[22050..<60000])
    let amplitude = region.map { abs($0) }.max() ?? 0
    guard amplitude > 0.001 else { fatalError("Native output is silent") }
    let crossings = zip(region, region.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
    return Float(crossings) * 44100 / Float(region.count)
}
let normal = try measure(0)
let shifted = try measure(1200)
print("PRODUCTION GRAPH: FLAC normal=\(normal)Hz, +12 semitones=\(shifted)Hz")
guard abs(normal - 440) < 30 && abs(shifted - 880) < 60 else {
    fatalError("Production graph does not audibly shift FLAC pitch")
}
print("PASS: production graph decoded FLAC and produced audible pitch-shifted PCM")
