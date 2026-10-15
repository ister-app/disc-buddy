import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../device/cdda_reader.dart';
import '../device/cdrom_toc.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../metadata/cddb.dart';
import '../metadata/cover_art.dart';
import '../metadata/disc_id.dart' show computeDiscId, computeDiscIdFromOffsets;
import '../metadata/musicbrainz.dart';
import '../models/disc_metadata.dart';
import '../models/rip_options.dart';
import '../utils/file_utils.dart';
import '../utils/log.dart';
import '../utils/prompter.dart';
import '../utils/progress.dart';
import '../utils/sanitize.dart';
import '../utils/udev.dart';

/// Output path of [track] exactly as [AudioCDRipper.rip] will create it.
/// Lets a UI check for existing files before starting a rip.
String audioTrackOutputPath(String outputDir, DiscMetadata meta, TrackInfo track) {
  final albumDir = p.join(outputDir,
      sanitizeFilename(meta.artistDir), sanitizeFilename(meta.albumDir));
  final nr = track.number.toString().padLeft(2, '0');
  final stem = meta.totalDiscs > 1 && meta.discNumber > 0
      ? '${meta.discNumber.toString().padLeft(2, '0')}-$nr-${track.title}'
      : '$nr-${track.title}';
  return p.join(albumDir, '${sanitizeFilename(stem)}.flac');
}

class AudioCDRipper {
  final RipOptions options;
  final FfmpegRunner _ffmpeg;
  final LogCallback? onLog;
  final ProgressCallback? onProgress;

  /// Per-track LBAs + lead-out from the FFI TOC read, when available.
  /// Enables the direct SG_IO rip path in [rip].
  ({List<int> offsets, int leadOut})? _fullToc;

  /// Asks about overwrites. `force` always wins: with `options.force` set
  /// every question is answered with its default.
  final Prompter _prompter;

  AudioCDRipper(this.options, {this.onLog, this.onProgress, Prompter? prompter})
      : _ffmpeg = FfmpegRunner(executable: options.ffmpeg, onLog: onLog),
        _prompter = options.force
            ? const NonInteractivePrompter()
            : (prompter ?? const NonInteractivePrompter());

  void _log(String msg, {bool isError = false}) =>
      emitLog(onLog, msg, isError: isError);

  /// Loads metadata from the disc (CD-TEXT + optionally MusicBrainz).
  Future<DiscMetadata?> loadMetadata() async {
    final result = await Process.run(options.ffprobe, [
      '-f', 'libcdio',
      '-i', options.device!,
      '-show_format',
      '-show_chapters',
      '-of', 'json',
      '-loglevel', 'error',
    ]);

    Map<String, dynamic> probe;
    try {
      probe = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    } catch (_) {
      _log('Error: ffprobe could not read the disc.', isError: true);
      return null;
    }

    var chapters = (probe['chapters'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (chapters.isEmpty) {
      _log('Error: no tracks found on the disc.', isError: true);
      return null;
    }

    // CD Extra / Enhanced CD has an extra data track at the end.
    // Limit chapters to audio tracks only via udevadm.
    final udev = await Process.run(
      'udevadm', ['info', '--query=property', '--name=${options.device}'],
    );
    final udevProps = parseUdevProps(udev.stdout as String);
    final audioTrackCount =
        int.tryParse(udevProps['ID_CDROM_MEDIA_TRACK_COUNT_AUDIO'] ?? '') ?? 0;
    if (audioTrackCount > 0 && audioTrackCount < chapters.length) {
      chapters = chapters.sublist(0, audioTrackCount);
    }

    final fmtTags = (probe['format'] as Map?)?['tags'] as Map? ?? {};

    final albumCdText  = ((fmtTags['album']  ?? fmtTags['ALBUM']  ?? '') as String).trim();
    final artistCdText = ((fmtTags['artist'] ?? fmtTags['ARTIST'] ?? '') as String).trim();
    final dateCdText   = ((fmtTags['date'] ?? fmtTags['DATE'] ?? '') as String).take(4);

    final titlesCdText = chapters.map((ch) {
      final tags = ch['tags'] as Map? ?? {};
      return ((tags['title'] ?? tags['TITLE'] ?? '') as String).trim();
    }).toList();

    final startTimes = chapters
        .map((ch) => double.tryParse(ch['start_time']?.toString() ?? '') ?? 0.0)
        .toList();
    final endTimesRaw = chapters
        .map((ch) => double.tryParse(ch['end_time']?.toString() ?? '') ?? 0.0)
        .toList();

    // Fetch disc ID + corrected lead-out via system tool if available.
    // Necessary for CD Extra: ffprobe's end_time for the last audio track
    // is the start of the data session (including inter-session gap ≈ 152s),
    // causing an incorrect disc ID and wrong duration for the last track.
    final toc = await _getToc(options.device!, startTimes, endTimesRaw.last);
    final discId  = toc.$1;
    final leadOut = toc.$2;   // corrected lead-out (in seconds)

    if (discId.isEmpty || leadOut <= 0) {
      _log('Warning: disc ID or lead-out is invalid '
          '(discId="$discId", leadOut=$leadOut) — metadata lookup may fail.', isError: true);
    }

    // Correct the end_time of the last audio track if lead-out was adjusted
    final endTimes = List<double>.from(endTimesRaw);
    if (endTimes.isNotEmpty) endTimes[endTimes.length - 1] = leadOut;

    final hasAlbum = albumCdText.isNotEmpty;

    // Try MusicBrainz first; fall back to CDDB/GnuDB on failure.
    final mb = await MusicBrainz.lookup(discId, startTimes, leadOut, onLog: onLog)
        ?? await Cddb.lookup(startTimes, leadOut, onLog: onLog);

    if (mb != null) {
      // MusicBrainz takes priority; CD-TEXT is used as fallback for missing fields.
      final mergedTracks = List.generate(chapters.length, (i) {
        final mbTrack = i < mb.tracks.length ? mb.tracks[i] : null;
        final cdTitle = i < titlesCdText.length ? titlesCdText[i] : '';
        return TrackInfo(
          number: i + 1,
          title: mbTrack?.title.isNotEmpty == true
              ? mbTrack!.title
              : (cdTitle.isNotEmpty ? cdTitle : 'track_${(i + 1).toString().padLeft(2, '0')}'),
          artist: mbTrack?.artist ?? '',
          artistMbid: mbTrack?.artistMbid ?? '',
          recordingMbid: mbTrack?.recordingMbid ?? '',
          startTime: startTimes[i],
          endTime: endTimes[i],
        );
      });

      return DiscMetadata(
        album: mb.album.isNotEmpty ? mb.album : (hasAlbum ? albumCdText : 'Unknown album'),
        artist: mb.artist.isNotEmpty ? mb.artist : artistCdText,
        artistMbid: mb.artistMbid,
        date: mb.date.isNotEmpty ? mb.date : dateCdText,
        releaseMbid: mb.releaseMbid,
        label: mb.label,
        catalogNumber: mb.catalogNumber,
        discNumber: mb.discNumber,
        totalDiscs: mb.totalDiscs,
        tracks: mergedTracks,
      );
    }

    // CD-TEXT only (or default track names as fallback)
    final tracks = List.generate(chapters.length, (i) {
      final title = i < titlesCdText.length && titlesCdText[i].isNotEmpty
          ? titlesCdText[i]
          : 'track_${(i + 1).toString().padLeft(2, '0')}';
      return TrackInfo(
        number: i + 1,
        title: title,
        artist: '',
        artistMbid: '',
        recordingMbid: '',
        startTime: startTimes[i],
        endTime: endTimes[i],
      );
    });

    return DiscMetadata(
      album: hasAlbum ? albumCdText : 'Unknown album',
      artist: artistCdText,
      date: dateCdText,
      tracks: tracks,
    );
  }

  /// Rips the given tracks to FLAC files.
  ///
  /// [overwrite] — when non-null, existing output files whose path is in the
  /// set are deleted and re-ripped; other existing files are skipped without
  /// prompting. When null, existing behavior applies ([confirmOverwrite]:
  /// force deletes, interactive TTY asks per file, UI skips).
  Future<void> rip(
    DiscMetadata meta,
    List<int> trackNumbers, {
    Set<String>? overwrite,
  }) async {
    final albumDir = p.join(options.outputDir,
        sanitizeFilename(meta.artistDir), sanitizeFilename(meta.albumDir));
    await Directory(albumDir).create(recursive: true);

    // Fetch cover art
    if (meta.releaseMbid.isNotEmpty) {
      final coverFile = File(p.join(albumDir, 'cover.jpg'));
      if (!await coverFile.exists()) {
        _log('Downloading cover art...');
        final bytes = await CoverArt.fetchFront(meta.releaseMbid);
        if (bytes != null) {
          await coverFile.writeAsBytes(bytes);
          _log('Cover saved: ${coverFile.path}');
        } else {
          _log('No cover art found.');
        }
      }
    }

    // The UI loads metadata and rips with separate AudioCDRipper instances,
    // so the TOC from loadMetadata may not be present here — read it now.
    if (_fullToc == null) {
      try {
        final t = await readToc(options.device!);
        if (t != null && t.offsets.length == meta.tracks.length) {
          _fullToc = (offsets: t.offsets, leadOut: t.leadOut);
        }
      } catch (_) {}
    }

    // Prefer direct SG_IO sector reads piped into ffmpeg: the stream ends
    // exactly at the track boundary, so ffmpeg exits on its own (no libcdio
    // hang after the last track, no kill timers). The reads run in their own
    // isolate — SG_IO is a blocking ioctl that would freeze a Flutter UI.
    // Falls back to libcdio when the TOC or the drive won't cooperate.
    final toc = _fullToc;
    IsolateCddaReader? reader;
    if (toc != null && trackNumbers.isNotEmpty) {
      reader = await IsolateCddaReader.open(options.device!);
      if (reader != null) {
        final probeIdx = trackNumbers.first - 1;
        if (probeIdx < 0 ||
            probeIdx >= toc.offsets.length ||
            await reader.readSectors(
                  trackSectorRange(
                    offsets: toc.offsets,
                    leadOut: toc.leadOut,
                    trackIndex: probeIdx,
                  ).startLba,
                  1,
                ) ==
                null) {
          reader.close();
          reader = null;
        }
      }
      if (reader == null) {
        _log('Warning: direct CDDA read unavailable — falling back to libcdio.',
            isError: true);
      }
    }

    try {
      for (final nr in trackNumbers) {
        final idx = nr - 1;
        if (idx < 0 || idx >= meta.tracks.length) {
          _log('Invalid track: $nr', isError: true);
          continue;
        }

        final track = meta.tracks[idx];
        final outFile = File(audioTrackOutputPath(options.outputDir, meta, track));

        _log('── Ripping: track $nr → ${outFile.path}');

        if (!await confirmOverwrite(outFile,
            force: options.force, onLog: onLog, overwrite: overwrite, prompter: _prompter)) {
          continue;
        }

        final trackArtist = track.artist.isNotEmpty ? track.artist : meta.albumArtist;

        if (reader != null && toc != null) {
          await _ripTrackCdda(reader, toc, meta, track, outFile, trackArtist);
        } else {
          await _ripTrackLibcdio(meta, track, outFile, trackArtist);
        }
      }
    } finally {
      reader?.close();
    }
  }

  List<String> _metadataArgs(DiscMetadata meta, TrackInfo track, String trackArtist) => [
    '-metadata', 'title=${track.title}',
    '-metadata', 'album=${meta.album}',
    '-metadata', 'artist=$trackArtist',
    '-metadata', 'album_artist=${meta.albumArtist}',
    '-metadata', 'tracknumber=${track.number}',
    '-metadata', 'tracktotal=${meta.tracks.length}',
    if (meta.discNumber > 0) ...[ '-metadata', 'discnumber=${meta.discNumber}' ],
    if (meta.totalDiscs > 1) ...[ '-metadata', 'disctotal=${meta.totalDiscs}' ],
    if (meta.date.isNotEmpty)          ...[ '-metadata', 'date=${meta.date}' ],
    if (meta.label.isNotEmpty)         ...[ '-metadata', 'label=${meta.label}' ],
    if (meta.catalogNumber.isNotEmpty) ...[ '-metadata', 'catalognumber=${meta.catalogNumber}' ],
    if (meta.releaseMbid.isNotEmpty)   ...[ '-metadata', 'MUSICBRAINZ_ALBUMID=${meta.releaseMbid}' ],
    if (track.recordingMbid.isNotEmpty)...[ '-metadata', 'MUSICBRAINZ_TRACKID=${track.recordingMbid}' ],
    if (meta.artistMbid.isNotEmpty)    ...[ '-metadata', 'MUSICBRAINZ_ALBUMARTISTID=${meta.artistMbid}' ],
    if (track.artistMbid.isNotEmpty)   ...[ '-metadata', 'MUSICBRAINZ_ARTISTID=${track.artistMbid}' ],
  ];

  Future<void> _deletePartial(File outFile) async {
    if (await outFile.exists()) {
      await outFile.delete().catchError((e) {
        _log('   Cannot delete file: $e', isError: true);
        return File('');
      });
    }
  }

  /// Rips one track by reading its exact sector range via SG_IO and piping
  /// raw PCM into ffmpeg stdin. ffmpeg exits normally when the stream closes;
  /// success requires exit 0 and the full expected byte count.
  Future<void> _ripTrackCdda(
    IsolateCddaReader reader,
    ({List<int> offsets, int leadOut}) toc,
    DiscMetadata meta,
    TrackInfo track,
    File outFile,
    String trackArtist,
  ) async {
    final range = trackSectorRange(
      offsets: toc.offsets,
      leadOut: toc.leadOut,
      trackIndex: track.number - 1,
    );
    final expectedBytes = range.sectorCount * kCddaSectorSize;

    CddaReadException? producerError;
    var bytesPiped = 0;
    final progressCb = onProgress ?? logProgress;
    final wallClock  = Stopwatch()..start();
    var lastEmit = Duration.zero;

    void emitProgress(int bytes, {bool force = false}) {
      if (!force && wallClock.elapsed - lastEmit < const Duration(milliseconds: 250)) {
        return;
      }
      lastEmit = wallClock.elapsed;
      final audioMs = bytes * 1000 ~/ (kCddaSectorSize * kCddaSectorsPerSecond);
      final wallMs  = wallClock.elapsedMilliseconds;
      progressCb(FfmpegProgress(
        Duration(milliseconds: audioMs),
        wallMs > 0 ? audioMs / wallMs : 0.0,
      ));
    }

    Stream<Uint8List> producer() async* {
      try {
        yield* cddaSectorStream(
          startLba: range.startLba,
          sectorCount: range.sectorCount,
          read: reader.readSectors,
          onBytes: (b) {
            bytesPiped = b;
            emitProgress(b);
          },
        );
      } on CddaReadException catch (e) {
        // Close the stream cleanly so ffmpeg finishes; the byte-count check
        // below fails the track.
        producerError = e;
      }
    }

    final args = [
      '-loglevel', 'repeat+level+warning',
      '-f', 's16le', '-ar', '44100', '-ac', '2', '-i', 'pipe:0',
      '-c:a', 'flac',
      ..._metadataArgs(meta, track, trackArtist),
      outFile.path,
    ];

    final exitCode = await _ffmpeg.run(args, stdinData: producer());
    emitProgress(bytesPiped, force: true);
    _log('');

    if (exitCode == 0 && producerError == null && bytesPiped == expectedBytes) {
      _log('   Done: ${outFile.path}');
    } else {
      final detail = producerError?.toString() ??
          'exit code $exitCode, piped $bytesPiped of $expectedBytes bytes';
      _log('   Error ripping track ${track.number} ($detail).', isError: true);
      await _deletePartial(outFile);
    }
  }

  /// Fallback rip via ffmpeg's libcdio input. libcdio hangs after the last
  /// track, so the runner kills ffmpeg once progress reaches the expected
  /// duration and success is judged by a progress heuristic.
  Future<void> _ripTrackLibcdio(
    DiscMetadata meta,
    TrackInfo track,
    File outFile,
    String trackArtist,
  ) async {
    final dur = track.duration;
    final timeoutDur = Duration(seconds: dur.truncate().toInt() + 30);

    final args = [
      '-loglevel', 'repeat+level+warning', '-stats',
      '-f', 'libcdio',
      '-ss', track.startTime.toString(),
      '-i', options.device!,
      '-t', dur.toString(),
      '-c:a', 'flac',
      ..._metadataArgs(meta, track, trackArtist),
      outFile.path,
    ];

    final expectedDur = Duration(milliseconds: (dur * 1000).round());

    // Track the furthest progress ffmpeg reported. The runner SIGTERMs ffmpeg
    // on purpose once all audio is written (to stop libcdio hanging), so a
    // successful rip normally exits non-zero. We therefore can't trust the
    // exit code alone; instead we confirm ffmpeg actually reached the end of
    // the track. A real read error exits early, well short of expectedDur.
    var lastElapsed = Duration.zero;
    final progressCb = onProgress ?? logProgress;
    final exitCode = await _ffmpeg.run(
      args,
      timeout: timeoutDur,
      expectedDuration: expectedDur,
      onProgress: (p) {
        lastElapsed = p.elapsed;
        progressCb(p);
      },
    );
    _log('');

    // 98% tolerance covers the ~last-frame the completion-kill trims.
    final reachedEnd = lastElapsed.inMilliseconds >= expectedDur.inMilliseconds * 0.98;
    if (exitCode == 0 || (await outFile.exists() && reachedEnd)) {
      _log('   Done: ${outFile.path}');
    } else {
      _log('   Error ripping track ${track.number} (exit code $exitCode, '
          'reached ${lastElapsed.inSeconds}s of ${expectedDur.inSeconds}s).', isError: true);
      await _deletePartial(outFile);
    }
  }

  /// Fetches disc ID and corrected lead-out as a (discId, leadOut) record.
  ///
  /// Reads the TOC directly via Dart FFI (SG_IO READ TOC format 2) for an
  /// accurate session-1 lead-out — crucial for CD Extra (Blue Book), where
  /// ffprobe's end_time for the last audio track is the data-session start
  /// (including inter-session gap ≈ 152s).
  ///
  /// Order: discid tool → Dart FFI SG_IO → computed fallback.
  Future<(String, double)> _getToc(
    String device,
    List<double> startTimes,
    double ffprobeLeadOut,
  ) async {
    double sectorsToSeconds(int sectors) => (sectors - 150) / 75.0;

    // Always read the full TOC via FFI first: its per-track LBAs enable the
    // direct SG_IO rip path, regardless of which method supplies the disc ID.
    try {
      final toc = await readToc(device);
      if (toc != null && toc.offsets.length == startTimes.length) {
        _fullToc = (offsets: toc.offsets, leadOut: toc.leadOut);
      }
    } catch (_) {}

    // Method 1: discid tool (libdiscid-utils), if installed
    try {
      final r = await Process.run('discid', [device]);
      final lines = (r.stdout as String).trim().split('\n');
      if (r.exitCode == 0 && lines.length >= 2) {
        final id      = lines[0].trim();
        final sectors = int.tryParse(lines[1].trim());
        if (id.isNotEmpty && sectors != null && sectors > 150) {
          return (id, sectorsToSeconds(sectors));
        }
      }
    } catch (_) {}

    // Method 2: the FFI TOC read above — exact track sector addresses
    final full = _fullToc;
    if (full != null) {
      final discId      = computeDiscIdFromOffsets(full.offsets, full.leadOut);
      final leadOutSecs = sectorsToSeconds(full.leadOut);
      return (discId, leadOutSecs);
    }

    // Method 3: computed from ffprobe times (less accurate for CD Extra)
    return (computeDiscId(startTimes, ffprobeLeadOut), ffprobeLeadOut);
  }
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
