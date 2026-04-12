import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../device/dvdread.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../models/dvd_title.dart';
import '../models/rip_options.dart';
import '../utils/file_utils.dart';
import '../utils/languages.dart';
import '../utils/mount.dart';
import '../utils/progress.dart';
import '../utils/sanitize.dart';

class DVDRipper {
  final RipOptions options;
  final FfmpegRunner _ffmpeg;

  DVDRipper(this.options) : _ffmpeg = FfmpegRunner(executable: options.ffmpeg);

  /// Scans the DVD via the IFO parser.
  /// Returns null on error.
  /// [titles] is sorted by VTS number + PGC index.
  Future<({String discTitle, List<DvdTitle> titles})?> loadTitles() async {
    return withMountedDisc(
      options.device!,
      (mp) => _scanMounted(mp, mp),
      errorContext: 'DVD',
    );
  }

  /// Rips the selected titles as lossless MKV.
  /// If libdvdread is available (+ libdvdcss for CSS discs): uses
  /// DVDReadBlocks via pipe → ffmpeg stdin (encrypted or not).
  /// Otherwise: VOB concat fallback (only for unencrypted discs).
  Future<void> rip(String discTitle, List<DvdTitle> selected) async {
    final device = options.device!;

    final outDir = Directory(p.join(options.outputDir, sanitizeFilename(discTitle)));
    await outDir.create(recursive: true);

    // Phase 1: collect languages for all titles upfront
    final langsMap = <DvdTitle, ({List<String> audioLangs, List<String> subLangs})>{};
    for (final title in selected) {
      stdout.writeln('── Languages: title ${title.displayKey} [${title.durationLabel}]');
      langsMap[title] = _collectLanguages(title, force: options.force);
    }
    if (!options.force) stdout.writeln('');

    // Phase 2: rip
    if (dvdreadAvailable) {
      stdout.writeln('   (libdvdread available — CSS decryption active if applicable)');
      await _ripWithDvdread(device, discTitle, selected, outDir, langsMap);
    } else {
      stdout.writeln('   (libdvdread not found — VOB concat mode; encrypted discs will fail)');
      await _ripWithVobConcat(device, selected, outDir, langsMap);
    }
  }

  Future<void> _ripWithDvdread(
    String device,
    String discTitle,
    List<DvdTitle> selected,
    Directory outDir,
    Map<DvdTitle, ({List<String> audioLangs, List<String> subLangs})> langsMap,
  ) async {
    for (final title in selected) {
      final outFile = File(p.join(outDir.path, title.filename));
      stdout.writeln('── Ripping: ${title.displayKey} → ${outFile.path}');

      if (!await confirmOverwrite(outFile, force: options.force)) continue;

      final langs = langsMap[title]!;
      final cells = title.cells.isNotEmpty ? title.cells : null;

      // Only scan IFO-specified SIDs: audio and subtitle streams the disc
      // declares in the IFO. Scanning broader sets (all 0x80–0x8F) picks up
      // spurious SIDs from other angles in multi-angle VOBs, inflating the
      // audio index count and causing invalid -map arguments.
      // _scanVobSids caps at 256 MB so that discs whose IFO-declared subtitle
      // SIDs don't exist in the VOB never cause a full-file scan.
      final wantedSids = <int>{
        ...title.audioTracks.map((a) => a.streamId),
        ...title.subtitleTracks.map((s) => s.streamId),
      };

      // Pass 1: scan the full VOB stream for SID order + position of last SID.
      // Uses a separate streamVobs call so no data needs to be buffered.
      final scanStream = streamVobs(device, title.vtsNumber, cells: cells);
      if (scanStream == null) {
        stderr.writeln('   streamVobs returned null unexpectedly — skipping.');
        continue;
      }
      final scan = await _scanVobSids(scanStream, wantedSids);

      // Pass 2: rip with a probesize that covers the full scan depth.
      final ripStream = streamVobs(device, title.vtsNumber, cells: cells);
      if (ripStream == null) {
        stderr.writeln('   streamVobs returned null unexpectedly — skipping.');
        continue;
      }

      final mapAndMetaArgs = _buildMapAndMetaArgs(
        title:      title,
        sidOrder:   scan.sidOrder,
        audioLangs: langs.audioLangs,
        subLangs:   langs.subLangs,
      );

      // probeBytes: scan position + 16 MiB headroom, passed as raw bytes to ffmpeg.
      // analyzeduration is in microseconds (not bytes) — use full title duration + 60 s margin.
      final probeBytes   = scan.lastSidByteOffset + 16 * 1024 * 1024;
      final analyzeDurUs = title.duration.inMicroseconds + 60 * 1000000;

      final chapterFile = await writeChapterMetadata(title.chapters, title.duration);
      final args = [
        '-loglevel', 'warning', '-stats',
        '-fflags', '+genpts',
        '-probesize', '$probeBytes',
        '-analyzeduration', '$analyzeDurUs',
        '-f', 'mpeg',
        '-i', 'pipe:0',
        if (chapterFile != null) ...['-i', chapterFile.path, '-map_chapters', '1'],
        ...mapAndMetaArgs,
        outFile.path,
      ];

      final dur      = title.duration.inSeconds;
      final exitCode = await _ffmpeg.runWithStdin(
        args,
        ripStream,
        timeout:          Duration(seconds: dur + 120),
        expectedDuration: title.duration,
        onProgress:       logProgress,
      );
      await chapterFile?.delete().catchError((_) => File(''));
      stdout.writeln('');

      final fileSize = await outFile.exists() ? await outFile.length() : 0;
      if (exitCode == 0 && fileSize > 0) {
        stdout.writeln('   Done: ${outFile.path}');
        await _injectSubtitlePalette(outFile, title, langs.subLangs);
      } else {
        stderr.writeln('   Error ripping ${title.displayKey} (exit code $exitCode).');
        await outFile.delete().catchError((e) {
          stderr.writeln('   Cannot delete file: $e');
          return File('');
        });
      }
    }
  }

  Future<void> _ripWithVobConcat(
    String device,
    List<DvdTitle> selected,
    Directory outDir,
    Map<DvdTitle, ({List<String> audioLangs, List<String> subLangs})> langsMap,
  ) async {
    await withMountedDisc<Object?>(device, (mountPath) async {
      for (final title in selected) {
        final outFile = File(p.join(outDir.path, title.filename));
        stdout.writeln('── Ripping: ${title.displayKey} → ${outFile.path}');

        if (!await confirmOverwrite(outFile, force: options.force)) continue;

        final vobFiles = _collectVobs(mountPath, title.vtsNumber);
        if (vobFiles.isEmpty) {
          stderr.writeln('   No VOB files found for ${title.displayKey}.');
          continue;
        }

        final concatInput = vobFiles.join('|');
        final langs = langsMap[title]!;

        final wantedSids = <int>{
          ...title.audioTracks.map((a) => a.streamId),
          ...title.subtitleTracks.map((s) => s.streamId),
        };

        // Scan all VOB files in concat order until all SIDs are found (or cap).
        Stream<List<int>> vobsStream() async* {
          for (final path in vobFiles) { yield* File(path).openRead(); }
        }
        final scan = await _scanVobSids(vobsStream(), wantedSids);

        final mapAndMetaArgs = _buildMapAndMetaArgs(
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
        final args = [
          '-loglevel', 'warning', '-stats',
          '-fflags', '+genpts',
          '-probesize', '$probeBytes',
          '-analyzeduration', '$analyzeDurUs',
          '-f', 'mpeg',
          '-i', 'concat:$concatInput',
          if (chapterFile != null) ...['-i', chapterFile.path, '-map_chapters', '1'],
          ...mapAndMetaArgs,
          outFile.path,
        ];

        final dur      = title.duration.inSeconds;
        final exitCode = await _ffmpeg.run(
          args,
          timeout:          Duration(seconds: dur + 60),
          expectedDuration: title.duration,
          onProgress:       logProgress,
        );
        await chapterFile?.delete().catchError((_) => File(''));
        stdout.writeln('');

        final fileSize = await outFile.exists() ? await outFile.length() : 0;
        if (exitCode == 0 && fileSize > 0) {
          stdout.writeln('   Done: ${outFile.path}');
          await _injectSubtitlePalette(outFile, title, langs.subLangs);
        } else {
          stderr.writeln('   Error ripping ${title.displayKey} (exit code $exitCode).');
          await outFile.delete().catchError((e) {
            stderr.writeln('   Cannot delete file: $e');
            return File('');
          });
        }
      }
      return null;
    });
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
      discTitle = _readAsciiFixed(vmgData, 0x12, 32);
      if (discTitle.isEmpty) discTitle = p.basename(mountedAt);
      if (discTitle.isEmpty) discTitle = 'dvd';
      numVts = ByteData.sublistView(vmgData).getUint16(0x3E, Endian.big);
    } catch (e) {
      stderr.writeln('Error: VIDEO_TS.IFO not readable ($e)');
      return null;
    }

    if (numVts == 0) {
      stderr.writeln('Error: no titles found on the DVD.');
      return null;
    }

    final titles = <DvdTitle>[];
    for (var i = 1; i <= numVts; i++) {
      final vts = await _scanVts(videoTs, i);
      titles.addAll(vts);
    }

    if (titles.isEmpty) return null;

    titles.sort((a, b) {
      final v = a.vtsNumber.compareTo(b.vtsNumber);
      return v != 0 ? v : a.pgcIndex.compareTo(b.pgcIndex);
    });

    return (discTitle: discTitle, titles: titles);
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
    } catch (_) {
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

    // VTS-level: audio and subtitle attribute tables (for language/codec)
    const audioFormats = {0: 'AC3', 2: 'MP2', 3: 'MP2E', 4: 'LPCM', 6: 'DTS'};
    final vtsAudio = <int, ({String lang, String codec, int channels})>{};
    try {
      final numAudio = bd.getUint16(0x202, Endian.big);
      for (var i = 0; i < numAudio && i < 8; i++) {
        final off  = 0x204 + i * 8;
        if (off + 4 > data.length) break;
        final fmt  = (data[off] >> 5) & 0x7;
        final ch   = (data[off + 1] & 0x7) + 1;
        final lang = (data[off + 2] > 0x20 && data[off + 3] > 0x20)
            ? String.fromCharCodes([data[off + 2], data[off + 3]])
            : '';
        vtsAudio[i] = (lang: lang, codec: audioFormats[fmt] ?? 'PCM', channels: ch);
      }
    } catch (_) {}

    final vtsSub = <int, String>{};
    try {
      final numSubs = bd.getUint16(0x254, Endian.big);
      for (var i = 0; i < numSubs && i < 32; i++) {
        final off  = 0x256 + i * 6;
        if (off + 4 > data.length) break;
        final lang = (data[off + 2] > 0x20 && data[off + 3] > 0x20)
            ? String.fromCharCodes([data[off + 2], data[off + 3]])
            : '';
        vtsSub[i] = lang;
      }
    } catch (_) {}

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

      // PGC audio control (pgc + 0x0C, 8 × uint16):
      //   byte 0 (high byte): bit7 = active, bits2-0 = sub-stream nr → MPEG ID 0x80+nr
      // PGC subtitle control (pgc + 0x1C, 32 × uint32 per DVD spec):
      //   byte 0 (bits31-24): bit31=active_4:3,        bits28:24=stream_nr
      //   byte 1 (bits23-16): bit23=active_widescreen,  bits20:16=stream_nr
      //   byte 2 (bits15-8):  bit15=active_letterbox,   bits12:8 =stream_nr
      //   byte 3 (bits7-0):   bit7 =active_pan_scan,    bits4:0  =stream_nr
      //   MPEG sub-stream ID = 0x20 + stream_nr. Widescreen discs leave byte 0 zero.
      final activeAudio    = <int>{};
      final audioStreamIds = <int, int>{}; // ifo_idx → MPEG sub-stream ID
      final activeSubs     = <int>{};
      final subStreamIds   = <int, int>{}; // ifo_idx → MPEG sub-stream ID
      final pgcOk = pgc + 0x1C + 32 * 4 <= data.length;
      if (pgcOk) {
        for (var i = 0; i < 8; i++) {
          final ctrl = bd.getUint16(pgc + 0x0C + i * 2, Endian.big);
          if ((ctrl & 0x8000) != 0) {
            activeAudio.add(i);
            final nr    = (ctrl >> 8) & 0x07;
            final codec = vtsAudio[i]?.codec ?? '';
            // DVD private stream 1 sub-IDs are codec-range-specific:
            //   AC3/MP2: 0x80–0x87,  DTS: 0x88–0x8F,  LPCM: 0xA0–0xA7
            final base  = codec == 'DTS' ? 0x88 : codec == 'LPCM' ? 0xA0 : 0x80;
            audioStreamIds[i] = base + nr;
          }
        }
        for (var i = 0; i < 32; i++) {
          final ctrl  = bd.getUint32(pgc + 0x1C + i * 4, Endian.big);
          final subId = _pgcSubId(ctrl, prefer16x9: is16x9);
          if (subId != null) {
            activeSubs.add(i);
            subStreamIds[i] = subId;
          }
        }

        // Post-process: when multiple IFO subtitle entries map to the same SID
        // (e.g. a disc where ALL entries share 4:3 stream_nr=0), look at the
        // widescreen/letterbox/pan-scan stream_nr bytes (even if inactive) for
        // a unique stream number to differentiate them.
        final usedSids = <int, int>{};
        for (var i = 0; i < 32; i++) {
          if (!subStreamIds.containsKey(i)) continue;
          final sid = subStreamIds[i]!;
          if (!usedSids.containsKey(sid)) {
            usedSids[sid] = i;
            continue;
          }
          // Duplicate SID — try wide, letterbox, pan-scan stream_nrs in order.
          final ctrl = bd.getUint32(pgc + 0x1C + i * 4, Endian.big);
          final altNrs = [
            (ctrl >> 16) & 0x1F, // widescreen stream_nr
            (ctrl >>  8) & 0x1F, // letterbox stream_nr
             ctrl        & 0x1F, // pan-scan stream_nr
          ];
          for (final nr in altNrs) {
            final altSid = 0x20 + nr;
            if (!usedSids.containsKey(altSid)) {
              subStreamIds[i] = altSid;
              usedSids[altSid] = i;
              break;
            }
          }
          // If still duplicate after all alternatives, fall back to IFO index.
          if (subStreamIds[i] == sid) {
            subStreamIds[i] = 0x20 + i;
          }
        }
      }

      final audioTracks = <AudioTrack>[];
      for (final entry in vtsAudio.entries) {
        if (pgcOk && !activeAudio.contains(entry.key)) continue;
        final a = entry.value;
        audioTracks.add(AudioTrack(
          index:    entry.key,
          streamId: audioStreamIds[entry.key] ?? (0x80 + entry.key),
          language: a.lang,
          codec:    a.codec,
          channels: a.channels,
        ));
      }

      final subtitleTracks = <SubtitleTrack>[];
      for (final entry in vtsSub.entries) {
        if (pgcOk && !activeSubs.contains(entry.key)) continue;
        subtitleTracks.add(SubtitleTrack(
          index:    entry.key,
          streamId: subStreamIds[entry.key] ?? (0x20 + entry.key),
          language: entry.value,
        ));
      }

      // Cell table + chapter timestamps for this PGC
      final cells    = <({int first, int last})>[];
      final chapters = <Duration>[];
      try {
        final cpbitRel   = bd.getUint16(pgc + 0xE8, Endian.big);
        final cpbitOff   = pgc + cpbitRel;
        final nrCells    = data[pgc + 3];
        final nrPrograms = data[pgc + 2];
        int bcdV(int b) => ((b >> 4) & 0xF) * 10 + (b & 0xF);

        // Read each cell: sector range + duration (for chapter timing).
        final cellSecs = <int>[];
        for (var c = 0; c < nrCells; c++) {
          final coff = cpbitOff + c * 24;
          if (coff + 24 > data.length) break;
          final first = bd.getUint32(coff + 8,  Endian.big);
          final last  = bd.getUint32(coff + 20, Endian.big);
          final h = bcdV(data[coff + 4]);
          final m = bcdV(data[coff + 5]);
          final s = bcdV(data[coff + 6]);
          cellSecs.add(h * 3600 + m * 60 + s);
          if (last >= first) cells.add((first: first, last: last));
        }

        // Cumulative cell start times → chapter timestamps via PGMAP.
        if (nrPrograms > 0) {
          final pgmapRel = bd.getUint16(pgc + 0xE6, Endian.big);
          final pgmapOff = pgc + pgmapRel;
          final cellStarts = <int>[0];
          for (final d in cellSecs) { cellStarts.add(cellStarts.last + d); }
          for (var prog = 0; prog < nrPrograms; prog++) {
            if (pgmapOff + prog >= data.length) break;
            final firstCell = data[pgmapOff + prog] - 1; // 0-based
            if (firstCell >= 0 && firstCell < cellStarts.length) {
              chapters.add(Duration(seconds: cellStarts[firstCell]));
            }
          }
        }
      } catch (_) {}

      // PGC Color Lookup Table at pgc + 0xA4 (16 × 4 bytes).
      // DVD format per entry: byte0=0x00, byte1=Y, byte2=Cb, byte3=Cr (BT.601).
      final clut = <int>[];
      if (pgc + 0xA4 + 64 <= data.length) {
        for (var i = 0; i < 16; i++) {
          final y  = data[pgc + 0xA4 + i * 4 + 1];
          final cb = data[pgc + 0xA4 + i * 4 + 2];
          final cr = data[pgc + 0xA4 + i * 4 + 3];
          clut.add(_ycbcrToRgb(y, cb, cr));
        }
      }

      results.add(DvdTitle(
        vtsNumber:      vtsNum,
        pgcIndex:       pgcIdx,
        totalAngles:    nrPgc,
        duration:       Duration(seconds: durSeconds),
        audioTracks:    audioTracks,
        subtitleTracks: subtitleTracks,
        cells:          cells,
        chapters:       chapters,
        clut:           clut,
        videoHeight:    videoHeight,
      ));
    }
    return results;
  }

  // ---------------------------------------------------------------------------
  // Language collection (interactive)
  // ---------------------------------------------------------------------------

  static ({List<String> audioLangs, List<String> subLangs}) _collectLanguages(
    DvdTitle title, {
    bool force = false,
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
      force:         force,
    );
  }

  // ---------------------------------------------------------------------------
  // VOB scan: find MPEG-PS private stream 1 sub-IDs for correct stream mapping
  // ---------------------------------------------------------------------------

  /// Streams through [src] looking for MPEG-PS private-stream-1 (0xBD) packets
  /// Scans [src] for MPEG-PS private-stream-1 (0xBD) packets and records each
  /// unique sub-stream ID in [wantedSids] in order of first appearance.
  /// Stops as soon as all wanted SIDs have been found.
  ///
  /// Only IFO-declared SIDs are passed as [wantedSids]. Scanning broader sets
  /// (e.g. all 0x80–0x8F) picks up spurious SIDs from other angles in
  /// multi-angle VOBs, inflating audio-index counts and causing invalid -map
  /// arguments in ffmpeg.
  ///
  /// Returns the SID discovery order and the byte offset at which the last SID
  /// was found. The caller uses [lastSidByteOffset] to set ffmpeg's -probesize
  /// so that ffmpeg discovers every stream before writing the MKV header.
  static Future<({List<int> sidOrder, int lastSidByteOffset})> _scanVobSids(
    Stream<List<int>> src,
    Set<int> wantedSids,
  ) async {
    if (wantedSids.isEmpty) return (sidOrder: <int>[], lastSidByteOffset: 0);

    // Keep the last [carrySize] bytes of the previous chunk to handle MPEG-PS
    // packet headers that straddle chunk boundaries. A PES header is at most
    // 3 (fixed) + 255 (extension) + 1 (sub-stream ID) = 259 bytes from the
    // start of the start-code, so 512 bytes of carry is more than sufficient.
    // Safety cap: stop scanning after 600 MB even if not all SIDs are found.
    // Die Hard 4.0 SE has an audio SID (0x85) at 281.9 MB and First Blood 3
    // has its only subtitle SID at 518.8 MB — both must be within the cap so
    // ffmpeg sees them during probing and doesn't discover them mid-encode.
    // const kScanCap  = 600 * 1024 * 1024;
    const kScanCap  = 60000 * 1024 * 1024;
    const carrySize = 512;
    final order   = <int>[];
    final seen    = <int>{};
    var   totalBytes              = 0;
    // var   lastTrackedSidByteOffset = 0; // position of last SID added to order
    var   carry                   = Uint8List(0);

    await for (final chunk in src) {
      final window = Uint8List(carry.length + chunk.length)
        ..setRange(0, carry.length, carry)
        ..setRange(carry.length, carry.length + chunk.length, chunk);

      // final winBase = totalBytes - carry.length;
      var   i = 0;

      while (i < window.length - 9) {
        if (window[i]   == 0x00 && window[i+1] == 0x00 &&
            window[i+2] == 0x01 && window[i+3] == 0xBD) {
          final pktLen = (window[i+4] << 8) | window[i+5];
          final hdrLen = window[i + 8];
          final sidOff = i + 9 + hdrLen;
          if (sidOff < window.length) {
            final sid = window[sidOff];
            if (!seen.contains(sid)) {
              // Track ALL subtitle SIDs (0x20–0x3F) even if not in wantedSids.
              // DVDs sometimes store companion subtitle streams for different
              // display modes (widescreen/letterbox) alongside the declared
              // streams. ffmpeg counts all of them when assigning stream indices,
              // so we must include them in the discovery order too.
              final isWanted  = wantedSids.contains(sid);
              final isSubSid  = sid >= 0x20 && sid <= 0x3F;
              if (isWanted || isSubSid) {
                order.add(sid);
                seen.add(sid);
                // lastTrackedSidByteOffset = winBase + sidOff;
              }
              if (isWanted) {
                final wantedSeen = seen.intersection(wantedSids);
                if (wantedSeen.length == wantedSids.length) {
                  // return (sidOrder: order, lastSidByteOffset: lastTrackedSidByteOffset);
                }
              }
            }
          }
          final step = pktLen > 0 ? 6 + pktLen : 1;
          if (i + step >= window.length) break;
          i += step;
        } else {
          i++;
        }
      }

      totalBytes += chunk.length;
      if (totalBytes >= kScanCap) { // Safety cap — don't scan the entire VOB
        print('DEBUG: Scan cap reached at $totalBytes bytes');
        print('DEBUG: Found SIDs: $seen');
        print('DEBUG: Wanted SIDs: $wantedSids');
        print('DEBUG: Missing: ${wantedSids.difference(seen)}');
        break;
      }
      final keepFrom = window.length > carrySize ? window.length - carrySize : 0;
      carry = window.sublist(keepFrom);
    }

    return (sidOrder: order, lastSidByteOffset: totalBytes);
  }

  // ---------------------------------------------------------------------------
  // Build ffmpeg map + metadata arguments
  // ---------------------------------------------------------------------------

  /// Builds -map and -metadata arguments based on the VOB SID scan.
  ///
  /// Method (identical to rip.sh + dvdread_pipe.py):
  /// 1. Determine per SID the ffmpeg discovery index (separate for audio and subs).
  /// 2. Use explicit -map 0:a:FF_IDX / -map 0:s:FF_IDX? in IFO order.
  /// 3. Metadata uses output indices 0,1,2... (= IFO order), not ffmpeg discovery order.
  static List<String> _buildMapAndMetaArgs({
    required DvdTitle title,
    required List<int> sidOrder,    // MPEG SIDs in ffmpeg discovery order
    required List<String> audioLangs,
    required List<String> subLangs,
  }) {
    // Build SID → ffmpeg discovery index, separate per type (a:N and s:N count separately)
    final audioSidToFf = <int, int>{};
    final subSidToFf   = <int, int>{};
    var aCount = 0;
    var sCount = 0;
    for (final sid in sidOrder) {
      // Audio ranges: AC3/DTS 0x80–0x8F, LPCM 0xA0–0xA7
      if (((sid >= 0x80 && sid <= 0x8F) || (sid >= 0xA0 && sid <= 0xA7)) &&
          !audioSidToFf.containsKey(sid)) {
        audioSidToFf[sid] = aCount++;
      } else if (sid >= 0x20 && sid <= 0x3F && !subSidToFf.containsKey(sid)) {
        subSidToFf[sid] = sCount++;
      }
    }

    final args = <String>['-map', '0:v'];

    // Audio maps in IFO order; for missing SIDs: ascending fallback index
    for (final a in title.audioTracks) {
      final ffIdx = audioSidToFf[a.streamId] ?? aCount++;
      args.addAll(['-map', '0:a:$ffIdx']);
    }

    // Subtitle maps in IFO order — include all tracks, even if multiple share
    // the same sub-stream ID.
    for (final s in title.subtitleTracks) {
      final ffIdx = subSidToFf[s.streamId] ?? sCount++;
      args.addAll(['-map', '0:s:$ffIdx?']);
    }

    args.addAll([
      '-c:v', 'copy',
      '-c:a', 'copy',
      '-c:s', 'copy',
      '-avoid_negative_ts', 'make_zero',
    ]);

    // Metadata: output indices 0,1,2... = IFO order (from explicit -map above)

    // Video language: take from first audio track (DVD has no per-stream video language)
    if (audioLangs.isNotEmpty && audioLangs.first.isNotEmpty) {
      args.addAll(['-metadata:s:v:0', 'language=${audioLangs.first}']);
    }

    for (var i = 0; i < title.audioTracks.length; i++) {
      final a = title.audioTracks[i];
      if (audioLangs[i].isNotEmpty) {
        args.addAll(['-metadata:s:a:$i', 'language=${audioLangs[i]}']);
      }
      args.addAll(['-metadata:s:a:$i', 'title=${a.codec} ${channelLabel(a.channels)}']);
    }
    for (var i = 0; i < title.subtitleTracks.length; i++) {
      if (subLangs[i].isNotEmpty) {
        args.addAll(['-metadata:s:s:$i', 'language=${subLangs[i]}']);
      }
    }

    // Subtitle dispositions: mark the first track as default, rest as 0.
    // All tracks use '-map 0:s:N?' so non-existent streams are silently skipped
    // by ffmpeg; the disposition args reference output indices which match
    // because the optional maps keep IFO order.
    if (title.subtitleTracks.isNotEmpty) {
      args.addAll(['-disposition:s:0', 'default']);
      for (var i = 1; i < title.subtitleTracks.length; i++) {
        args.addAll(['-disposition:s:$i', '0']);
      }
    }

    return args;
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

  /// Converts a DVD YCbCr color (BT.601 studio swing) to 0xRRGGBB.
  static int _ycbcrToRgb(int y, int cb, int cr) {
    final r = (1.164 * (y - 16) + 1.596 * (cr - 128)).round().clamp(0, 255);
    final g = (1.164 * (y - 16) - 0.391 * (cb - 128) - 0.813 * (cr - 128)).round().clamp(0, 255);
    final b = (1.164 * (y - 16) + 2.018 * (cb - 128)).round().clamp(0, 255);
    return (r << 16) | (g << 8) | b;
  }

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
      stderr.writeln('   mkvtoolnix not found — subtitle palette not injected.'
          ' Install mkvtoolnix for correct subtitle colors.');
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
        stderr.writeln('   mkvextract warning: ${(extract.stderr as String).trim()}');
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
        stderr.writeln('   Subtitle palette not injected: not enough free space'
            ' (need ${fileSize ~/ 1048576} MiB, have ${availBytes ~/ 1048576} MiB).');
        return;
      }
      stdout.writeln('   Injecting subtitle palette (remux)…');
      final fixedPath = p.join(outFile.parent.path,
          '${p.basenameWithoutExtension(outFile.path)}.fixed.mkv');
      final mergeArgs = ['-o', fixedPath, '--no-subtitles', outFile.path,
          ...idxPaths];
      final merge = await Process.run('mkvmerge', mergeArgs);
      // mkvmerge exit codes: 0 = success, 1 = success with warnings, 2 = error.
      if (merge.exitCode >= 2) {
        final out = (merge.stdout as String).trim();
        final err = (merge.stderr as String).trim();
        stderr.writeln('   mkvmerge failed (exit ${merge.exitCode}):');
        if (out.isNotEmpty) stderr.writeln('   stdout: $out');
        if (err.isNotEmpty) stderr.writeln('   stderr: $err');
        await File(fixedPath).delete().catchError((_) => File(fixedPath));
        return;
      }

      // --- 5. Replace original with fixed file. ---
      await File(fixedPath).rename(outFile.path);
    } finally {
      await tmpDir.delete(recursive: true);
    }
  }

  /// Returns the MPEG sub-stream ID (0x20–0x3F) for a PGC subpicture control
  /// word, or null if the track is inactive in all four display modes.
  ///
  /// For 16:9 content, widescreen streams are preferred so that the subtitle
  /// data actually present in the VOB is selected. For 4:3 content, the 4:3
  /// stream is preferred because it is always present when declared.
  static int? _pgcSubId(int ctrl, {bool prefer16x9 = false}) {
    if (prefer16x9) {
      if ((ctrl & 0x00800000) != 0) return 0x20 + ((ctrl >> 16) & 0x1F); // wide (prefer)
      if ((ctrl & 0x80000000) != 0) return 0x20 + ((ctrl >> 24) & 0x1F); // 4:3 fallback
      if ((ctrl & 0x00008000) != 0) return 0x20 + ((ctrl >>  8) & 0x1F); // letterbox
      if ((ctrl & 0x00000080) != 0) return 0x20 +  (ctrl        & 0x1F); // pan-scan
    } else {
      if ((ctrl & 0x80000000) != 0) return 0x20 + ((ctrl >> 24) & 0x1F); // 4:3 (prefer)
      if ((ctrl & 0x00800000) != 0) return 0x20 + ((ctrl >> 16) & 0x1F); // wide
      if ((ctrl & 0x00008000) != 0) return 0x20 + ((ctrl >>  8) & 0x1F); // letterbox
      if ((ctrl & 0x00000080) != 0) return 0x20 +  (ctrl        & 0x1F); // pan-scan
    }
    return null;
  }

  // Exposed for unit tests only.
  static int? pgcSubIdForTest(int ctrl, {bool prefer16x9 = false}) =>
      _pgcSubId(ctrl, prefer16x9: prefer16x9);

  static String _readAsciiFixed(Uint8List data, int offset, int length) {
    if (offset + length > data.length) return '';
    return String.fromCharCodes(
      data.sublist(offset, offset + length)
          .where((b) => b >= 0x20 && b < 0x7F),
    ).trim();
  }
}
