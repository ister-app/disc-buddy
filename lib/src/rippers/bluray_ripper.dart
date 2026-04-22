import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../ffmpeg/ffmpeg_runner.dart';
import '../models/bluray_title.dart';
import '../models/rip_options.dart';
import 'video_disc_ripper.dart';
import '../utils/file_utils.dart';
import '../utils/languages.dart';
import '../utils/mount.dart';
import '../utils/progress.dart';
import '../utils/sanitize.dart';

class BlurayRipper implements VideoDiscRipper<BlurayTitle> {
  final RipOptions options;
  final FfmpegRunner _ffmpeg;

  BlurayRipper(this.options) : _ffmpeg = FfmpegRunner(executable: options.ffmpeg);

  /// Scans the Blu-ray via MPLS and CLPI files (pure Dart).
  /// Returns null on error.
  ///
  /// If [mountPath] is provided the disc is assumed to be already mounted there
  /// and no additional mount/unmount cycle is performed.
  @override
  Future<({String discTitle, List<BlurayTitle> titles})?> loadTitles(
      {String? mountPath}) async {
    if (mountPath != null) return _scanMounted(mountPath);
    return withMountedDisc(
      options.device!,
      (mp) => _scanMounted(mp),
      errorContext: 'Blu-ray',
    );
  }

  /// Rips the selected titles as lossless MKV.
  /// Uses libbluray (via ffmpeg) if available, otherwise direct M2TS concat.
  ///
  /// If [mountPath] is provided the disc is assumed to be already mounted there
  /// and no additional mount/unmount cycle is performed.
  @override
  Future<void> rip(String discTitle, List<BlurayTitle> selected,
      {String? mountPath}) async {
    final outDir = Directory(p.join(options.outputDir, sanitizeFilename(discTitle)));
    await outDir.create(recursive: true);

    final hasLibbluray = await _checkLibbluray();

    if (mountPath != null) {
      await _ripMounted(mountPath, discTitle, selected, outDir, hasLibbluray);
    } else {
      await withMountedDisc<Object?>(options.device!, (mp) =>
          _ripMounted(mp, discTitle, selected, outDir, hasLibbluray));
    }
  }

  Future<void> _ripMounted(
    String mountPath,
    String discTitle,
    List<BlurayTitle> selected,
    Directory outDir,
    bool hasLibbluray,
  ) async {
    // AACS/BD+ detection
    final isEncrypted = await _detectEncryption(mountPath);
    if (isEncrypted) {
      // 4K UHD check: use hasHevc cached in the model — no extra CLPI parse needed.
      final isUhd = selected.isNotEmpty && selected.first.hasHevc;

      if (isUhd) {
        stderr.writeln('');
        stderr.writeln('   ⚠  4K Ultra HD Blu-ray gedetecteerd (AACS 2.0).');
        stderr.writeln('   libaacs en libbluray ondersteunen alleen AACS 1.0 (standaard Blu-ray).');
        stderr.writeln('');
        return;
      } else if (!hasLibbluray) {
        stderr.writeln('');
        stderr.writeln('   ⚠  Encrypted Blu-ray detected and ffmpeg lacks libbluray.');
        for (final line in const [
          '   Install ffmpeg with libbluray support:',
          '      sudo dnf install ffmpeg-free --allowerasing   # Fedora RPMFusion',
          '      or: sudo dnf install ffmpeg-full              # if available',
          '   For AACS decryption you also need:',
          '      sudo dnf install libaacs',
          '      and: ~/.config/aacs/KEYDB.cfg  (from makemkv or oss-blu-ray)',
        ]) {
          stderr.writeln(line);
        }
        stderr.writeln('');
      } else if (_findKeydb() == null) {
        stderr.writeln('');
        stderr.writeln('   ⚠  Encrypted Blu-ray — libbluray present but no KEYDB.cfg.');
        stderr.writeln('   Place KEYDB.cfg in ~/.config/aacs/ for AACS decryption.');
        stderr.writeln('');
      }
    }

    if (hasLibbluray) {
      stdout.writeln('   (libbluray available — AACS decryption active if configured)');
    } else {
      stdout.writeln('   (libbluray not found — direct M2TS mode)');
    }

    // Phase 1: collect languages for all titles upfront
    final langsMap = <BlurayTitle, ({List<String> audioLangs, List<String> subLangs})>{};
    for (final title in selected) {
      stdout.writeln('── Languages: playlist ${title.playlist} [${title.durationLabel}]');
      langsMap[title] = _collectLanguages(title, force: options.force);
    }
    if (!options.force) stdout.writeln('');

    // Phase 2: rip
    for (final title in selected) {
      await _ripTitle(title, outDir, mountPath, hasLibbluray, langsMap[title]!, discTitle);
    }
  }

  // ---------------------------------------------------------------------------
  // Scan: MPLS + CLPI
  // ---------------------------------------------------------------------------

  Future<({String discTitle, List<BlurayTitle> titles})?> _scanMounted(
    String mountPath,
  ) async {
    final bdmvPath    = p.join(mountPath, 'BDMV');
    final playlistDir = Directory(p.join(bdmvPath, 'PLAYLIST'));

    if (!await playlistDir.exists()) {
      stderr.writeln('Error: BDMV/PLAYLIST not found at $mountPath');
      return null;
    }

    final discTitle =
        await _readDiscTitle(bdmvPath) ?? p.basename(mountPath);

    final mplsFiles = await playlistDir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.mpls'))
        .map((e) => e as File)
        .toList();

    mplsFiles.sort((a, b) => a.path.compareTo(b.path));

    final titles = <BlurayTitle>[];
    for (var i = 0; i < mplsFiles.length; i++) {
      final title = await _parseMpls(mplsFiles[i], bdmvPath, i + 1);
      if (title != null) titles.add(title);
    }

    if (titles.isEmpty) {
      stderr.writeln('Error: no titles found on the Blu-ray.');
      return null;
    }

    return (discTitle: discTitle, titles: titles);
  }

  static Future<String?> _readDiscTitle(String bdmvPath) async {
    final metaDir = Directory(p.join(bdmvPath, 'META', 'DL'));
    if (!await metaDir.exists()) return null;
    try {
      final xmlFiles = await metaDir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.xml'))
          .map((e) => e as File)
          .toList();
      for (final xml in xmlFiles) {
        final content = await xml.readAsString();
        final m = RegExp(r'<di:name>\s*([^<]+?)\s*</di:name>').firstMatch(content);
        if (m != null) return m.group(1);
      }
    } catch (_) {}
    return null;
  }

  /// Parses one MPLS file.
  ///
  /// MPLS layout:
  ///   0: magic "MPLS" (4B)
  ///   4: version (4B)
  ///   8: playlist_start_address (uint32 BE)
  ///
  /// PlayList() at playlist_start_address:
  ///   +0: length (uint32 BE)
  ///   +6: number_of_PlayItems (uint16 BE)
  ///   +10: first PlayItem
  ///
  /// PlayItem():
  ///   +0: length (uint16 BE)    — length excluding this field
  ///   +2..+6: clip_name (5B)    — e.g. "00001"
  ///   +7..+10: codec_id (4B)    — "M2TS"
  ///   +11: flags (1B)
  ///   +12: ref_to_STC_id (1B)
  ///   +13: IN_time  (uint32 BE, 45 kHz ticks)
  ///   +17: OUT_time (uint32 BE, 45 kHz ticks)
  static Future<BlurayTitle?> _parseMpls(
    File mplsFile,
    String bdmvPath,
    int index,
  ) async {
    final Uint8List data;
    try {
      data = await mplsFile.readAsBytes();
    } catch (_) {
      return null;
    }

    if (data.length < 20) return null;
    if (String.fromCharCodes(data.sublist(0, 4)) != 'MPLS') return null;

    final bd             = ByteData.sublistView(data);
    final playlistOffset = bd.getUint32(8, Endian.big);
    if (playlistOffset + 10 > data.length) return null;

    final nrItems   = bd.getUint16(playlistOffset + 6, Endian.big);
    if (nrItems == 0) return null;

    var   itemOffset    = playlistOffset + 10;
    var   totalTicks    = 0;
    final clipNames     = <String>[];
    final itemInTimes   = <int>[];   // IN_time per PlayItem (45 kHz)
    final itemTicksList = <int>[];   // (OUT − IN) ticks per PlayItem

    for (var i = 0; i < nrItems; i++) {
      if (itemOffset + 20 > data.length) break;
      final itemLen = bd.getUint16(itemOffset, Endian.big);
      if (itemLen < 16) break;

      clipNames.add(String.fromCharCodes(data.sublist(itemOffset + 2, itemOffset + 7)));

      // PlayItem layout (from PlayItem start, including 2-byte length field):
      //   +0  length (uint16)
      //   +2  clip_id (5B)
      //   +7  codec_id (4B)
      //   +11 flags (2B: 6+1+4+1 bits, padded to byte boundary)
      //   +13 ref_to_STC_id (1B)
      //   +14 IN_time (uint32 BE, 45 kHz)
      //   +18 OUT_time (uint32 BE, 45 kHz)
      final inTime  = bd.getUint32(itemOffset + 14, Endian.big);
      final outTime = bd.getUint32(itemOffset + 18, Endian.big);
      final ticks   = outTime > inTime ? outTime - inTime : 0;
      totalTicks += ticks;
      itemInTimes.add(inTime);
      itemTicksList.add(ticks);

      itemOffset += 2 + itemLen;
    }

    if (totalTicks == 0 || clipNames.isEmpty) return null;

    // Parse PlayListMark for chapter entry marks (mark_type 0x01).
    // Mark entry: reserved(1B) + mark_type(1B) + ref_to_PlayItem_id(uint16 BE)
    //           + mark_timestamp(uint32 BE, 45kHz) + entry_ES_PID(uint16 BE)
    //           + duration(uint32 BE, 45kHz)  → 14 bytes total.
    final chapters = <Duration>[];
    try {
      final markAddr = bd.getUint32(12, Endian.big);
      if (markAddr + 6 <= data.length) {
        final nrMarks = bd.getUint16(markAddr + 4, Endian.big);
        // Cumulative 45 kHz ticks at the start of each PlayItem.
        final cumTicks = <int>[0];
        for (final t in itemTicksList) { cumTicks.add(cumTicks.last + t); }
        for (var m = 0; m < nrMarks; m++) {
          final mOff = markAddr + 6 + m * 14;
          if (mOff + 14 > data.length) break;
          final markType = data[mOff + 1];
          final itemId   = bd.getUint16(mOff + 2, Endian.big);
          final ts       = bd.getUint32(mOff + 4, Endian.big);
          if (markType == 0x01 && itemId < itemInTimes.length) {
            final ticksFromStart = cumTicks[itemId] + ts - itemInTimes[itemId];
            if (ticksFromStart >= 0) {
              chapters.add(Duration(milliseconds: (ticksFromStart / 45.0).round()));
            }
          }
        }
      }
    } catch (_) {}

    final duration = Duration(milliseconds: (totalTicks / 45.0).round());

    // Stream info from the first CLPI — parsed once here and stored in the model.
    var audioLangs       = <String>[];
    var subtitleLangs    = <String>[];
    var lpcmAudioIndices = <int>{};
    var audioTitles      = <String>[];
    var hasHevc          = false;

    for (final clipName in clipNames) {
      final clpiFile = File(p.join(bdmvPath, 'CLIPINF', '$clipName.clpi'));
      final info = await _parseClpi(clpiFile);
      if (info != null) {
        audioLangs       = info.audioLangs;
        subtitleLangs    = info.subtitleLangs;
        lpcmAudioIndices = info.lpcmAudioIndices;
        audioTitles      = info.audioTitles;
        hasHevc          = info.hasHevc;
        break;
      }
    }

    final playlist = p.basenameWithoutExtension(mplsFile.path);

    return BlurayTitle(
      index:            index,
      playlist:         playlist,
      duration:         duration,
      audioCount:       audioLangs.length,
      subtitleCount:    subtitleLangs.length,
      audioLangs:       audioLangs,
      subtitleLangs:    subtitleLangs,
      chapters:         chapters,
      clipNames:        clipNames,
      lpcmAudioIndices: lpcmAudioIndices,
      audioTitles:      audioTitles,
      hasHevc:          hasHevc,
    );
  }

  /// Parses one CLPI file for language and stream information.
  ///
  /// CLPI layout:
  ///   0: magic "HDMV" (4B)
  ///   4: version (4B)
  ///   8: sequence_info_start_address (uint32 BE)
  ///   12: program_info_start_address (uint32 BE)
  ///
  /// ProgramInfo() at program_info_start_address:
  ///   +4: reserved (1B)
  ///   +5: number_of_program_sequences (uint8)
  ///
  /// Each ProgramSequence:
  ///   +0: SPN (uint32 BE)
  ///   +4: program_map_pid (uint16 BE)
  ///   +6: number_of_streams_in_ps (uint8)
  ///   +7: number_of_groups_in_ps (uint8)
  ///   then per stream:
  ///     +0..+1: stream_pid (uint16 BE)
  ///     +2: entry_len (uint8)
  ///     +3: coding_type (uint8)
  ///     +4..: codec attributes
  ///       audio (0x80-0x86, 0xA1, 0xA2): format+rate (1B), lang (3B) → lang @ +5..+7
  ///       sub   (0x90):                   lang (3B)               → lang @ +4..+6
  ///   total size: 3 + entry_len bytes
  static const _codingTypeNames = {
    0x80: 'LPCM',    0x81: 'AC3',       0x82: 'DTS',
    0x83: 'TrueHD',  0x84: 'E-AC3',     0x85: 'DTS-HD HR',
    0x86: 'DTS-HD MA', 0xA1: 'E-AC3',   0xA2: 'DTS-HD',
  };

  static const _audioFormatChannels = {
    0x01: 'Mono', 0x03: 'Stereo',
    0x06: '5.1',  0x09: '7.1', 0x0C: '7.1',
  };

  static Future<({List<String> audioLangs, List<String> subtitleLangs, Set<int> lpcmAudioIndices, List<String> audioTitles, bool hasHevc})?> _parseClpi(
    File clpiFile,
  ) async {
    final Uint8List data;
    try {
      data = await clpiFile.readAsBytes();
    } catch (_) {
      return null;
    }

    if (data.length < 20) return null;
    if (String.fromCharCodes(data.sublist(0, 4)) != 'HDMV') return null;

    final bd      = ByteData.sublistView(data);
    final progOff = bd.getUint32(12, Endian.big);
    if (progOff + 6 > data.length) return null;

    final nrSeqs = data[progOff + 5];
    if (nrSeqs == 0) return null;

    final audioLangs       = <String>[];
    final subtitleLangs    = <String>[];
    final lpcmAudioIndices = <int>{};
    final audioTitles      = <String>[];
    var   hasHevc          = false;

    // First program sequence contains all streams
    final seqOff = progOff + 6;
    if (seqOff + 8 <= data.length) {
      final nrStreams = data[seqOff + 6];
      var   strmOff  = seqOff + 8;
      var   audioIdx = 0;

      for (var i = 0; i < nrStreams; i++) {
        if (strmOff + 4 > data.length) break;
        final entryLen   = data[strmOff + 2];
        final codingType = data[strmOff + 3];

        // Video: MPEG-1 (0x01), MPEG-2 (0x02), VC-1 (0xEA), AVC (0x1B), HEVC (0x24)
        if (codingType == 0x24) hasHevc = true;

        // Audio: LPCM (0x80), AC3 (0x81), DTS (0x82), TrueHD (0x83),
        //        AC3+ (0x84), DTS-HD HR (0x85), DTS-HD MA (0x86),
        //        AC3+ sec (0xA1), DTS-HD sec (0xA2)
        final isAudio = (codingType >= 0x80 && codingType <= 0x86) ||
            codingType == 0xA1 || codingType == 0xA2;
        // Subtitle: PG (0x90) — not IG (menus)
        final isSub = codingType == 0x90;

        if (isAudio && strmOff + 8 <= data.length) {
          if (codingType == 0x80) lpcmAudioIndices.add(audioIdx); // LPCM → needs FLAC
          final raw = String.fromCharCodes(
            data.sublist(strmOff + 5, strmOff + 8).where((b) => b >= 0x20),
          );
          audioLangs.add(convertIso2Tto2B(raw.trim()));

          final codecName = _codingTypeNames[codingType] ?? '';
          final fmtNibble = (data[strmOff + 4] >> 4) & 0x0F;
          final chLabel   = _audioFormatChannels[fmtNibble] ?? '';
          audioTitles.add('$codecName $chLabel'.trim());
          audioIdx++;
        } else if (isSub && strmOff + 7 <= data.length) {
          final raw = String.fromCharCodes(
            data.sublist(strmOff + 4, strmOff + 7).where((b) => b >= 0x20),
          );
          subtitleLangs.add(convertIso2Tto2B(raw.trim()));
        }

        strmOff += 3 + entryLen;
      }
    }

    return (audioLangs: audioLangs, subtitleLangs: subtitleLangs, lpcmAudioIndices: lpcmAudioIndices, audioTitles: audioTitles, hasHevc: hasHevc);
  }

  // ---------------------------------------------------------------------------
  // Ripping
  // ---------------------------------------------------------------------------

  Future<void> _ripTitle(
    BlurayTitle title,
    Directory outDir,
    String mountPath,
    bool useLibbluray,
    ({List<String> audioLangs, List<String> subLangs}) langs,
    String discTitle,
  ) async {
    final outFile = File(p.join(outDir.path, '${sanitizeFilename(discTitle)}-${title.filename}'));
    stdout.writeln('── Ripping: playlist ${title.playlist} → ${outFile.path}');

    if (!await confirmOverwrite(outFile, force: options.force)) return;

    final bdmvPath   = p.join(mountPath, 'BDMV');
    final playlistNr = int.tryParse(title.playlist) ?? 1;

    // Clip names and LPCM info were cached in the model during the scan phase.
    final clipNames  = title.clipNames;
    final lpcmIdx    = title.lpcmAudioIndices;
    final audioTitles = title.audioTitles;

    final chapterFile = await writeChapterMetadata(title.chapters, title.duration);

    // Build ffmpeg arguments
    final List<String> args;
    if (useLibbluray) {
      args = _buildLibblurayArgs(
        mountPath:    mountPath,
        playlistNr:   playlistNr,
        audioLangs:   langs.audioLangs,
        subLangs:     langs.subLangs,
        lpcmIdx:      lpcmIdx,
        audioTitles:  audioTitles,
        chapterFile:  chapterFile,
        outPath:      outFile.path,
      );
    } else {
      final m2tsFiles = clipNames
          .map((c) => p.join(bdmvPath, 'STREAM', '$c.m2ts'))
          .where((f) => File(f).existsSync())
          .toList();
      if (m2tsFiles.isEmpty) {
        await chapterFile?.delete().catchError((_) => File(''));
        stderr.writeln('   No M2TS files found for ${title.playlist}.');
        return;
      }
      args = _buildDirectArgs(
        m2tsFiles:   m2tsFiles,
        audioLangs:  langs.audioLangs,
        subLangs:    langs.subLangs,
        lpcmIdx:     lpcmIdx,
        audioTitles: audioTitles,
        chapterFile: chapterFile,
        outPath:     outFile.path,
      );
    }

    final dur      = title.duration.inSeconds;
    final exitCode = await _ffmpeg.run(
      args,
      timeout:          Duration(seconds: dur + 180),
      expectedDuration: title.duration,
      onProgress:       logProgress,
    );
    await chapterFile?.delete().catchError((_) => File(''));
    stdout.writeln('');

    final fileSize = await outFile.exists() ? await outFile.length() : 0;
    if (exitCode == 0 && fileSize > 0) {
      stdout.writeln('   Done: ${outFile.path}');
    } else {
      stderr.writeln('   Error ripping ${title.playlist} (exit code $exitCode).');
      await outFile.delete().catchError((_) => File(''));
    }
  }

  static List<String> _buildLibblurayArgs({
    required String mountPath,
    required int playlistNr,
    required List<String> audioLangs,
    required List<String> subLangs,
    required Set<int> lpcmIdx,
    required List<String> audioTitles,
    required File? chapterFile,
    required String outPath,
  }) {
    final args = [
      '-loglevel', 'warning', '-stats',
      '-analyzeduration', '500M',
      '-probesize', '500M',
      '-playlist', playlistNr.toString(),
      '-i', 'bluray:$mountPath',
      if (chapterFile != null) ...['-i', chapterFile.path, '-map_chapters', '1'],
      '-map', '0:v',
      '-map', '0:a',
      '-map', '0:s?',
      '-c:v', 'copy',
    ];

    // Per-stream audio codec: LPCM (0x80) → FLAC, others → copy
    for (var i = 0; i < audioLangs.length; i++) {
      args.addAll(['-c:a:$i', lpcmIdx.contains(i) ? 'flac' : 'copy']);
    }
    if (audioLangs.isEmpty) args.addAll(['-c:a', 'copy']); // fallback when count unknown

    args.addAll(['-c:s', 'copy']);
    _addMetadata(args, audioLangs, subLangs, audioTitles);
    args.add(outPath);
    return args;
  }

  static List<String> _buildDirectArgs({
    required List<String> m2tsFiles,
    required List<String> audioLangs,
    required List<String> subLangs,
    required Set<int> lpcmIdx,
    required List<String> audioTitles,
    required File? chapterFile,
    required String outPath,
  }) {
    final inputArg = m2tsFiles.length == 1
        ? m2tsFiles.first
        : 'concat:${m2tsFiles.join('|')}';

    final args = [
      '-loglevel', 'warning', '-stats',
      '-analyzeduration', '500M',
      '-probesize', '500M',
      '-i', inputArg,
      if (chapterFile != null) ...['-i', chapterFile.path, '-map_chapters', '1'],
      '-map', '0:v',
      '-map', '0:a',
      '-map', '0:s?',
      '-c:v', 'copy',
    ];

    for (var i = 0; i < audioLangs.length; i++) {
      args.addAll(['-c:a:$i', lpcmIdx.contains(i) ? 'flac' : 'copy']);
    }
    if (audioLangs.isEmpty) args.addAll(['-c:a', 'copy']);

    args.addAll(['-c:s', 'copy']);
    _addMetadata(args, audioLangs, subLangs, audioTitles);
    args.add(outPath);
    return args;
  }

  static void _addMetadata(
    List<String> args,
    List<String> audioLangs,
    List<String> subLangs,
    List<String> audioTitles,
  ) {
    for (var i = 0; i < audioLangs.length; i++) {
      if (audioLangs[i].isNotEmpty) {
        args.addAll(['-metadata:s:a:$i', 'language=${audioLangs[i]}']);
      }
      if (i < audioTitles.length && audioTitles[i].isNotEmpty) {
        args.addAll(['-metadata:s:a:$i', 'title=${audioTitles[i]}']);
      }
    }
    for (var i = 0; i < subLangs.length; i++) {
      if (subLangs[i].isNotEmpty) {
        args.addAll(['-metadata:s:s:$i', 'language=${subLangs[i]}']);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Checks whether ffmpeg has libbluray support.
  Future<bool> _checkLibbluray() async {
    for (final flag in ['-demuxers', '-buildconf', '-protocols']) {
      final result = await Process.run(options.ffmpeg, ['-hide_banner', flag]);
      final output = '${result.stdout}${result.stderr}'.toLowerCase();
      if (output.contains('bluray') || output.contains('libbluray')) return true;
    }
    return false;
  }

  /// Detects AACS or BD+ encryption on the mounted disc.
  static Future<bool> _detectEncryption(String mountPath) async {
    if (await File(p.join(mountPath, 'AACS', 'Unit_Key_RO.inf')).exists()) return true;
    if (await Directory(p.join(mountPath, 'AACS')).exists()) return true;
    if (await Directory(p.join(mountPath, 'BDSVM')).exists()) return true;
    if (await Directory(p.join(mountPath, 'CERTIFICATE')).exists()) return true;
    return false;
  }

  static String? _findKeydb() {
    final home = Platform.environment['HOME'] ?? '';
    for (final path in [
      p.join(home, '.config', 'aacs', 'KEYDB.cfg'),
      p.join(home, '.aacs', 'KEYDB.cfg'),
      '/etc/aacs/KEYDB.cfg',
    ]) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Shows current languages (from CLPI) and optionally prompts for manual correction.
  static ({List<String> audioLangs, List<String> subLangs}) _collectLanguages(
    BlurayTitle title, {
    bool force = false,
  }) {
    return askLanguages(
      audioLabels:   const [],  // Blu-ray shows codec in audioTitles; no extra label needed
      audioCurrents: title.audioLangs,
      subCurrents:   title.subtitleLangs,
      force:         force,
    );
  }
}
