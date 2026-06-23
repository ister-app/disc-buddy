# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project structure

Three packages in a Dart workspace:

| Package | Path | Role |
|---------|------|------|
| `disc_buddy` | `disc_buddy_lib/` | Pure Dart library (usable in Flutter) |
| `disc_buddy_cli` | `disc_buddy_cli/` | CLI binary; depends on `disc_buddy` |
| `disc_buddy_ui` | `disc_buddy_ui/` | Flutter GUI; depends on `disc_buddy` (outside workspace) |

Dependency rules: `cli` and `ui` may depend on `lib`; they must not depend on each other; `lib` must not depend on `cli` or `ui`.

## Commands

```bash
# Install dependencies (workspace root — resolves all packages)
dart pub get

# Run the CLI
dart run disc_buddy_cli/bin/rip.dart [options]

# Compile to native binary
dart compile exe disc_buddy_cli/bin/rip.dart -o disc-buddy

# Run tests
dart test disc_buddy_lib/

# Analyze (CI uses --fatal-infos)
dart analyze --fatal-infos disc_buddy_lib disc_buddy_cli
```

## Architecture

`disc_buddy_cli/bin/rip.dart` is the CLI entry point. It rips Audio CDs, DVDs, and Blu-rays on Linux. The public library API is exported from `disc_buddy_lib/lib/disc_buddy.dart`.

### Input modes

- **Drive** (`--device /dev/sr0` or interactive menu): detects disc type, dispatches to the right ripper.
- **ISO image** (`-i disc.iso`): mounts temporarily, same disc-type detection and ripping flow.
- **Standalone MKV** (`-i video.mkv`): skips disc detection entirely; prompts for subtitle extraction and/or rename (manual or LLM auto-naming). No ripping phase.

### Flow

1. `disc_buddy_cli/bin/rip.dart` parses CLI args and selects the input source. A `.mkv` path via `-i` is handled as a standalone MKV; anything else goes through disc-type detection.
2. Each disc ripper has two phases: `loadTitles()` (scan/parse disc metadata) then `rip()` (invoke ffmpeg).
3. After ripping, `_resolveSubtitlesAndNames` handles optional subtitle extraction and LLM-based auto-naming for all disc types (DVD, Blu-ray).
4. `--force` flag skips all interactive prompts and auto-selects titles.

### Disc type handling

- **Audio CD**: TOC read via `discid` binary or `SG_IO` FFI ioctl → MusicBrainz disc ID → metadata lookup (MusicBrainz → CDDB → CD-TEXT) → FLAC via ffmpeg.
- **DVD**: Parses `VIDEO_TS.IFO` and `VTS_XX_0.IFO` files directly in Dart (no external tool). Two-pass VOB scan: first pass finds MPEG-PS private stream sub-IDs (`_scanVobSids`) to determine correct ffmpeg `-map` ordering; second pass rips. Prefers `libdvdread` FFI for CSS; falls back to VOB concat.
- **Blu-ray**: Parses MPLS playlist and CLPI stream info files. Rips via libbluray (through ffmpeg's `bluray:` protocol) or M2TS concat fallback. LPCM audio is transcoded to FLAC; everything else is stream-copied.

### Title auto-selection (`disc_buddy_lib/lib/src/cli/title_selector.dart`)

Shared logic for both DVD and Blu-ray: filters clips < 5 min, deduplicates by duration (±5 s keeping the track with most streams), detects series if ≥ 3 titles within ±30% of median duration, otherwise picks the longest title.

### TTY input (`disc_buddy_lib/lib/src/utils/tty.dart`)

`ttyReadLine()` and `ttyConfirm()` are shared between lib and CLI. Exported via `package:disc_buddy/tty.dart`. The CLI's `Menu` class delegates to these functions.

### FFI usage

- `disc_buddy_lib/lib/src/device/dvdread.dart`: loads `libdvdread.so` at runtime (tries `.so.8`, `.so.4`, plain `.so`). `dvdreadAvailable` is a top-level bool checked before using CSS decryption. stderr is suppressed during `DVDOpen` by redirecting fd 2 via libc `dup`/`dup2`.
- `disc_buddy_lib/lib/src/device/cdrom_toc.dart`: uses `SG_IO` ioctl via `dart:ffi` for TOC reading.
- `disc_buddy_lib/lib/src/device/drive_status.dart`: `CDROM_DRIVE_STATUS` ioctl.

### Drive detection

`disc_buddy_lib/lib/src/device/drive_detector.dart` lists drives via `lsblk`. `disc_buddy_cli/lib/src/cli/menu.dart` shows a real-time interactive drive selection menu backed by `udevadm monitor`.

### Auto-naming (`disc_buddy_lib/lib/src/naming/`)

Triggered by `'?'` in naming prefs (disc rippers) or the `?` answer in standalone MKV mode.

1. `AutoNamer.nameFile` extracts a subtitle excerpt (first 6 000 chars + 4 000 chars from the ⅓ mark) and asks the LLM to identify the content.
2. For movies: `TmdbClient.searchMovie` → `"Title (Year)"` stem.
3. For series: `TmdbClient.getAllEpisodes` fetches all seasons (cached 7 days in `$XDG_CACHE_HOME/disc-buddy/`), then the LLM matches the subtitle to a season+episode → `"s##e##"` stem.
4. `LlmClient` calls any OpenAI-compatible API (temperature 0.1).

### Key models

- `RipOptions` — device path (null for standalone MKV), output dir, ffmpeg/ffprobe paths, force flag, optional subtitle-tool paths and LLM/TMDB credentials.
- `DvdTitle` — VTS number, PGC index (= angle), duration, audio/subtitle tracks with MPEG stream IDs, cell ranges.
- `BlurayTitle` — index, playlist name, duration, audio/subtitle counts.
- `DiscMetadata` + `TrackInfo` — Audio CD metadata (artist, album, tracks with MusicBrainz IDs).

### DVD stream mapping detail

DVDs store audio at MPEG sub-stream IDs `0x80–0x8F` and subtitles at `0x20–0x3F`. The IFO file specifies which sub-stream ID each track uses per PGC. The two-pass scan (`_scanVobSids`) determines the ffmpeg discovery order of these sub-IDs, which is then used to build explicit `-map 0:a:N` / `-map 0:s:N?` arguments in IFO order, with `-metadata:s:a:N` indices matching the output (IFO) order, not the discovery order.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on every push: `dart pub get` (workspace root) → `dart analyze --fatal-infos` (lib + cli) → `dart test` (lib) → `dart compile exe`. Tags matching `v*` trigger a GitHub release with the compiled binary attached.
