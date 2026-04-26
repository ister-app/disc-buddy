import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../rippers/video_disc_ripper.dart' show LogCallback;

class SubtitleExtractor {
  static const _textCodecs = {
    'subrip', 'ass', 'ssa', 'mov_text', 'webvtt', 'text',
  };
  static const _imageCodecs = {
    'dvd_subtitle', 'dvdsub', 'hdmv_pgs_subtitle', 'pgssub',
  };
  // ISO 639-2/B or -3 → ISO 639-1 (2-letter) for SRT filename extension.
  static const _langMap = {
    'eng': 'en', 'nld': 'nl', 'dut': 'nl', 'fra': 'fr', 'fre': 'fr',
    'deu': 'de', 'ger': 'de', 'spa': 'es', 'ita': 'it', 'por': 'pt',
    'rus': 'ru', 'jpn': 'ja', 'zho': 'zh', 'chi': 'zh', 'kor': 'ko',
    'ara': 'ar', 'pol': 'pl', 'swe': 'sv', 'nor': 'no', 'dan': 'da',
    'fin': 'fi', 'ces': 'cs', 'cze': 'cs', 'hun': 'hu', 'ron': 'ro',
    'rum': 'ro', 'tur': 'tr', 'ell': 'el', 'gre': 'el', 'heb': 'he',
    'tha': 'th', 'vie': 'vi', 'ind': 'id', 'msa': 'ms', 'may': 'ms',
  };

  // ISO 639-2/B → ISO 639-3 as used by Tesseract traineddata filenames.
  // Only needed for codes where Part2B ≠ Part2T/639-3 (e.g. dut → nld).
  static const _ocrLangMap = {
    'dut': 'nld', 'fre': 'fra', 'ger': 'deu', 'cze': 'ces',
    'rum': 'ron', 'slo': 'slk', 'wel': 'cym', 'baq': 'eus',
    'alb': 'sqi', 'arm': 'hye', 'geo': 'kat', 'ice': 'isl',
    'mac': 'mkd', 'may': 'msa', 'per': 'fas', 'gre': 'ell',
    'chi': 'chi_sim',
  };

  final String ffmpeg;
  final String ffprobe;
  final String mkvextract;
  final String subtileOcr;
  final LogCallback? onLog;

  SubtitleExtractor({
    required this.ffmpeg,
    required this.ffprobe,
    required this.mkvextract,
    required this.subtileOcr,
    this.onLog,
  });

  void _log(String msg, {bool isError = false}) {
    if (onLog != null) {
      onLog!(msg, isError: isError);
    } else if (isError) {
      stderr.writeln(msg);
    } else {
      stdout.writeln(msg);
    }
  }

  Future<void> extractAll(File mkvFile, {Set<String>? languages}) async {
    final streams = await _probeSubtitles(mkvFile);
    if (streams.isEmpty) {
      _log('   No subtitle streams found.');
      return;
    }

    final stem = mkvFile.path.replaceFirst(RegExp(r'\.mkv$'), '');
    int subIdx = 0;
    for (final stream in streams) {
      final codec   = stream['codec_name']!.toLowerCase();
      final rawLang = stream['language']!;
      final lang    = _toLangCode(rawLang);
      if (languages != null && !languages.contains(lang)) {
        subIdx++;
        continue;
      }
      final srtFile = File('$stem.$lang.srt');

      if (await srtFile.exists()) {
        _log('   Subtitle $lang: already exists, skipping.');
        subIdx++;
        continue;
      }

      bool ok;
      if (_textCodecs.contains(codec)) {
        _log('   Subtitle $lang ($codec): extracting...');
        ok = await _extractText(mkvFile, subIdx, srtFile);
      } else if (_imageCodecs.contains(codec)) {
        _log('   Subtitle $lang ($codec): running OCR...');
        ok = await _extractImage(mkvFile, subIdx, rawLang, srtFile);
      } else {
        _log('   Subtitle $lang ($codec): unsupported codec, skipping.');
        subIdx++;
        continue;
      }
      _log(ok ? '   Subtitle $lang: done → ${srtFile.path}' : '   Subtitle $lang: failed.');
      subIdx++;
    }
  }

  Future<List<Map<String, String>>> _probeSubtitles(File mkvFile) async {
    final result = await Process.run(ffprobe, [
      '-v', 'quiet',
      '-print_format', 'json',
      '-show_streams',
      mkvFile.path,
    ]);
    if (result.exitCode != 0) {
      _log('   ffprobe failed: ${result.stderr}', isError: true);
      return [];
    }
    final json   = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final all    = (json['streams'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    return all
        .where((s) => s['codec_type'] == 'subtitle')
        .map((s) => {
              'codec_name': s['codec_name']?.toString() ?? '',
              'language':
                  ((s['tags'] as Map?)?['language'])?.toString() ?? 'und',
            })
        .toList();
  }

  Future<bool> _extractText(File src, int subIdx, File srtOut) async {
    final result = await Process.run(ffmpeg, [
      '-loglevel', 'error',
      '-i', src.path,
      '-map', '0:s:$subIdx',
      '-c:s', 'srt',
      '-y',
      srtOut.path,
    ]);
    return result.exitCode == 0;
  }

  Future<bool> _extractImage(
    File src,
    int subIdx,
    String rawLang,
    File srtOut,
  ) async {
    final lang = _toOcrLang(rawLang);
    final tmpDir = await Directory('/tmp').createTemp('sub_');
    try {
      final base    = '${tmpDir.path}/track';
      final mksFile = File('$base.mks');
      final idxFile = File('$base.idx');

      // Step 1: ffmpeg → dvdsub MKS
      final ffmpegResult = await Process.run(ffmpeg, [
        '-loglevel', 'error',
        '-i', src.path,
        '-map', '0:s:$subIdx',
        '-c:s', 'dvdsub',
        '-f', 'matroska',
        '-y',
        mksFile.path,
      ]);
      if (ffmpegResult.exitCode != 0) {
        _log('ffmpeg (step 1) failed (exit ${ffmpegResult.exitCode}):', isError: true);
        if ((ffmpegResult.stderr as String).isNotEmpty) {
          _log(ffmpegResult.stderr as String, isError: true);
        }
        return false;
      }

      // Step 2: mkvextract → .sub + .idx
      final mkvResult = await Process.run(mkvextract, [
        mksFile.path, 'tracks', '0:$base',
      ]).timeout(const Duration(minutes: 10));
      if (mkvResult.exitCode != 0) {
        _log('mkvextract (step 2) failed (exit ${mkvResult.exitCode}):', isError: true);
        if ((mkvResult.stdout as String).isNotEmpty) {
          _log(mkvResult.stdout as String, isError: true);
        }
        return false;
      }
      if (!await idxFile.exists()) {
        _log('mkvextract (step 2): .idx file not created at ${idxFile.path}', isError: true);
        return false;
      }

      // Step 3: subtile-ocr → SRT
      final ocrResult = await Process.run(subtileOcr, [
        '-l', lang,
        '-o', srtOut.path,
        idxFile.path,
      ]).timeout(const Duration(minutes: 10));
      if (ocrResult.exitCode != 0) {
        _log('subtile-ocr (step 3) failed (exit ${ocrResult.exitCode}):', isError: true);
        if ((ocrResult.stdout as String).isNotEmpty) _log(ocrResult.stdout as String, isError: true);
        if ((ocrResult.stderr as String).isNotEmpty) _log(ocrResult.stderr as String, isError: true);
        return false;
      }
      return true;
    } on TimeoutException {
      _log('timed out.', isError: true);
      return false;
    } catch (_) {
      return false;
    } finally {
      await tmpDir.delete(recursive: true).catchError((_) => Directory(''));
    }
  }

  /// Extracts the first subtitle stream to a temp directory in `/tmp`, reads
  /// up to [maxChars] characters of the SRT text, deletes the temp files, and
  /// returns `(text, language)` — or null if extraction fails or no subtitles
  /// exist.  [language] is the ISO 639-1 two-letter code (e.g. `"nl"`, `"en"`).
  Future<({String text, String language})?> extractFirstSubtitleText(
    File mkvFile, {
    int maxChars = 4000,
  }) async {
    final streams = await _probeSubtitles(mkvFile);
    if (streams.isEmpty) return null;

    // Prefer an English subtitle track for identification; fall back to first.
    final enIdx = streams.indexWhere(
      (s) => _toLangCode(s['language']!) == 'en',
    );
    final subIdx  = enIdx >= 0 ? enIdx : 0;
    final stream  = streams[subIdx];
    final codec   = stream['codec_name']!.toLowerCase();
    final rawLang = stream['language']!;
    final lang    = _toLangCode(rawLang);

    final tmpDir = await Directory('/tmp').createTemp('naming_');
    try {
      final tmpSrt = File('${tmpDir.path}/sub.srt');
      bool ok;
      if (_textCodecs.contains(codec)) {
        ok = await _extractText(mkvFile, subIdx, tmpSrt);
      } else if (_imageCodecs.contains(codec)) {
        ok = await _extractImage(mkvFile, subIdx, rawLang, tmpSrt);
      } else {
        return null;
      }
      if (!ok || !await tmpSrt.exists()) return null;
      final content = await tmpSrt.readAsString();
      final text = content.length > maxChars
          ? content.substring(0, maxChars)
          : content;
      return (text: text, language: lang);
    } finally {
      await tmpDir.delete(recursive: true).catchError((_) => Directory(''));
    }
  }

  /// Returns any `.srt` files already extracted alongside [mkvFile].
  /// E.g. for `foo.mkv` this returns all `foo.*.srt` files in the same dir.
  List<File> findExistingSrts(File mkvFile) {
    final stem = p.basenameWithoutExtension(mkvFile.path);
    return mkvFile.parent
        .listSync()
        .whereType<File>()
        .where((f) =>
            p.basename(f.path).startsWith('$stem.') &&
            f.path.endsWith('.srt'))
        .toList();
  }

  String _toLangCode(String iso639) => _langMap[iso639] ?? iso639;

  /// Converts a raw stream language code to the Tesseract traineddata name.
  /// ISO 639-2/B alternatives (e.g. dut, fre, ger) are remapped to their
  /// ISO 639-3 equivalents that Tesseract ships with.
  String _toOcrLang(String raw) => _ocrLangMap[raw] ?? raw;
}
