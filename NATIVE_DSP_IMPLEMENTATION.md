# AuraLocal native DSP implementation — engineering contract

Status: ACTIVE PRIORITY. The current Flutter just_audio player does NOT have a real graphic EQ or independent pitch and tempo. Do not present UI controls for these features until native processing is connected and audible.

## Non-negotiable implementation decision
iOS AVPlayer/just_audio playback cannot simply be routed through AVAudioUnitEQ. A graphic equalizer requires decoded PCM flowing through a controlled DSP graph. Native AVAudioEngine with AVAudioUnitEQ can do this for formats supported by AVAudioFile, but FLAC requires a compatible decoder feeding PCM buffers. AVAudioUnitTimePitch supports rate and pitch controls, but quality and independent behavior must be tested on actual devices. Rubber Band is an alternative if licensing, integration, and performance requirements are satisfied.

## Native architecture
1. Create a Flutter MethodChannel/EventChannel audio backend, with a single owner for transport state, position, duration, queue, repeat, shuffle and remote commands.
2. Decoder interface for FLAC, MP3, M4A/AAC and WAV. Preserve original files on disk; decode in memory for processing. Verify FLAC sample rate, channel count and sample format. Never falsely advertise FLAC support through AVAudioFile alone.
3. Buffer producer and scheduling with AVAudioPlayerNode or a suitable AudioUnit render source, including sample-accurate position tracking, seeking, underrun handling and gapless transition.
4. AVAudioEngine DSP chain: source -> headroom/gain -> AVAudioUnitEQ (10 bands at 31,62,125,250,500,1000,2000,4000,8000,16000 Hz) -> time/pitch processor -> output. Confirm graph format compatibility at each sample rate.
5. Independent tempo (0.5x–2x, pitch fixed) and pitch (-12 to +12 semitones, duration fixed) and simultaneous adjustment. Prefer a tested quality algorithm; evaluate transients, vocals and CPU/battery.
6. EQ bypass must route unprocessed audio when off. Flat and custom presets persisted; apply negative preamp headroom for boosted bands; avoid digital clipping.
7. Integrate iOS AVAudioSession, lock-screen Now Playing, background audio, interruption handling and Bluetooth remote transport. Ensure exactly one audio engine is active (avoid simultaneous just_audio playback).
8. Wire Flutter controls only after native channel implementation; persist DSP settings, restore safely, expose processing errors.

## Acceptance tests before any IPA is called DSP-capable
- Confirm all ten bands measurably change the intended frequency regions (test tones/spectrum comparison), including 16 kHz on supported sample rates.
- Verify 1.25x tempo does not change pitch, +3 semitones pitch does not change duration, and both controls operate together.
- Verify FLAC imports play with DSP on/off, pause, seek, next/previous, background/lock screen and headphone controls.
- Verify EQ bypass and flat settings, no clipping at max boosts with protection, no clicks during adjustments, and stable long-session playback.
- Verify clean install AND upgrade from Build 24 preserve user music and playlists.

## Delivery
Do not label an IPA 'EQ implemented' or 'independent pitch/tempo' until these checks pass. Preserve the working Build 24 player as fallback during development. Do not substitute speed or volume controls for pitch/EQ.
