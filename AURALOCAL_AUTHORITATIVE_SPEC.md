# AuraLocal — Authoritative Product Specification
Status: APPROVED PRODUCT DIRECTION (2026-10-11)
Repository: ralphistic/AuraLocal
Priority: This document governs future feature design and implementation. Do not silently replace requirements with shortcuts. If technically infeasible, explain tradeoffs before changing scope.

## Mission
Build a polished, Spotify-inspired, **offline-first iPhone music player** for the user's own locally stored, lossless FLAC collection. No subscription, streaming requirement, or account requirement. Preserve original files and their audio quality. Internet is optional and used only for opt-in features such as online lyrics.

## Approved choices
- Visual language: Spotify-inspired dark UI, but AuraLocal identity, not a literal brand copy.
- Initial screen: **Your Library**, not the full-screen player.
- Equalizer: functional **10-band graphic EQ** (not a placeholder).
- Lyrics: embedded lyrics, synchronized LRC, **plus optional online lyrics lookup** when network available; playback remains fully offline.
- Queue: editable **Up Next**.
- Folder browsing: yes.
- Themes: album-artwork-derived automatic colors **plus manually selectable themes**.

## Navigation and interface
- Library-first landing page with accessible Songs, Albums, Artists, Playlists, and Folders; search and sorting.
- Persistent compact mini-player while browsing, tapping expands to full Now Playing.
- Full player includes prominent album art, title, artist, album, timeline with seeking, play/pause, previous/next, shuffle, Repeat Off/All/One, queue and lyrics access.
- Modern dark layout, readable typography, touch-friendly targets, smooth transitions, graceful empty/loading/error states, clear menu/navigation. Do not ship only a giant player with no menu.
- Artwork-derived colors are tasteful and maintain contrast; manual themes override automatic color selection.

## Music library and imports
- Import FLAC, MP3, M4A/AAC, WAV from iOS Files picker, including multiple tracks; support album-sized batches.
- **Immediately copy imported audio into persistent app-controlled storage**; temporary picker paths must not be the long-term library. Keep original audio bytes intact; do not transcode, recompress, modify, or delete user source files.
- Persist a durable catalog with path, original/display filename, import date, metadata, folder provenance where available, and playlist associations. On launch restore catalog, verify missing files, and show meaningful errors.
- Read embedded title, artist, album, album artist, track/disc number, duration, cover art and lyrics where supported. Fall back gracefully to filenames and placeholders. Never substitute 'AuraLocal' as if it were the true artist.
- Albums/artists group by metadata; songs searchable/sortable. User-created playlists editable/deletable. Folder browsing preserves imported relative structure where iOS Files provides it; don't imply arbitrary continuous filesystem access.
- App updates should preserve library and settings if bundle identifier and signing/app container remain compatible. Warn before reinstall flows that could erase app data.

## Playback
- Robust FLAC playback at source quality with no unnecessary conversion; support other stated formats.
- Play/pause, next/previous, accurate timeline scrub and dedicated 10-second back/forward seeking. Previous restarts track when past a few seconds; otherwise previous track. Define sensible behavior at playlist boundaries, including shuffle and repeat.
- Editable Up Next: inspect, reorder, remove, and add tracks; queue navigation reflects actual playback order.
- Shuffle, repeat Off/All/One, gapless where technically supported; no arbitrary gaps.
- Continue audio while app backgrounded and screen locked; iOS Now Playing info with accurate title, artist, album art, duration/elapsed time; Control Center, headphone/Bluetooth remote commands and interruptions handled correctly.
- Audio engine must coordinate with iOS audio session and avoid resetting the playlist unnecessarily when adding imports.

## EQ and audio quality
- Working 10-band graphic EQ with nominal centers 31, 62, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz, adjustable roughly +/-12 dB. Flat default, bypass switch, presets and saved custom preset/settings.
- Provide headroom/preamp or clipping protection when boosting bands; avoid distortion.
- When bypassed, do not unnecessarily alter signal; EQ-enabled output is processed, not bit-perfect. Don't claim bit-perfect output through iOS hardware without verification.
- Investigate a suitable iOS-native audio/DSP engine and FLAC compatibility rather than presenting a decorative EQ.

## Lyrics
- Display embedded plain/synchronized lyrics and imported .lrc sidecars, synchronized with playback when timestamps exist; plain scrolling lyrics otherwise.
- Optional online lookup when connected, user-initiated or opt-in; respect provider API licensing/rate limits, show source and unavailable states. No online dependency for offline music or stored lyrics. Don't claim availability of lyrics not found.

## Settings and personalization
- Theme selection: automatic from artwork or manually chosen accent/theme.
- EQ, playback preferences, library management, lyrics options and about/build version accessible in Settings.
- Remember selected theme, EQ, repeat/shuffle, last track and position when feasible.

## Build, distribution and acceptance
- Windows development workflow, free GitHub Actions macOS iOS build, unsigned IPA installed through user's Signulous subscription.
- GitHub Releases 'latest-build' provides a stable unsigned IPA URL. **When asked to check, verify successful build and release asset before linking.** Supply IPA link directly in chat after verification; no iCloud/shared folder required.
- Don't claim unverified compile, lock-screen behavior, hardware audio quality or feature completion. Verify CI logs; user device test remains necessary for actual playback/Control Center/EQ.
- Group related changes into coherent, testable milestones rather than one trivial feature per install.
- Preserve the working build pipeline and playback when refactoring. Avoid duplicate code/partial merges; use clean file rewrites as needed.

## Implementation order (planning, not scope reduction)
1. Stable app architecture, persistent imported music and library navigation, metadata/artwork.
2. Reliable playlist/queue/playback and iOS background/lock-screen controls.
3. Playlists, folder browsing, search, sorting and theme system.
4. Lyrics (embedded/LRC then optional online provider).
5. Real 10-band iOS DSP EQ, presets, headroom, and sound quality tests.
6. UI refinement, accessibility, performance, regression testing and distribution polish.

## Existing prototype limitations
Earlier prototype used picker temporary paths, a single player screen, placeholder artwork, placeholder EQ and incomplete media metadata. New code must resolve these rather than assume they are already done.

## Working rules
This is the authoritative product intent. Before implementation changes, check this file and explain meaningful scope/technical deviations. Prefer delivering complete working workflows. Build success != feature verification on device. User has requested **design consolidation before implementation**, so creation of this document is not authorization to begin implementing features immediately.
