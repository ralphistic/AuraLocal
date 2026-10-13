# AuraLocal — authoritative project handoff and feature contract
Last updated: 2026-10-13. READ THIS FILE BEFORE EVERY CHANGE, INCLUDING NEW CHATS.
Repository: ralphistic/AuraLocal, main. iOS unsigned IPA built via .github/workflows/ios.yml; GitHub Actions run number is the build number. Release URL pattern: https://github.com/ralphistic/AuraLocal/releases/download/build-N/AuraLocal-build-N-unsigned.ipa (only works after successful CI).
## Must preserve
- Winamp-inspired warm peach/salmon, dark background, Josefin typography; no all-caps user-facing UI labels.
- Library and Now Playing are distinct screens. Tap mini-player or swipe UP on mini-player to expand; swipe DOWN on Now Playing title/header or pull down from top of player to minimize; top-left chevron is fallback. Maintain visible transition without translating the entire page permanently offscreen (historic blank/grey-screen regression).
- Player must show exactly ONE copy of artwork, scrolling long song title, playback position/duration, scrubber, shuffle, previous, play/pause, next, repeat, 10s jumps, Library, Queue, playlist and Pitch/tempo. No duplicate footer.
- Artwork flips to reveal metadata editing/search. Front/back flips should be snappy; returning to front faster than flipping to back. User-facing label is 'Add metadata?', never 'ADD METADATA?'.
- EQ: ten adjustable bands, custom presets and save/delete, responsive 48-band live spectrum driven by actual PCM output (not fake oscillator). Visual should show strong high peaks and low valleys and quick transient response; never change actual audio EQ for visual effect.
- Pitch/tempo: native AVAudioEngine -> AVAudioUnitEQ -> AVAudioUnitTimePitch; preserve real pitch/tempo, per-song or global settings. Neutral (100%, 0 cents) bypasses time-stretcher to avoid lingering grain glitches. Needs iPhone audio verification; avoid claiming glitch fixed without test.
- iOS Files imports: offer LINK originals (no copy) and copy mode, bookmarks/security scoped URLs; persist library through upgrades. Do not automatically re-add removed songs or multiply duplicates.
- Sort options alphabetical, date added, duration with reverse toggles; next/previous follows queue ordering. Playback resumes across audio route changes and lock screen where possible.
- Build number displayed in library main menu; workflow stamps auraBuildNumber with actual run number before iOS compile.
## Recent history
- Build 120 temporarily added duplicate bottom controls; 121 removed them.
- Build 122 restored marquee and AnimatedSwitcher screen transition, boosted spectrum, bypassed neutral time-stretch, stamped build number.
- Current next build: restore actual touch swipe minimize, increase spectrum peaks/valleys sensitivity, faster flip back, remove uppercase metadata label, establish this handoff.
## Verification checklist for every build
1. Read this handoff, inspect diff, keep unrelated working features.
2. Run python3 native/tests/check_bridge_contract.py and check_library_contract.py; run Flutter tests and native DSP stress tests in CI.
3. Check GitHub Actions run result and only describe IPA as downloadable after successful release. Always provide direct numbered IPA link.
4. iPhone manual verification: mini-player swipe up, Now Playing swipe down, no grey screen, scrolling title, only one control set, EQ motion, tempo reset sound, artwork flip, Files linking and version menu.
5. Keep this file updated when changes are made; future chats should read it before editing.

## Automatic change history
- 2026-10-13: Added repository-wide AGENTS.md instructions, pre-commit automatic history updates, and CI enforcement of same-commit handoff changes. Never remove these safeguards silently.
- 2026-10-13: Updated Flutter artwork regression test to expect sentence-case Add metadata? label, matching the requested UI. Do not revert the app label to uppercase just to pass tests.
- 2026-10-13: Restored interactive thumb-following vertical Now Playing dismissal using Stack plus AnimatedSlide; drag title downward or pull down from scroll top; player follows drag, then animates closed or snaps back. Mini-player moves with upward swipe. Underlying library stays rendered to avoid blank overlay. Corrected mojibake in audio format separator (use actual bullet, not misdecoded UTF-8). Preserve interactive dragging and avoid reverting to switch-only transitions. Pending iPhone gesture validation.

- 2026-10-13 09:29 UTC: Code changed in lib/main.dart. Preserve all Must preserve features. Confirm behavior and iPhone testing; review diff for regressions.
