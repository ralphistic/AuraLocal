# AuraLocal bug and polish tracker

Reported 2026-10-15. Recorded only; do not implement without user approval. Build unspecified.

- [ ] Artwork flip clipping: When a track has no artwork, tapping the placeholder to flip it in the full player clips the top of the flip animation slightly along a horizontal line, as though behind an invisible header.
- [ ] Player gesture easing: Full player drag down and MiniPlayer drag up are too snappy. Ramp and smooth motion/easing while preserving reliable gestures.
- [ ] Repeat icon labels: Remove text and numbers underneath. Exactly three icon-only states: off, on, and on with a number 1 inside the icon.
- [ ] Repeat icon shape/color: Circular button, not rounded square. Enabled color must match the actual Google green in the user's design reference, not an eyedropper sample of the screenshot. Verify hex value before implementation.
- [ ] Information dialog typography: i-button information menu text is too small and thin. Make appropriately larger/chunkier with varied hierarchy and weights, not uniformly bold.
- [ ] Search bar vertical spacing: Search field remains unevenly spaced between header and tracklist. Balance gaps.

## Separate active defect
- [ ] Last-track collapse: Castle Boss Battle SMW Remaster without metadata causes disappearing tracklist and misplaced waveform after player collapse; blank-screen tap reopens player. Adding metadata resolves and undoing recreates. Confirmed on Build 183; Builds 188 and 189 tested: no change. New experiment keeps artist row present for untagged files to avoid metadata-dependent player geometry.




