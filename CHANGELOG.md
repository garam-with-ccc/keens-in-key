# Changelog

## 0.3.0 — 2026-09-29

- **Collections, playlists and smart playlists.** Collections are folders (like Mixed In Key 11's "folders and nested playlists"); playlists can nest, carry an emoji label, and be reordered. Smart playlists fill themselves from rules (tags, compatible key or key list, BPM range, energy range, genre, text, sort, limit).
- **Tags for secondary classification** (rekordbox "My Tag" style): tag categories (Genre, Components, Situation, Mood by default, editable), a tag panel to tag the selected tracks, a tag filter bar (match all / any) on every list, and a tag manager.
- Drag tracks from the list onto a playlist in the sidebar, or use "Add to Playlist" in the context menu / Track menu. New Collection / Playlist / Smart Playlist commands (⇧⌘N, ⌘N, ⌥⌘N).
- Exports follow the selected playlist (CSV, rekordbox, Traktor, M3U), and all collections can be exported as one rekordbox XML or Traktor NML with the folder / playlist tree.
- **Song Info** editor in the detail panel (title, artist, album, genre) that writes the fields back to the file.
- Library file format version 2 (older libraries load unchanged).

## 0.2.0 — 2026-09-28

- **Serato DJ / Engine DJ cue points and beat grid** written into the files themselves (Serato Markers2 + BeatGrid): MP3 / AIFF / WAV (ID3 GEOB), M4A (freeform atoms) and FLAC (Vorbis comments). Enable it in Personalize.
- **Traktor collection export (.nml)** with key, tempo grid marker and hot cues; rekordbox XML hot cues now carry colours.
- Own MP4 atom writer for freeform metadata: existing Serato and other non-iTunes atoms in M4A files are preserved byte-for-byte (AVFoundation used to drop their mean/name).
- Manual corrections: set the key (Track menu or context menu), halve / double the BPM, move the downbeat by one beat in the cue editor.
- Cue editor: keys 1–8 jump to hot cues, energy curve overlay on the waveform, volume slider; cue editing moved into the core library with tests.
- `kik write --serato`, `kik export --traktor`.

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
