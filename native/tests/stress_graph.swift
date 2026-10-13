import Foundation
import AVFoundation

// Runs on the actual production graph using an offline FLAC source.
// Fast parameter sweeps and exact reset combinations should never stop,
// restart or flush the source, generate NaNs, or catastrophically clip.
guard CommandLine.arguments.count == 2 else { fatalError("Pass FLAC path") }
let graph = AuraDspGraph()
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let output = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 512)!
try graph.playFile(at: CommandLine.arguments[1])
var rendered = 0
var maximum: Float = 0
var nonzero = 0
var retries = 0
for step in 0..<240 {
    let tempo: Float = step % 11 == 0 ? 1.0 : 0.5 + Float((step * 17) % 151) / 100.0
    let cents: Float = step % 11 == 0 ? 0 : Float((step * 71) % 2401 - 1200)
    try graph.setTimePitch(tempo: tempo, semitones: cents / 100.0)
    if step % 7 == 0 {
        let gains: [Float] = (0..<10).map { Float((step + $0 * 3) % 25 - 12) }
        try graph.setEQ(gains, enabled: true)
    }
    let status = try graph.engine.renderOffline(512, to: output)
    switch status {
    case .success:
        guard let samples = output.floatChannelData?[0] else { fatalError("No PCM") }
        for i in 0..<Int(output.frameLength) {
            let sample = samples[i]
            guard sample.isFinite else { fatalError("NaN/Inf after fast DSP reset") }
            maximum = max(maximum, abs(sample))
            if abs(sample) > 0.00001 { nonzero += 1 }
        }
        rendered += 1
    case .cannotDoInCurrentContext, .insufficientDataFromInputNode: retries += 1
    case .error: fatalError("Production DSP render error during fast controls")
    @unknown default: fatalError("Unknown render state")
    }
}
guard rendered > 150, nonzero > 1500, maximum < 2.0 else {
    fatalError("DSP stress test failed: rendered=\(rendered), nonzero=\(nonzero), peak=\(maximum), retries=\(retries)")
}
print("PASS: 240 live pitch/tempo changes and 35 EQ changes with resets; finite PCM, peak=\(maximum)")
