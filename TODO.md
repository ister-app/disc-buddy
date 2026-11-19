# TODO

Open points only. Everything that was in the old `todo.md` / `todofrontend.md`
and is implemented (SRT extraction, manual and LLM auto-naming, guest stars
in episode matching, the lib/cli/ui split, the Flutter front end with
directory support, eject of virtual entries, auto-name checkbox, per-title
audio/subtitle selection, subtitle export, dependency warnings, Victorious
closed captions, Seinfeld S7 auto-selection) has been removed.

## Verify on real discs

- **Scratched Seinfeld S4D1 / S8D1.** The dvdread path now retries,
  bisects and zero-fills unreadable sectors (`device/resilient_read.dart`)
  and warns when the output is shorter than the title. Rip
  `~/ister/SEINFELD_S4_D1.iso` and compare the duration with the MakeMKV
  output (`~/Video's/dvd1/Seinfeld - Season 4 (Disc 1)-B1_t02.mkv`) via
  `ffprobe`. Tune `DVDRipper.kMaxBadSectorsPerTitle` if the cap is hit.

## CLI

- Scanning speed: the libdvdread path reads each title twice (scan + rip)
  unless `--dvd-single-pass` is used; the CC fallback re-reads the title a
  third time when the tee is abandoned.

## Review findings left open (2026-11-19)

Reported by a code review, judged plausible, deliberately not changed
because they touch behaviour tuned on real discs or cannot be checked
without one:

- **Completion kill counts as failure for video.** `FfmpegRunner` SIGTERMs
  ffmpeg 3 s after progress reaches the title duration; ffmpeg then exits
  255 and the DVD/Blu-ray rippers delete the output. Only the libcdio audio
  path tolerates that. Bites when a source runs past its metadata duration
  (e.g. the Blu-ray M2TS fallback, which ignores playlist IN/OUT times).
  Accepting the kill would trade a loud failure for a possibly truncated
  file, so it needs a disc that shows it.
- **VOB-concat fallback ignores a title's cells** (no libdvdread): every
  title of a multi-title VTS starts at the VTS start. It now warns; a real
  fix streams the cell ranges like the dvdread path does.
- **CC timing with interleaved `FE`/`FF` triples** (`cc_extractor.dart`
  `_flushGop`): kept pairs are placed by their index among kept pairs, not
  by their triple slot; captions late in a GOP could be up to ~0.25 s
  early on discs with that layout.
- **Ctrl+C in the CLI**: the SIGINT handler cannot run while a prompt
  blocks in a synchronous TTY read, and the timed `exit(130)` skips the ISO
  unmount. Not reproduced (needs a TTY).
- **UI loop mode with an unchanged volume label**: the second disc's titles
  are skipped as "already exists" (no longer overwritten); loop mode has no
  per-disc naming unless auto-naming is on.
- A cancelled UI rip does not close its libdvdread session (the isolate is
  killed), leaking a file descriptor per cancel.

## Library

- A second subtitle track in the same language is not written as a
  sidecar: `<stem>.<lang>.srt` already exists by then (the track itself
  stays in the MKV). Numbering it would need care on NTSC discs, where the
  embedded closed-caption track would become a duplicate of the CC `.srt`.

## UI

- Auto-naming questions (candidate ties, manual episode pick) now open a
  dialog (`DialogPrompter`), except in loop mode. Not yet verified against
  a real LLM tie. Questions asked inside the rip isolate (track-language
  fixes) still take their default; the title panel's per-track language
  overrides cover that case.
- "Two stories per file" (directory mode) mirrors the CLI's
  `--split-stories` but has not been run against a real LLM/TMDB batch
  from the UI yet.
- Rename individual audio/subtitle stream titles per title.
- Disc-page skeleton should mirror the real page layout.
