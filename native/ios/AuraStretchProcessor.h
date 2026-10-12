#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Independent polyphonic pitch and tempo processing. Audio is interleaved float PCM.
// The caller owns the returned processor and must destroy it.
void *AuraStretchCreate(int channels, int sampleRate, float semitones);
void AuraStretchDestroy(void *processor);
int AuraStretchInputLatency(void *processor);
int AuraStretchOutputLatency(void *processor);
void AuraStretchProcess(void *processor, const float *input, int inputFrames,
                        float *output, int outputFrames);
#ifdef __cplusplus
}
#endif
