import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../device/dvdread.dart' show DVDSession, dvdreadAvailable, ReadStats, DvdReadException;
import '../utils/duration_ext.dart';
import 'rip_report.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models/dvd_title.dart';
import '../models/rip_options.dart';
import 'dvd_ifo.dart';
import 'dvd_stream_map.dart';
import 'video_disc_ripper.dart';
import '../utils/atomic_output.dart';
import '../utils/file_utils.dart';
import '../utils/log.dart';
import '../utils/prompter.dart';
import '../utils/languages.dart';
import '../utils/mount.dart';
import '../utils/progress.dart';
import '../subtitles/cc_extractor.dart';
import '../subtitles/cc_format.dart' show stripMkvCcUserData;
import '../utils/sanitize.dart';

class DVDRipper implements VideoDiscRipper<DvdTitle> {
  final RipOptions options;
  final FfmpegRunner _ffmpeg;
  final LogCallback? onLog;
  final ProgressCallback? onProgress;

  /// Set once a single-pass (map-by-id) attempt fails verification, so the rest
  /// of this disc's titles skip straight to the proven two-pass scan.
  bool _singlePassDisabled = false;

  /// Unreadable sectors tolerated per title before the rip is abandoned.
  /// 4096 sectors = 8 MiB ≈ 10-15 s of DVD video: enough to get past a
  /// scratch, little enough that a hopeless disc fails fast.
  static const int kMaxBadSectorsPerTitle = 4096;

  /// One entry per title that produced a file, in rip order. Lets the caller
  /// warn about zero-filled sectors or a too-short output after [rip].
  final List<TitleRipReport> reports = [];

  /// Asks about languages and overwrites. `force` always wins: with
  /// `options.force` set every question is answered with its default.
  final Prompter _prompter;

  DVDRipper(this.options,
      {this.onLog,
      this.onProgress,
      Prompter? prompter,
      void Function(Process)? onFfmpegProcess})
      : _ffmpeg = FfmpegRunner(
            executable: options.ffmpeg,
            onProcessStarted: onFfmpegProcess,
            onLog: onLog),
        _prompter = options.force
            ? const NonInteractivePrompter()
            : (prompter ?? const NonInteractivePrompter());

  /// All IFO-declared audio and subtitle stream ids per title (keyed by
  /// [DvdTitle.displayKey]), captured in [rip] before track filtering.
  final Map<String, Set<int>> _scanSidsByTitle = {};

  static Set<int> _declaredSids(DvdTitle t) => <int>{
        ...t.audioTracks.map((a) => a.streamId),
        ...t.subtitleTracks.map((s) => s.streamId),
      };

  /// Stream ids the SID pre-scan has to find for [title]: the full IFO set
  /// when known, otherwise whatever the (possibly filtered) title lists.
  Set<int> _scanSidsFor(DvdTitle title) =>
      _scanSidsByTitle[title.displayKey] ?? _declaredSids(title);

  static List<T> _filterByLang<T>(
      List<T> tracks, Set<String> langs, String Function(T) getLang) {
    final filtered = tracks
        .where((t) => langs.any((l) => l.toLowerCase() == getLang(t).toLowerCase()))
        .toList();
    return filtered.isEmpty ? tracks : filtered;
  }

  void _log(String msg, {bool isError = false}) =>
      emitLog(onLog, msg, isError: isError);

  /// Scans the DVD via the IFO parser.
  /// Returns null on error.
  /// [titles] is sorted by VTS number + PGC index.
  ///
  /// If [mountPath] is provided the disc is assumed to be already mounted there
  /// and no additional mount/unmount cycle is performed.
  @override
  Future<({String discTitle, List<DvdTitle> titles})?> loadTitles(
      {String? mountPath}) async {
    if (mountPath != null) return _scanMounted(mountPath, mountPath);
    return withMountedDisc(
      options.device!,
      (mp) => _scanMounted(mp, mp),
      errorContext: 'DVD',
      onLog: onLog,
    );
  }

  /// Rips the selected titles as lossless MKV.
  /// If libdvdread is available (+ libdvdcss for CSS discs): uses
  /// DVDReadBlocks via pipe → ffmpeg stdin (encrypted or not).
  /// Otherwise: VOB concat fallback (only for unencrypted discs).
  ///
  /// If [mountPath] is provided the disc is assumed to be already mounted there
  /// (used by the VOB concat path only; dvdread uses the device directly).
  @override
  Future<void> rip(String discTitle, List<DvdTitle> selected,
      {String? mountPath, Set<String>? overwrite}) async {
    final device = options.device!;

    // Remember every IFO-declared stream id per title BEFORE any track
    // filtering.  The SID pre-scan must see all of them: ffmpeg numbers its
    // audio/subtitle streams by discovery order over every stream in the VOB,
    // so scanning only for the tracks the user kept yields wrong indices
    // (e.g. keeping just the German 0x82 on a disc laid out 0x80 en, 0x81 fr,
    // 0x82 de would map "-map 0:a:0", the English track, and tag it German).
    _scanSidsByTitle
      ..clear()
      ..addEntries(selected.map((t) => MapEntry(t.displayKey, _declaredSids(t))));

    // Apply per-title track filtering (by index, then by language as fallback).
    final audioLangFilter = options.audioMkvLangs;
    final subLangFilter   = options.subtitleMkvLangs;
    if (options.audioTrackIndices != null || options.subtitleTrackIndices != null ||
        audioLangFilter != null || subLangFilter != null) {
      selected = selected.map((t) {
        final audioTracks = options.audioTrackIndices != null
            ? t.audioTracks.where((a) => options.audioTrackIndices!.contains(a.index)).toList()
            : audioLangFilter != null
                ? _filterByLang(t.audioTracks, audioLangFilter, (a) => a.language)
                : t.audioTracks;
        final subtitleTracks = options.subtitleTrackIndices != null
            ? t.subtitleTracks.where((s) => options.subtitleTrackIndices!.contains(s.index)).toList()
            : subLangFilter != null
                ? _filterByLang(t.subtitleTracks, subLangFilter, (s) => s.language)
                : t.subtitleTracks;
        return DvdTitle(
          vtsNumber:     t.vtsNumber,
          pgcIndex:      t.pgcIndex,
          pgcCount:      t.pgcCount,
          duration:      t.duration,
          audioTracks:   audioTracks,
          subtitleTracks: subtitleTracks,
          cells:         t.cells,
          chapters:      t.chapters,
          clut:          t.clut,
          videoHeight:   t.videoHeight,
        );
      }).toList();
    }

    final outDir = Directory(p.join(options.outputDir, sanitizeFilename(discTitle)));
    await outDir.create(recursive: true);

    // Phase 1: collect languages for all titles upfront
    final langsMap = <DvdTitle, ({List<String> audioLangs, List<String> subLangs})>{};
    for (final title in selected) {
      _log('── Languages: title ${title.displayKey} [${title.durationLabel}]');
      langsMap[title] = await _collectLanguages(title, prompter: _prompter, onLog: onLog);
    }
    if (!options.force) _log('');

    // Phase 2: rip
    if (dvdreadAvailable) {
      _log('   (libdvdread available — CSS decryption active if applicable)');
      await _ripWithDvdread(device, discTitle, selected, outDir, langsMap,
          overwrite: overwrite);
    } else {
      _log('   (libdvdread not found — VOB concat mode; encrypted discs will fail)');
      await _ripWithVobConcat(device, discTitle, selected, outDir, langsMap,
          mountPath: mountPath, overwrite: overwrite);
    }
  }

  Future<void> _ripWithDvdread(
    String device,
    String discTitle,
    List<DvdTitle> selected,
    Directory outDir,
    Map<DvdTitle, ({List<String> audioLangs, List<String> subLangs})> langsMap, {
    Set<String>? overwrite,
  }) async {
    // Open the disc once for all titles so libdvdcss only retrieves CSS keys once.
    final session = DVDSession.open(device);
    if (session == null) {
      _log('   Cannot open disc — libdvdread unavailable.', isError: true);
      return;
    }

    // Cache scan results per VTS number.
    // SID order is fixed within a VTS across angles on all commercial DVDs
    // (streams are interleaved in a stable order), so one scan per VTS suffices.
    final scanCache = <int, ({List<int> sidOrder, int lastSidByteOffset})>{};

    try {
    for (final title in selected) {
      final outFile = File(videoTitleOutputPath(options.outputDir, discTitle, title));
      _log('── Ripping: ${title.displayKey} → ${outFile.path}');

      if (!await confirmOverwrite(outFile,
          force: options.force, onLog: onLog, overwrite: overwrite, prompter: _prompter)) {
        continue;
      }

      final langs = langsMap[title]!;
      final cells = title.cells.isNotEmpty ? title.cells : null;

      // Only scan IFO-specified SIDs: audio and subtitle streams the disc
      // declares in the IFO. Scanning broader sets (all 0x80–0x8F) picks up
      // spurious SIDs from other angles in multi-angle VOBs, inflating the
      // audio index count and causing invalid -map arguments.
      final wantedSids = _scanSidsFor(title);

      // Rips the title once. In single-pass mode streams are mapped by MPEG
      // stream id (-map 0:i:0x80) with NO pre-scan; otherwise a scan first
      // determines ffmpeg's discovery order (a second read). Returns true when a
      // valid MKV was produced; single-pass returns false on rip error or when
      // the audio-stream count comes up short, so the caller can fall back.
      Future<bool> ripAttempt(bool singlePass) async {
        // Pass 1: scan for SID order (skipped in single-pass mode). Cached per
        // VTS; exits early once all wanted SIDs are found.
        ({List<int> sidOrder, int lastSidByteOffset})? scan;
        if (!singlePass) {
          if (scanCache.containsKey(title.vtsNumber)) {
            scan = scanCache[title.vtsNumber]!;
          } else {
            final scanStream = session.stream(title.vtsNumber, cells: cells);
            scan = await scanVobSids(scanStream, wantedSids);
            scanCache[title.vtsNumber] = scan;
          }
        }

        // CC extraction tee (see _willExtractCc): fan the rip's MPEG-PS bytes
        // out to the CC scanner so the disc is read once. Bounded + fail-soft.
        final teeCc = _willExtractCc(title);
        Future<File?>? ccScanFuture;
        var ccTeeOk = teeCc;

        Future<void> cleanupCcPartial() async {
          if (!teeCc) return;
          await ccScanFuture;
          final partial =
              File('${outFile.path.replaceFirst(RegExp(r'\.mkv$'), '')}.en.srt');
          if (await partial.exists()) {
            await partial.delete().catchError((_) => File(''));
          }
        }

        // Damaged-disc handling: unreadable sectors are zero-filled and
        // tallied; past the cap the producer stops and the title fails.
        final stats = ReadStats();
        DvdReadException? producerError;
        var lastWarnAt = 0;
        void onBadRange(int first, int last) {
          if (stats.badRanges.length <= 3 || stats.badBlocks - lastWarnAt >= 64) {
            lastWarnAt = stats.badBlocks;
            _log('   Unreadable sectors $first-$last zero-filled '
                '(${stats.badBlocks} so far).', isError: true);
          }
        }
        Stream<List<int>> readTitle() async* {
          try {
            yield* session.stream(title.vtsNumber,
                cells: cells,
                stats: stats,
                maxBadBlocks: kMaxBadSectorsPerTitle,
                onBadRange: onBadRange);
          } on DvdReadException catch (e) {
            // End the stream cleanly so ffmpeg finalises; the check below
            // fails the title.
            producerError = e;
          }
        }

        final produced = await withPartFile<bool>(outFile, (part) async {
        final ripStream = readTitle();
        var ripInput = ripStream;
        if (teeCc) {
          final stem = outFile.path.replaceFirst(RegExp(r'\.mkv$'), '');
          final ctrl = StreamController<List<int>>();
          var inFlight = 0;
          const ccCap = 128 * 1024 * 1024; // abandon the tee if CC falls behind
          final ccInput = ctrl.stream.map((c) { inFlight -= c.length; return c; });
          ccScanFuture = CcExtractor(ffmpeg: options.ffmpeg, onLog: onLog)
              .extractFromMpegPsStream(ccInput, File('$stem.en.srt'))
              .catchError((_) => null); // fail-soft: never break the rip
          ripInput = () async* {
            try {
              await for (final chunk in ripStream) {
                if (ccTeeOk) {
                  if (inFlight > ccCap) {
                    ccTeeOk = false; // CC too slow — abandon, fall back later
                    if (!ctrl.isClosed) await ctrl.close();
                  } else {
                    inFlight += chunk.length;
                    ctrl.add(chunk);
                  }
                }
                yield chunk;
              }
            } finally {
              if (!ctrl.isClosed) await ctrl.close();
            }
          }();
        }

        final mapAndMetaArgs = singlePass
            ? buildMapAndMetaArgsById(
                title: title, audioLangs: langs.audioLangs, subLangs: langs.subLangs)
            : buildMapAndMetaArgs(
                title: title, sidOrder: scan!.sidOrder,
                audioLangs: langs.audioLangs, subLangs: langs.subLangs);

        // probeBytes: in two-pass mode the scan says how far to probe. In
        // single-pass mode use the same 600 MB ceiling the scan would cap at, so
        // late-appearing streams (e.g. a subtitle 518 MB in) are still seen. The
        // ceiling only forces deep buffering on those rare discs; normal discs
        // find every stream early and write the header immediately.
        final probeBytes = singlePass
            ? 600 * 1024 * 1024
            : scan!.lastSidByteOffset + 16 * 1024 * 1024;
        final analyzeDurUs = title.duration.inMicroseconds + 60 * 1000000;

        final chapterFile = await writeChapterMetadata(title.chapters, title.duration);
        final args = [
          '-loglevel', 'repeat+level+warning', '-stats',
          '-fflags', '+genpts',
          '-probesize', '$probeBytes',
          '-analyzeduration', '$analyzeDurUs',
          '-f', 'mpeg',
          '-i', 'pipe:0',
          if (chapterFile != null) ...['-i', chapterFile.path, '-map_chapters', '1'],
          ...mapAndMetaArgs,
          part.path,
        ];

        // Retries on a scratched disc push the read rate well below 1x, so
        // the hard timeout is generous; the expectedDuration timer still
        // stops ffmpeg promptly on a clean rip.
        final dur      = title.duration.inSeconds;
        final exitCode = await _ffmpeg.run(
          args,
          stdinData:        ripInput,
          timeout:          Duration(seconds: dur * 3 + 120),
          expectedDuration: title.duration,
          onProgress:       onProgress ?? logProgress,
        );
        await chapterFile?.delete().catchError((_) => File(''));
        _log('');

        final fileSize = await part.exists() ? await part.length() : 0;
        if (exitCode != 0 || fileSize == 0 || producerError != null) {
          final why = producerError != null
              ? '$producerError'
              : 'exit code $exitCode';
          _log('   Error ripping ${title.displayKey} ($why).', isError: true);
          await cleanupCcPartial();
          return false;
        }

        // Single-pass guard: confirm every audio stream made it in. If the id
        // mapping didn't resolve them all, discard and let the caller fall back.
        if (singlePass &&
            !await _verifyDvdAudioCount(part, title.audioTracks.length)) {
          _log('   Single-pass audio-stream check failed — discarding.', isError: true);
          await cleanupCcPartial();
          return false;
        }
        return true;
        }, succeeded: (ok) => ok, onLog: onLog);
        if (!produced) return false;

        await _reportTitle(title, outFile, stats);
        await _injectSubtitlePalette(outFile, title, langs.subLangs);
        if (teeCc && ccTeeOk) {
          // CC was scanned during the rip (single disc read) — finalize it.
          await _finalizeCc(outFile, await ccScanFuture);
        } else {
          // Tee abandoned or not applicable: drop any partial, then use the
          // original path (a no-op for non-CC titles).
          await cleanupCcPartial();
          final ccCells = title.cells.isNotEmpty ? title.cells : null;
          await _extractClosedCaptions(
            outFile, title,
            sourceStreamFactory: () => session.stream(title.vtsNumber, cells: ccCells),
          );
        }
        return true;
      }

      final trySingle = options.dvdSinglePass && !_singlePassDisabled;
      var produced = await ripAttempt(trySingle);
      if (!produced && trySingle) {
        _singlePassDisabled = true;
        _log('   Single-pass mapping failed — using the two-pass scan for the '
            'remaining titles.', isError: true);
        produced = await ripAttempt(false);
      }
    }
    } finally {
      session.close();
    }
  }

  Future<void> _ripWithVobConcat(
    String device,
    String discTitle,
    List<DvdTitle> selected,
    Directory outDir,
    Map<DvdTitle, ({List<String> audioLangs, List<String> subLangs})> langsMap, {
    String? mountPath,
    Set<String>? overwrite,
  }) async {
    final scanCache = <int, ({List<int> sidOrder, int lastSidByteOffset})>{};
    Future<Object?> doRip(String mp) async {
      for (final title in selected) {
        final outFile = File(videoTitleOutputPath(options.outputDir, discTitle, title));
        _log('── Ripping: ${title.displayKey} → ${outFile.path}');

        if (!await confirmOverwrite(outFile,
            force: options.force, onLog: onLog, overwrite: overwrite, prompter: _prompter)) {
          continue;
        }

        final vobFiles = _collectVobs(mp, title.vtsNumber);
        if (vobFiles.isEmpty) {
          _log('   No VOB files found for ${title.displayKey}.', isError: true);
          continue;
        }

        final concatInput = vobFiles.join('|');
        final langs = langsMap[title]!;

        final wantedSids = _scanSidsFor(title);

        // Scan all VOB files in concat order until all SIDs are found (or cap).
        // Cached per VTS like the dvdread path: titles (angles) in one VTS
        // share the stream layout, so the second title skips the scan.
        Stream<List<int>> vobsStream() async* {
          for (final path in vobFiles) { yield* File(path).openRead(); }
        }
        final cached = scanCache[title.vtsNumber];
        if (cached != null) _log('   (stream scan cached for VTS ${title.vtsNumber})');
        final scan = cached ?? await scanVobSids(vobsStream(), wantedSids);
        scanCache[title.vtsNumber] = scan;

        final mapAndMetaArgs = buildMapAndMetaArgs(
          title:      title,
          sidOrder:   scan.sidOrder,
          audioLangs: langs.audioLangs,
          subLangs:   langs.subLangs,
        );
        // probeBytes: scan position + 16 MiB headroom, passed as raw bytes to ffmpeg.
        // analyzeduration is in microseconds (not bytes) — use full title duration + 60 s margin.
        final probeBytes   = scan.lastSidByteOffset + 16 * 1024 * 1024;
        final analyzeDurUs = title.duration.inMicroseconds + 60 * 1000000;
        final chapterFile  = await writeChapterMetadata(title.chapters, title.duration);
        final produced = await withPartFile<bool>(outFile, (part) async {
          final args = [
            '-loglevel', 'repeat+level+warning', '-stats',
            '-fflags', '+genpts',
            '-probesize', '$probeBytes',
            '-analyzeduration', '$analyzeDurUs',
            '-f', 'mpeg',
            '-i', 'concat:$concatInput',
            if (chapterFile != null) ...['-i', chapterFile.path, '-map_chapters', '1'],
            ...mapAndMetaArgs,
            part.path,
          ];

          final dur      = title.duration.inSeconds;
          final exitCode = await _ffmpeg.run(
            args,
            timeout:          Duration(seconds: dur + 60),
            expectedDuration: title.duration,
            onProgress:       onProgress ?? logProgress,
          );
          await chapterFile?.delete().catchError((_) => File(''));
          _log('');

          final fileSize = await part.exists() ? await part.length() : 0;
          if (exitCode == 0 && fileSize > 0) return true;
          _log('   Error ripping ${title.displayKey} (exit code $exitCode).', isError: true);
          return false;
        }, succeeded: (ok) => ok, onLog: onLog);

        if (produced) {
          await _reportTitle(title, outFile, null);
          await _injectSubtitlePalette(outFile, title, langs.subLangs);
          await _extractClosedCaptions(
            outFile,
            title,
            sourceStreamFactory: () async* {
              for (final path in vobFiles) { yield* File(path).openRead(); }
            },
          );
        }
      }
      return null;
    }

    if (mountPath != null) {
      await doRip(mountPath);
    } else {
      await withMountedDisc<Object?>(device, doRip, onLog: onLog);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<({String discTitle, List<DvdTitle> titles})?> _scanMounted(
    String mountPath,
    String mountedAt,
  ) async {
    final videoTs = p.join(mountPath, 'VIDEO_TS');
    final vmgPath = p.join(videoTs, 'VIDEO_TS.IFO');
    String discTitle;
    int numVts;
    try {
      final vmgData = await File(vmgPath).readAsBytes();
      discTitle = readAsciiFixed(vmgData, 0x12, 32);
      if (discTitle.isEmpty) discTitle = p.basename(mountedAt);
      if (discTitle.isEmpty) discTitle = 'dvd';
      numVts = ByteData.sublistView(vmgData).getUint16(0x3E, Endian.big);
    } catch (e) {
      _log('Error: VIDEO_TS.IFO not readable ($e)', isError: true);
      return null;
    }

    if (numVts == 0) {
      // VMG reports 0 VTS — fall back to counting IFO files on disk.
      var n = 0;
      while (File(p.join(videoTs, 'VTS_${(n + 1).toString().padLeft(2, '0')}_0.IFO')).existsSync()) {
        n++;
      }
      if (n == 0) {
        _log('Error: no titles found on the DVD.', isError: true);
        return null;
      }
      numVts = n;
    }

    final titles = <DvdTitle>[];
    for (var i = 1; i <= numVts; i++) {
      final vts = await _scanVts(videoTs, i);
      final vobSectors = await _vtsVobSectors(videoTs, i);
      final readable   = dropTitlesBeyondVob(vts, vobSectors);
      if (readable.length < vts.length) {
        final maxLast = vts
            .expand((t) => t.cells)
            .fold(0, (m, c) => c.last > m ? c.last : m);
        _log('   VTS $i: ${vts.length - readable.length} PGC(s) ignored '
             '(cells reach sector $maxLast, VOB set holds $vobSectors sectors)');
      }
      titles.addAll(readable);
    }

    if (titles.isEmpty) {
      _log('Error: no titles found on the DVD (all PGCs too short or unreadable).', isError: true);
      return null;
    }

    titles.sort((a, b) {
      final v = a.vtsNumber.compareTo(b.vtsNumber);
      return v != 0 ? v : a.pgcIndex.compareTo(b.pgcIndex);
    });

    return (discTitle: discTitle, titles: _filterDecoyTitles(titles));
  }

  /// Total size in 2048-byte sectors of the title VOB set
  /// (`VTS_XX_1.VOB` … `VTS_XX_9.VOB`) of VTS [vtsNum]; 0 when none exist.
  static Future<int> _vtsVobSectors(String videoTs, int vtsNum) async {
    final pad = vtsNum.toString().padLeft(2, '0');
    var bytes = 0;
    for (var i = 1; i <= 9; i++) {
      final f = File(p.join(videoTs, 'VTS_${pad}_$i.VOB'));
      if (!await f.exists()) break;
      bytes += await f.length();
    }
    return bytes ~/ 2048;
  }

  /// Drops PGCs whose cells point past the end of the VTS title VOB set.
  ///
  /// Cell sector addresses in the IFO are relative to the start of
  /// `VTS_XX_1.VOB`, so any cell with `last >= vobSectors` references data
  /// that does not exist on the disc.  Copy-protection schemes author such
  /// "mirror" VTS sections: IFOs that replicate the real episodes' durations,
  /// stream layout and chapter counts, backed by a VOB of a few hundred
  /// sectors.  They are unrippable and would otherwise be mistaken for extra
  /// episode sets by the auto-selector.
  ///
  /// Titles without cell data are kept; when [vobSectors] is 0 (no VOB files
  /// found, e.g. an incomplete image) nothing is filtered.
  static List<DvdTitle> dropTitlesBeyondVob(List<DvdTitle> titles, int vobSectors) {
    if (vobSectors <= 0) return titles;
    return titles
        .where((t) => !t.cells.any((c) => c.last >= vobSectors))
        .toList();
  }

  /// Removes copy-protection decoy PGCs from [titles].
  ///
  /// Some discs store low-bitrate "decoy" PGCs with inflated IFO durations
  /// alongside the real content.  Within each duration group (±5 s) the
  /// real PGCs have significantly more sectors than the decoys.  When the
  /// ratio between the highest and lowest sector count in a group exceeds
  /// 1.5×, every PGC with fewer than half the maximum sectors is removed.
  ///
  /// Only duration groups where at least one title is ≥ 5 minutes are
  /// considered; short clips are left untouched.
  static List<DvdTitle> _filterDecoyTitles(List<DvdTitle> titles) {
    const dupTol = Duration(seconds: 5);
    const minDur = Duration(minutes: 5);

    // Group by duration (±5 s).
    final groups = <List<DvdTitle>>[];
    for (final t in titles) {
      final idx = groups.indexWhere(
          (g) => (g.first.duration - t.duration).abs() <= dupTol);
      if (idx >= 0) {
        groups[idx].add(t);
      } else {
        groups.add([t]);
      }
    }

    final toRemove = <DvdTitle>{};
    for (final group in groups) {
      if (group.length < 2) continue;
      if (group.every((t) => t.duration < minDur)) continue;

      final maxS = group.map((t) => t.totalSectors).reduce((a, b) => a > b ? a : b);
      final minS = group.map((t) => t.totalSectors).reduce((a, b) => a < b ? a : b);
      if (maxS <= 0 || minS <= 0) continue;
      if (maxS / minS < 1.5) continue;

      // Keep only titles with ≥ 55 % of the max sector count.
      // Observed ratios: real content ≈ 1.0, copy-protection decoys ≈ 0.48–0.52.
      for (final t in group) {
        if (t.totalSectors < maxS * 0.55) toRemove.add(t);
      }
    }

    return toRemove.isEmpty
        ? titles
        : titles.where((t) => !toRemove.contains(t)).toList();
  }

  /// Scans one VTS and returns a DvdTitle per PGC (= angle).
  /// PGCs shorter than 5 seconds (menus, splash screens) are skipped.
  Future<List<DvdTitle>> _scanVts(String videoTs, int vtsNum) async {
    final pad     = vtsNum.toString().padLeft(2, '0');
    final ifoFile = File(p.join(videoTs, 'VTS_${pad}_0.IFO'));
    if (!await ifoFile.exists()) return [];

    late Uint8List data;
    late ByteData  bd;
    try {
      data = await ifoFile.readAsBytes();
      bd   = ByteData.sublistView(data);
    } catch (e) {
      // A damaged disc often fails right here; without this line the scan
      // just reports fewer (or no) titles.
      _log('   Could not read ${ifoFile.path}: $e', isError: true);
      return [];
    }

    // PGCIT sector and number of PGCs
    int pgciOff;
    int nrPgc;
    try {
      pgciOff = bd.getUint32(0xCC, Endian.big) * 2048;
      if (pgciOff + 2 > data.length) return [];
      nrPgc   = bd.getUint16(pgciOff, Endian.big);
      if (nrPgc == 0) return [];
    } catch (_) {
      return [];
    }

    // VTS video attributes at 0x200:
    //   bits 5–4: standard (00=NTSC, 01=PAL)
    //   bits 3–2: aspect ratio (00=4:3, 11=16:9)
    final videoHeight = data.length > 0x200 && ((data[0x200] >> 4) & 0x3) == 0
        ? 480  // NTSC
        : 576; // PAL (default)
    final is16x9 = data.length > 0x200 && ((data[0x200] >> 2) & 0x3) == 3;

    final vtsAudio = readVtsAudioAttribs(data, bd);
    final vtsSub   = readVtsSubtitleAttribs(data, bd);

    // Scan each PGC
    final results = <DvdTitle>[];
    for (var pgcIdx = 0; pgcIdx < nrPgc; pgcIdx++) {
      // Offset to PGC in PGCIT: pgciOff + 8 (8-byte header) + pgcIdx * 8 + 4 (rel. offset)
      final srp    = pgciOff + 8 + pgcIdx * 8;
      if (srp + 8 > data.length) break;
      final pgcRel = bd.getUint32(srp + 4, Endian.big);
      final pgc    = pgciOff + pgcRel;

      int durSeconds;
      try {
        int bcd(int b) => ((b >> 4) & 0xF) * 10 + (b & 0xF);
        durSeconds = bcd(data[pgc + 4]) * 3600
                   + bcd(data[pgc + 5]) * 60
                   + bcd(data[pgc + 6]);
      } catch (_) {
        continue;
      }
      if (durSeconds < 5) continue;

      final streams      = scanPgcStreams(data, bd, pgc, is16x9, vtsAudio);
      final audioTracks  = buildAudioTracks(vtsAudio, streams);
      final subtitleTracks = buildSubtitleTracks(vtsSub, streams);
      final cellsAndChapters = scanPgcCells(data, bd, pgc, durSeconds,
          onDiag: (msg) => _log('   [cell-diag] VTS $vtsNum PGC ${pgcIdx + 1}: $msg'));
      final clut         = readPgcClut(data, pgc);

      results.add(DvdTitle(
        vtsNumber:      vtsNum,
        pgcIndex:       pgcIdx,
        pgcCount:       nrPgc,
        duration:       Duration(seconds: durSeconds),
        audioTracks:    audioTracks,
        subtitleTracks: subtitleTracks,
        cells:          cellsAndChapters.cells,
        chapters:       cellsAndChapters.chapters,
        clut:           clut,
        videoHeight:    videoHeight,
      ));
    }
    return results;
  }

  // ---------------------------------------------------------------------------
  // Language collection (interactive)
  // ---------------------------------------------------------------------------

  static Future<({List<String> audioLangs, List<String> subLangs})> _collectLanguages(
    DvdTitle title, {
    required Prompter prompter,
    LogCallback? onLog,
  }) {
    final audioLabels   = [
      for (final a in title.audioTracks)
        '${a.codec} ${channelLabel(a.channels)}',
    ];
    final audioCurrents = [
      for (final a in title.audioTracks) convertIso1to2(a.language),
    ];
    final subCurrents   = [
      for (final s in title.subtitleTracks) convertIso1to2(s.language),
    ];
    return askLanguages(
      audioLabels:   audioLabels,
      audioCurrents: audioCurrents,
      subCurrents:   subCurrents,
      prompter:      prompter,
      onLog:         onLog,
    );
  }

  /// Logs "Done" (or "Done (with warnings)"), records a [TitleRipReport] and
  /// warns when sectors were zero-filled or the output is clearly too short.
  Future<void> _reportTitle(DvdTitle title, File outFile, ReadStats? stats) async {
    final report = TitleRipReport(
      titleKey: title.displayKey,
      outputPath: outFile.path,
      read: stats,
      expected: title.duration,
      actual: await _probeDuration(outFile),
    );
    reports.add(report);
    if (report.hasReadErrors) {
      _log('   Warning: ${stats!.summary()}.', isError: true);
    }
    if (!report.durationOk) {
      _log('   Warning: output is ${report.actual!.hmsLabel}, title is '
          '${title.durationLabel} — rip is probably truncated.', isError: true);
    }
    _log(report.hasWarnings
        ? '   Done (with warnings): ${outFile.path}'
        : '   Done: ${outFile.path}');
  }

  /// Container duration via ffprobe, or null when the probe fails.
  Future<Duration?> _probeDuration(File f) async {
    try {
      final r = await Process.run(options.ffprobe, [
        '-v', 'quiet', '-show_entries', 'format=duration',
        '-of', 'csv=p=0', f.path,
      ]);
      if (r.exitCode != 0) return null;
      final secs = double.tryParse((r.stdout as String).trim());
      if (secs == null) return null;
      return Duration(milliseconds: (secs * 1000).round());
    } catch (_) {
      return null;
    }
  }

  /// Verifies the ripped MKV actually contains at least [expected] audio streams.
  /// Used after a single-pass (map-by-id) rip to detect dropped streams and
  /// trigger the two-pass fallback. Returns true (don't fall back) on any
  /// ffprobe error so a probe failure doesn't needlessly discard a good rip.
  Future<bool> _verifyDvdAudioCount(File outFile, int expected) async {
    if (expected <= 0) return true;
    try {
      final r = await Process.run(options.ffprobe, [
        '-v', 'quiet', '-select_streams', 'a',
        '-show_entries', 'stream=index', '-of', 'csv=p=0', outFile.path,
      ]);
      if (r.exitCode != 0) return true;
      final count = (r.stdout as String)
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .length;
      return count >= expected;
    } catch (_) {
      return true;
    }
  }

  // ---------------------------------------------------------------------------
  // Closed Caption extraction (EIA-608 / NTSC DVDs)
  // ---------------------------------------------------------------------------

  /// Extracts EIA-608 CC subtitles for NTSC titles (videoHeight == 480)
  /// that have no IFO-declared subtitle tracks. The SRT is embedded in the MKV as a
  /// subtitle track and the sidecar file is removed.
  ///
  /// When [sourceStreamFactory] is provided, CC is extracted from the original
  /// MPEG-PS source (dvdread stream or VOB files) instead of the ripped MKV.
  /// This preserves EDM user_data packets that ffmpeg may drop when remuxing
  /// MPEG-PS → MKV, giving accurate caption end-times.
  /// Whether [title] is a candidate for EIA-608 CC extraction: NTSC (480-line)
  /// and with no IFO-declared subtitle tracks. Mirrors the guards below; used to
  /// decide upfront whether to tee the rip stream into the CC scanner.
  bool _willExtractCc(DvdTitle title) =>
      title.videoHeight == 480 && title.subtitleTracks.isEmpty;

  /// Embeds [srtFile] when non-null, otherwise strips the leftover user_data
  /// identifiers so players don't show empty "Closed Captions 1-4" tracks.
  Future<void> _finalizeCc(File outFile, File? srtFile) async {
    if (srtFile == null) {
      await stripMkvCcUserData(outFile);
      return;
    }
    await _embedSrtInMkv(outFile, srtFile, 'eng');
  }

  Future<void> _extractClosedCaptions(
    File outFile,
    DvdTitle title, {
    Stream<List<int>> Function()? sourceStreamFactory,
  }) async {
    if (!_willExtractCc(title)) return;

    final extractor = CcExtractor(ffmpeg: options.ffmpeg, onLog: onLog);

    File? srtFile;
    if (sourceStreamFactory != null) {
      final stem = outFile.path.replaceFirst(RegExp(r'\.mkv$'), '');
      srtFile = await extractor.extractFromMpegPsStream(
        sourceStreamFactory(),
        File('$stem.en.srt'),
      );
    } else {
      srtFile = await extractor.extractFromMkv(outFile);
    }

    await _finalizeCc(outFile, srtFile);
  }

  /// Embeds [srtFile] as a subtitle track in [mkvFile] and deletes the sidecar.
  /// Uses mkvmerge if available, otherwise ffmpeg.
  Future<void> _embedSrtInMkv(File mkvFile, File srtFile, String lang) async {
    final fixedPath = '${mkvFile.path}.tmp.mkv';
    bool ok = false;

    try {
    final whichMerge = await Process.run('which', ['mkvmerge']);
    if (whichMerge.exitCode == 0) {
      final result = await Process.run('mkvmerge', [
        '-o', fixedPath,
        mkvFile.path,
        '--language', '0:$lang',
        '--default-track', '0:yes',
        srtFile.path,
      ]);
      ok = result.exitCode == 0 || result.exitCode == 1;
      if (!ok) {
        _log('   mkvmerge CC embed failed (${result.exitCode}): ${result.stderr}', isError: true);
      }
    } else {
      final result = await Process.run(options.ffmpeg, [
        '-i', mkvFile.path,
        '-i', srtFile.path,
        '-map', '0',
        '-map', '1',
        '-c', 'copy',
        '-metadata:s:s:0', 'language=$lang',
        '-disposition:s:0', 'default',
        fixedPath,
      ]);
      ok = result.exitCode == 0;
      if (!ok) {
        _log('   ffmpeg CC embed failed: ${result.stderr}', isError: true);
      }
    }

    if (ok) {
      await File(fixedPath).rename(mkvFile.path);
      await srtFile.delete();
      await stripMkvCcUserData(mkvFile);
      _log('   CC subtitle embedded in MKV.');
    }
    } finally {
      // Whether the merge failed or the rename threw, never leave the temp file.
      final fixed = File(fixedPath);
      if (await fixed.exists()) await fixed.delete().catchError((_) => fixed);
    }
  }


  static List<String> _collectVobs(String mountPath, int vtsNum) {
    final pad     = vtsNum.toString().padLeft(2, '0');
    final videoTs = p.join(mountPath, 'VIDEO_TS');
    final vobs    = <String>[];
    for (var i = 1; i <= 9; i++) {
      final f = File(p.join(videoTs, 'VTS_${pad}_$i.VOB'));
      if (f.existsSync()) vobs.add(f.path);
    }
    return vobs;
  }

  // ---------------------------------------------------------------------------
  // Subtitle palette helpers
  // ---------------------------------------------------------------------------

  /// Patches the VobSub codec private of each subtitle track in [outFile]
  /// so the MKV palette matches the IFO CLUT.
  ///
  /// Strategy:
  ///   1. mkvextract  — extract subtitle track(s) as IDX+SUB pairs.
  ///   2. Patch IDX   — insert `size:` and `palette:` lines from the IFO CLUT.
  ///   3. mkvmerge    — remux without old subtitles, adding patched IDX+SUB.
  ///   4. Replace     — overwrite the original MKV with the fixed one.
  ///
  /// Requires mkvtoolnix (mkvextract + mkvmerge). Skipped with a warning if
  /// not available; the rip still succeeds but players show wrong colors.
  Future<void> _injectSubtitlePalette(
    File outFile,
    DvdTitle title,
    List<String> subLangs,
  ) async {
    if (title.clut.isEmpty || title.subtitleTracks.isEmpty) return;

    final whichExtract = await Process.run('which', ['mkvextract']);
    final whichMerge   = await Process.run('which', ['mkvmerge']);
    if (whichExtract.exitCode != 0 || whichMerge.exitCode != 0) {
      _log('   mkvtoolnix not found — subtitle palette not injected.'
          ' Install mkvtoolnix for correct subtitle colors.', isError: true);
      return;
    }

    // --- 1. Identify subtitle track IDs in the MKV. ---
    final identify = await Process.run('mkvmerge', ['-i', outFile.path]);
    final subTrackIds = <int>[];
    for (final line in (identify.stdout as String).split('\n')) {
      // "Track ID 2: subtitles (VobSub)"
      final m = RegExp(r'Track ID (\d+): subtitles').firstMatch(line);
      if (m != null) subTrackIds.add(int.parse(m.group(1)!));
    }
    if (subTrackIds.isEmpty) return;

    final tmpDir = await Directory.systemTemp.createTemp('vobsub_');
    try {
      // --- 2. Extract subtitle tracks (IDX + SUB). ---
      final extractArgs = ['tracks', outFile.path];
      final tmpPrefixes = <String>[];
      for (var i = 0; i < subTrackIds.length; i++) {
        final prefix = p.join(tmpDir.path, 's$i');
        extractArgs.add('${subTrackIds[i]}:$prefix');
        tmpPrefixes.add(prefix);
      }
      final extract = await Process.run('mkvextract', extractArgs);
      if (extract.exitCode != 0) {
        _log('   mkvextract warning: ${(extract.stderr as String).trim()}', isError: true);
        return;
      }

      // --- 3. Patch each IDX: insert `size:` + `palette:` after line 1. ---
      final paletteStr = title.clut
          .map((c) => c.toRadixString(16).padLeft(6, '0'))
          .join(', ');
      final sizeStr = 'size: 720x${title.videoHeight}';

      final idxPaths = <String>[];
      for (var i = 0; i < tmpPrefixes.length; i++) {
        final idxFile = File('${tmpPrefixes[i]}.idx');
        if (!await idxFile.exists()) continue;
        final lines = await idxFile.readAsLines();
        // Insert after the version comment (first line).
        final patched = [
          lines.isNotEmpty ? lines[0] : '# VobSub index file, v7 (do not modify this line!)',
          sizeStr,
          'palette: $paletteStr',
          ...lines.skip(1),
        ].join('\n');
        await idxFile.writeAsString('$patched\n');
        idxPaths.add(idxFile.path);
      }
      if (idxPaths.isEmpty) return;

      // --- 4. Remux: remove old subtitles + add patched IDX+SUB. ---
      // Write next to the original (same filesystem) so rename() is atomic
      // and /tmp quota is not exhausted by the remuxed file.
      // Check available space: need at least as much as the file itself.
      final fileSize = await outFile.length();
      final dfResult = await Process.run('df', ['--output=avail', '--block-size=1',
          outFile.parent.path]);
      final availBytes = int.tryParse(
          (dfResult.stdout as String).split('\n').skip(1).firstOrNull?.trim() ?? '') ?? 0;
      if (availBytes > 0 && availBytes < fileSize) {
        _log('   Subtitle palette not injected: not enough free space'
            ' (need ${fileSize ~/ 1048576} MiB, have ${availBytes ~/ 1048576} MiB).', isError: true);
        return;
      }
      _log('   Injecting subtitle palette (remux)…');
      final fixedPath = p.join(outFile.parent.path,
          '${p.basenameWithoutExtension(outFile.path)}.fixed.mkv');
      final mergeArgs = ['-o', fixedPath, '--no-subtitles', outFile.path,
          ...idxPaths];
      final merge = await Process.run('mkvmerge', mergeArgs);
      // mkvmerge exit codes: 0 = success, 1 = success with warnings, 2 = error.
      if (merge.exitCode >= 2) {
        final out = (merge.stdout as String).trim();
        final err = (merge.stderr as String).trim();
        _log('   mkvmerge failed (exit ${merge.exitCode}):', isError: true);
        if (out.isNotEmpty) _log('   stdout: $out', isError: true);
        if (err.isNotEmpty) _log('   stderr: $err', isError: true);
        await File(fixedPath).delete().catchError((_) => File(fixedPath));
        return;
      }

      // --- 5. Replace original with fixed file. ---
      try {
        await File(fixedPath).rename(outFile.path);
      } catch (e) {
        _log('   Could not replace ${outFile.path} with remuxed file: $e',
            isError: true);
        await File(fixedPath).delete().catchError((_) => File(fixedPath));
      }
    } finally {
      await tmpDir.delete(recursive: true);
    }
  }

  /// Test-only wrapper for the private [scanPgcCells].
  static ({List<({int first, int last})> cells, List<Duration> chapters})
      scanPgcCellsForTest(Uint8List data, ByteData bd, int pgc, int durSeconds,
              {void Function(String)? onDiag}) =>
          scanPgcCells(data, bd, pgc, durSeconds, onDiag: onDiag);

  // Exposed for unit tests only.
  static int? pgcSubIdForTest(int ctrl, {bool prefer16x9 = false}) =>
      pgcSubId(ctrl, prefer16x9: prefer16x9);
}
