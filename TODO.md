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

## UI

- Auto-naming questions (candidate ties, manual episode pick) now open a
  dialog (`DialogPrompter`), except in loop mode. Not yet verified against
  a real LLM tie. Questions asked inside the rip isolate (track-language
  fixes) still take their default; the title panel's per-track language
  overrides cover that case.
- Rename individual audio/subtitle stream titles per title.
- Disc-page skeleton should mirror the real page layout.
