#include "AuraStretchProcessor.h"
#include "signalsmith-stretch.h"
#include <algorithm>
#include <cmath>
#include <vector>
#include <memory>

struct AuraStretchState {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    int channels;
    explicit AuraStretchState(int channelCount, int sampleRate, float semitones)
      : channels(channelCount) {
        stretch.presetDefault(channels, sampleRate);
        stretch.setTransposeSemitones(semitones);
        // Keep vocal formants near their original frequencies while transposing.
        stretch.setFormantFactor(1.0f, true);
    }
};

extern "C" void *AuraStretchCreate(int channels, int sampleRate, float semitones) {
    if (channels < 1 || channels > 8 || sampleRate < 8000 || sampleRate > 384000 ||
        !std::isfinite(semitones) || semitones < -24 || semitones > 24) return nullptr;
    try { return new AuraStretchState(channels, sampleRate, semitones); }
    catch (...) { return nullptr; }
}

extern "C" void AuraStretchDestroy(void *processor) {
    delete static_cast<AuraStretchState *>(processor);
}

extern "C" int AuraStretchInputLatency(void *processor) {
    return processor ? static_cast<AuraStretchState *>(processor)->stretch.inputLatency() : 0;
}
extern "C" int AuraStretchOutputLatency(void *processor) {
    return processor ? static_cast<AuraStretchState *>(processor)->stretch.outputLatency() : 0;
}

extern "C" void AuraStretchProcess(void *processor, const float *input, int inputFrames,
                                     float *output, int outputFrames) {
    if (!processor || !output || inputFrames < 0 || outputFrames < 0 ||
        (inputFrames && !input)) return;
    auto *state = static_cast<AuraStretchState *>(processor);
    const int channels = state->channels;
    std::vector<std::vector<float>> planarInput(channels, std::vector<float>(inputFrames));
    std::vector<std::vector<float>> planarOutput(channels, std::vector<float>(outputFrames));
    for (int i = 0; i < inputFrames; ++i)
        for (int c = 0; c < channels; ++c)
            planarInput[c][i] = input[i * channels + c];
    std::vector<const float *> inPtrs(channels);
    std::vector<float *> outPtrs(channels);
    for (int c = 0; c < channels; ++c) {
        inPtrs[c] = planarInput[c].data();
        outPtrs[c] = planarOutput[c].data();
    }
    state->stretch.process(inPtrs.data(), inputFrames, outPtrs.data(), outputFrames);
    for (int i = 0; i < outputFrames; ++i)
        for (int c = 0; c < channels; ++c)
            output[i * channels + c] = planarOutput[c][i];
}
