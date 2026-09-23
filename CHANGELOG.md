# Changelog

## 0.1.1 — 2026-09-23

- Builds are now signed with a Developer ID certificate (hardened runtime), notarized by Apple and stapled: the app opens without Gatekeeper warnings
- Universal binary (Apple silicon + Intel)
- `Scripts/build-app.sh` gained `CODESIGN_IDENTITY` / `NOTARY_*` options; the Release workflow signs and notarizes when the corresponding secrets are configured

## 0.1.0 — 2026-09-23

First release.

- Key detection (Camelot / Open Key / traditional notation) with tuning estimation and selectable tone profiles
- BPM detection with beat tracking, downbeat estimation and configurable tempo range
- Energy level (1–10) and per-section energy
- Automatic cue points quantized to the beat grid, with an editor (add, drag, nudge, re-quantize)
- Interactive Camelot wheel with harmonic mixing suggestions from your library
- Tag writing for MP3, AIFF, WAV (ID3v2.3/2.4), FLAC (Vorbis comments) and M4A/AAC (iTunes atoms)
- Personalize: notation, comment / grouping / title / file-name formats, automatic writing
- CSV, rekordbox XML and M3U export
- `kik` command-line tool
