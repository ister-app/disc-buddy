import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../device/cdrom_toc.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../metadata/cddb.dart';
import '../metadata/cover_art.dart';
import '../metadata/disc_id.dart' show computeDiscId, computeDiscIdFromOffsets;
import '../metadata/musicbrainz.dart';
import '../models/disc_metadata.dart';
import '../models/rip_options.dart';
import 'video_disc_ripper.dart';
import '../utils/file_utils.dart';
import '../utils/progress.dart';
import '../utils/sanitize.dart';
import '../utils/udev.dart';

class AudioCDRipper {
  final RipOptions options;
  final FfmpegRunner _ffmpeg;
  final LogCallback? onLog;
  final ProgressCallback? onProgress;

  AudioCDRipper(this.options, {this.onLog, this.onProgress})
      : _ffmpeg = FfmpegRunner(executable: options.ffmpeg);

  void _log(String msg, {bool isError = false}) {
    if (onLog != null) {
      onLog!(msg, isError: isError);
    } else if (isError) {
      stderr.writeln(msg);
    } else {
      stdout.writeln(msg);
    }
  }

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

    final albumCdText  = sanitizeFilename(fmtTags['album']  ?? fmtTags['ALBUM']  ?? '');
    final artistCdText = sanitizeFilename(fmtTags['artist'] ?? fmtTags['ARTIST'] ?? '');
    final dateCdText   = ((fmtTags['date'] ?? fmtTags['DATE'] ?? '') as String).take(4);

    final titlesCdText = chapters.map((ch) {
      final tags = ch['tags'] as Map? ?? {};
      return sanitizeFilename(tags['title'] ?? tags['TITLE'] ?? '');
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
    final mb = await MusicBrainz.lookup(discId, startTimes, leadOut)
        ?? await Cddb.lookup(startTimes, leadOut);

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
  Future<void> rip(DiscMetadata meta, List<int> trackNumbers) async {
    final albumDir = p.join(options.outputDir, meta.artistDir, meta.albumDir);
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

    for (final nr in trackNumbers) {
      final idx = nr - 1;
      if (idx < 0 || idx >= meta.tracks.length) {
        _log('Invalid track: $nr', isError: true);
        continue;
      }

      final track = meta.tracks[idx];
      final filename = _trackFilename(meta, track);
      final outFile  = File(p.join(albumDir, '$filename.flac'));

      _log('── Ripping: track $nr → ${outFile.path}');

      if (!await confirmOverwrite(outFile, force: options.force)) continue;

      final trackArtist = track.artist.isNotEmpty ? track.artist : meta.albumArtist;
      final dur = track.duration;
      final timeoutDur = Duration(seconds: dur.truncate().toInt() + 30);

      final args = [
        '-loglevel', 'warning', '-stats',
        '-f', 'libcdio',
        '-ss', track.startTime.toString(),
        '-i', options.device!,
        '-t', dur.toString(),
        '-c:a', 'flac',
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
        outFile.path,
      ];

      final exitCode = await _ffmpeg.run(
        args,
        timeout: timeoutDur,
        expectedDuration: Duration(milliseconds: (dur * 1000).round()),
        onProgress: onProgress ?? logProgress,
      );
      _log('');

      if (exitCode == 0 || await outFile.exists()) {
        _log('   Done: ${outFile.path}');
      } else {
        _log('   Error ripping track $nr (exit code $exitCode).', isError: true);
        await outFile.delete().catchError((e) {
          _log('   Cannot delete file: $e', isError: true);
          return File('');
        });
      }
    }
  }

  String _trackFilename(DiscMetadata meta, TrackInfo track) {
    final nr = track.number.toString().padLeft(2, '0');
    if (meta.totalDiscs > 1 && meta.discNumber > 0) {
      final dn = meta.discNumber.toString().padLeft(2, '0');
      return '$dn-$nr-${track.title}';
    }
    return '$nr-${track.title}';
  }

  /// Fetches disc ID and corrected lead-out as a (discId, leadOut) record.
  ///
  /// Reads the TOC directly via Dart FFI (SG_IO READ TOC format 2) for an
  /// accurate session-1 lead-out — crucial for CD Extra (Blue Book), where
  /// ffprobe's end_time for the last audio track is the data-session start
  /// (including inter-session gap ≈ 152s).
  ///
  /// Order: discid tool → Dart FFI SG_IO → computed fallback.
  static Future<(String, double)> _getToc(
    String device,
    List<double> startTimes,
    double ffprobeLeadOut,
  ) async {
    double sectorsToSeconds(int sectors) => (sectors - 150) / 75.0;

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

    // Method 2: Dart FFI — full TOC with exact track sector addresses
    try {
      final toc = await readToc(device);
      if (toc != null && toc.offsets.length == startTimes.length) {
        final discId      = computeDiscIdFromOffsets(toc.offsets, toc.leadOut);
        final leadOutSecs = sectorsToSeconds(toc.leadOut);
        return (discId, leadOutSecs);
      }
    } catch (_) {}

    // Method 3: computed from ffprobe times (less accurate for CD Extra)
    return (computeDiscId(startTimes, ffprobeLeadOut), ffprobeLeadOut);
  }
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
