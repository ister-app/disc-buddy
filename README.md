# disc-buddy

A Dart CLI for ripping Audio CDs, DVDs, and Blu-rays on Linux.

- **Audio CD** → FLAC, with metadata from MusicBrainz / CDDB / CD-TEXT and cover art from the Cover Art Archive
- **DVD** → lossless MKV via libdvdread (CSS decryption) or VOB concat fallback
- **Blu-ray** → lossless MKV via libbluray (AACS/BD+) or direct M2TS concat fallback

Drive detection updates in real time using `udevadm monitor` and the `CDROM_DRIVE_STATUS` ioctl.

---

## Requirements

**Runtime:**

| Tool | Purpose |
|------|---------|
| `ffmpeg` + `ffprobe` | encoding / probing |
| `lsblk`, `udevadm`, `eject` | drive detection and disc management |
| `libdvdread` (optional) | CSS decryption on encrypted DVDs |
| `libbluray` + `KEYDB.cfg` (optional) | AACS decryption on encrypted Blu-rays |
| `discid` (optional) | accurate MusicBrainz disc ID lookup |

**Build:**

- Dart SDK ≥ 3.11

Install dependencies on Fedora:

```bash
sudo dnf install ffmpeg lsblk util-linux udev libdvdread libbluray libaacs discid
# KEYDB.cfg for AACS: copy to ~/.config/aacs/KEYDB.cfg
```

---

## Build & run

```bash
dart pub get
dart run bin/rip.dart [options]
```

Or compile to a native binary:

```bash
dart compile exe bin/rip.dart -o disc-buddy
./disc-buddy [options]
```

---

## Usage

```
Usage: disc-buddy [options]

-d, --device    Optical device (e.g. /dev/sr0)   [env: DISC_DEVICE]
-o, --output    Output directory                  [env: OUTDIR, default: ./output]
    --ffmpeg    Path to ffmpeg binary             [default: ffmpeg]
    --ffprobe   Path to ffprobe binary            [default: ffprobe]
-f, --force     Overwrite existing files; skip language prompts
-h, --help      Show help
```

When `--device` is omitted, an interactive drive selection menu is shown. The menu updates in real time as discs are inserted or removed.

---

## Output layout

```
output/
  DISC_TITLE/               # DVD / Blu-ray
    title_01.mkv
    title_02.mkv
    ...
  Artist/                   # Audio CD
    Album (Year)/
      01-Track Title.flac
      02-Track Title.flac
      cover.jpg
```

---

## Disc types

### Audio CD

1. Reads the TOC via `discid` or FFI SG_IO to compute an exact MusicBrainz disc ID.
2. Looks up metadata in MusicBrainz, falls back to CDDB/GnuDB, then CD-TEXT.
3. Downloads front cover art from the Cover Art Archive (if a MusicBrainz release is found).
4. Rips selected tracks to FLAC with full metadata tags (title, artist, album, track number, MusicBrainz IDs, …).

### DVD

1. Parses `VIDEO_TS.IFO` and all `VTS_XX_0.IFO` files to enumerate titles with their duration, audio tracks (codec, channels, language), subtitle tracks, and cell ranges.
2. **Smart auto-selection** suggests titles for ripping:
   - Filters out clips shorter than 5 minutes (menus, trailers).
   - Detects series when ≥ 3 titles have similar duration (±30 % of median).
   - Otherwise selects the longest title (main feature).
3. Rips using **libdvdread** (via FFI) for CSS-encrypted discs. Falls back to VOB concat for unencrypted discs.
4. Audio and subtitle tracks are mapped in IFO order; language codes and codec titles are written as MKV metadata.

### Blu-ray

1. Parses MPLS playlist files and CLPI stream info files to enumerate titles with duration, audio, and subtitle tracks.
2. Uses the same smart auto-selection logic as DVD.
3. Rips using **libbluray** (via ffmpeg) when available. Falls back to direct M2TS concat for unencrypted discs.
4. LPCM audio tracks are transcoded to FLAC; all other tracks are stream-copied.

---

## Library API

The pure-Dart modules are exported from `package:disc_buddy/disc_buddy.dart` and can be used in Flutter apps without modification:

```dart
import 'package:disc_buddy/disc_buddy.dart';

// DVD titles
final ripper = DVDRipper(opts);
final result = await ripper.loadTitles();

// Blu-ray titles
final ripper = BlurayRipper(opts);
final result = await ripper.loadTitles();

// MusicBrainz lookup
final meta = await MusicBrainz.lookup(discId, startTimes, leadOut);

// Cover art
final bytes = await CoverArt.fetchFront(releaseMbid);
```

---

## Project layout

```
bin/
  rip.dart               Entry point; CLI argument parsing and top-level flow
lib/src/
  cli/
    menu.dart            Drive selection menu (real-time udevadm monitor)
    title_selector.dart  Auto-selection logic for DVD and Blu-ray titles
  device/
    drive_detector.dart  Lists optical drives via lsblk + udevadm
    drive_status.dart    CDROM_DRIVE_STATUS ioctl (tray open / loading / no disc)
    disc_type_detector.dart  Detects Audio CD / DVD / Blu-ray via udevadm
    cdrom_toc.dart       SG_IO READ TOC for exact MusicBrainz disc ID
    dvdread.dart         libdvdread FFI for CSS-decrypted VOB streaming
  ffmpeg/
    ffmpeg_runner.dart   Runs ffmpeg with progress tracking
  metadata/
    musicbrainz.dart     MusicBrainz Web Service v2 lookup
    cddb.dart            CDDB / GnuDB lookup (fallback)
    disc_id.dart         MusicBrainz disc ID computation
    cover_art.dart       Cover Art Archive fetch
  models/                Data classes (DriveInfo, DvdTitle, BlurayTitle, …)
  rippers/
    audiocd_ripper.dart  Audio CD → FLAC
    dvd_ripper.dart      DVD → MKV (libdvdread + VOB concat fallback)
    bluray_ripper.dart   Blu-ray → MKV (libbluray + M2TS concat fallback)
  utils/                 Shared utilities (mount, sanitize, languages, …)
```
