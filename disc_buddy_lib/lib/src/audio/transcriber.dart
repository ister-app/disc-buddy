import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../rippers/video_disc_ripper.dart' show LogCallback;

/// Audio-transcription fallback for auto-naming titles without subtitles.
///
/// Extracts a few sampled audio windows (begin/middle/end) as mono 16 kHz
/// WAV via ffmpeg and transcribes them with whisper.cpp's `whisper-cli`.
/// The joined transcript substitutes 1:1 for subtitle text in [AutoNamer].
///
/// Successful transcripts are cached as a `<stem>.whisper.json` sidecar next
/// to the video file, so re-runs (and post-rename retries) skip the work.
class Transcriber {
  static const _windowLen = 180.0; // seconds per sampled window
  static const _introSkip = 90.0;  // skip cold-open/theme at the start
  static const _minTranscriptChars = 200;

  // Whisper non-speech markers to strip from transcripts.
  static final _nonSpeech = RegExp(
    r'\[[^\]\n]{0,40}\]|\([^)\n]{0,40}\)|♪+',
  );

  final String ffmpeg;
  final String ffprobe;
  final String whisperCli;
  final String whisperModel;
  final LogCallback? onLog;

  Transcriber({
    required this.ffmpeg,
    required this.ffprobe,
    required this.whisperCli,
    required this.whisperModel,
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

  /// Returns the sidecar cache file for [videoFile]: `<stem>.whisper.json`.
  static File sidecarFor(File videoFile) {
    final stem = p.withoutExtension(videoFile.path);
    return File('$stem.whisper.json');
  }

  /// Transcribes sampled audio windows of [videoFile].
  ///
  /// Returns `(text, language)` — the same shape `AutoNamer._loadSubtitle`
  /// expects — or null when the file has no audio track or transcription
  /// produced (almost) nothing.
  Future<({String text, String language})?> transcribe(File videoFile) async {
    // 0. Sidecar cache.
    final cached = await _readSidecar(videoFile);
    if (cached != null) {
      _log('   Transcriber: using cached transcript '
          '(${p.basename(sidecarFor(videoFile).path)}).');
      return cached;
    }

    // 1. Probe audio streams + duration.
    final probe = await _probeAudio(videoFile);
    if (probe == null || probe.streams.isEmpty) {
      _log('   Transcriber: no audio track — skipping.', isError: true);
      return null;
    }

    // Prefer an English-tagged track for identification; fall back to first.
    final enIdx = probe.streams.indexWhere((s) => s.language.startsWith('en'));
    final audioIdx = enIdx >= 0 ? enIdx : 0;

    final windows = windowOffsets(probe.duration);
    final tmpDir = await Directory('/tmp').createTemp('whisper_');
    try {
      final texts = <String>[];
      String? language;
      for (var i = 0; i < windows.length; i++) {
        final w = windows[i];
        _log('   Transcribing window ${i + 1}/${windows.length} '
            '(${w.start.round()}s +${w.len.round()}s)...');
        final wav = File('${tmpDir.path}/win$i.wav');
        if (!await _extractWindow(videoFile, audioIdx, w.start, w.len, wav)) {
          continue;
        }
        final result = await _runWhisper(wav, '${tmpDir.path}/win$i');
        if (result == null) continue;
        final cleaned = cleanTranscript(result.text);
        if (cleaned.isNotEmpty) {
          texts.add(cleaned);
          language ??= result.language;
        }
      }

      final joined = texts.join('\n...\n');
      if (joined.trim().length < _minTranscriptChars) {
        _log('   Transcriber: transcript too short '
            '(${joined.trim().length} chars) — skipping.', isError: true);
        return null;
      }

      final out = (text: joined, language: language ?? 'en');
      await _writeSidecar(videoFile, out);
      return out;
    } finally {
      await tmpDir.delete(recursive: true).catchError((_) => Directory(''));
    }
  }

  // ---------------------------------------------------------------------------
  // Sidecar cache
  // ---------------------------------------------------------------------------

  Future<({String text, String language})?> _readSidecar(File videoFile) async {
    final sidecar = sidecarFor(videoFile);
    try {
      if (!await sidecar.exists()) return null;
      final json = jsonDecode(await sidecar.readAsString());
      if (json is! Map) return null;
      final text = json['text'];
      if (text is! String || text.trim().isEmpty) return null;
      return (text: text, language: (json['language'] as String?) ?? 'en');
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSidecar(
    File videoFile,
    ({String text, String language}) result,
  ) async {
    try {
      await sidecarFor(videoFile).writeAsString(jsonEncode({
        'language': result.language,
        'text': result.text,
      }));
    } catch (e) {
      _log('   Transcriber: could not write sidecar cache: $e', isError: true);
    }
  }

  // ---------------------------------------------------------------------------
  // ffprobe / ffmpeg
  // ---------------------------------------------------------------------------

  Future<({List<({String language})> streams, double? duration})?> _probeAudio(
    File videoFile,
  ) async {
    final ProcessResult result;
    try {
      result = await Process.run(ffprobe, [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_streams',
        '-show_format',
        videoFile.path,
      ]);
    } catch (e) {
      _log('   ffprobe failed: $e', isError: true);
      return null;
    }
    if (result.exitCode != 0) {
      _log('   ffprobe failed: ${result.stderr}', isError: true);
      return null;
    }
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final all =
        (json['streams'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final streams = all
        .where((s) => s['codec_type'] == 'audio')
        .map((s) => (
              language:
                  ((s['tags'] as Map?)?['language'])?.toString() ?? 'und',
            ))
        .toList();
    final duration = double.tryParse(
        ((json['format'] as Map?)?['duration'])?.toString() ?? '');
    return (streams: streams, duration: duration);
  }

  Future<bool> _extractWindow(
    File src,
    int audioIdx,
    double start,
    double len,
    File wavOut,
  ) async {
    try {
      final result = await Process.run(ffmpeg, [
        '-loglevel', 'error',
        '-ss', start.toStringAsFixed(2),
        '-t', len.toStringAsFixed(2),
        '-i', src.path,
        '-map', '0:a:$audioIdx',
        '-ac', '1',
        '-ar', '16000',
        '-c:a', 'pcm_s16le',
        '-y',
        wavOut.path,
      ]).timeout(const Duration(minutes: 10));
      if (result.exitCode != 0) {
        _log('   ffmpeg audio extract failed (exit ${result.exitCode}): '
            '${result.stderr}', isError: true);
        return false;
      }
      return await wavOut.exists();
    } on TimeoutException {
      _log('   ffmpeg audio extract timed out.', isError: true);
      return false;
    } catch (e) {
      _log('   ffmpeg audio extract failed: $e', isError: true);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // whisper-cli
  // ---------------------------------------------------------------------------

  Future<({String text, String language})?> _runWhisper(
    File wav,
    String outPrefix,
  ) async {
    try {
      final result = await Process.run(whisperCli, [
        '-m', whisperModel,
        '-f', wav.path,
        '-l', 'auto',
        '-oj',
        '-of', outPrefix,
        '-np',
      ]).timeout(const Duration(minutes: 10));
      if (result.exitCode != 0) {
        _log('   whisper-cli failed (exit ${result.exitCode}): '
            '${result.stderr}', isError: true);
        return null;
      }
      final jsonFile = File('$outPrefix.json');
      if (!await jsonFile.exists()) {
        _log('   whisper-cli: no JSON output at ${jsonFile.path}',
            isError: true);
        return null;
      }
      return parseWhisperJson(await jsonFile.readAsString());
    } on TimeoutException {
      _log('   whisper-cli timed out.', isError: true);
      return null;
    } catch (e) {
      _log('   whisper-cli failed: $e', isError: true);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Pure helpers (unit-testable)
  // ---------------------------------------------------------------------------

  /// Computes the audio windows to transcribe for a title of [durationSecs].
  ///
  /// - Unknown duration → one safe window of 5 minutes from the start.
  /// - Short title → one window covering most of it (skipping the intro).
  /// - Otherwise three windows at ~10% / 50% / 85%, [_windowLen] each, the
  ///   first at least [_introSkip] in, the last clamped to the end.
  static List<({double start, double len})> windowOffsets(
      double? durationSecs) {
    if (durationSecs == null || durationSecs <= 0) {
      return [(start: 0.0, len: 300.0)];
    }
    final dur = durationSecs;
    if (dur <= 3 * _windowLen + _introSkip) {
      final start = _introSkip < dur / 4 ? _introSkip : 0.0;
      return [(start: start, len: dur - start)];
    }
    final offsets = [
      _introSkip > dur * 0.10 ? _introSkip : dur * 0.10,
      dur * 0.50,
      dur * 0.85,
    ];
    final windows = <({double start, double len})>[];
    for (final rawStart in offsets) {
      var start = rawStart;
      if (start + _windowLen > dur) start = dur - _windowLen;
      if (start < 0) start = 0;
      // Skip windows that overlap the previous one.
      if (windows.isNotEmpty &&
          start < windows.last.start + windows.last.len) {
        continue;
      }
      windows.add((start: start, len: _windowLen));
    }
    return windows;
  }

  /// Parses whisper.cpp `-oj` JSON output into `(text, language)`.
  static ({String text, String language})? parseWhisperJson(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final segments = (json['transcription'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final text =
          segments.map((s) => (s['text'] ?? '').toString()).join(' ');
      final language =
          ((json['result'] as Map?)?['language'])?.toString() ?? 'en';
      return (text: text, language: language);
    } catch (_) {
      return null;
    }
  }

  /// Strips whisper non-speech markers (`[BLANK_AUDIO]`, `(music)`, `♪`)
  /// and collapses whitespace.
  static String cleanTranscript(String text) => text
      .replaceAll(_nonSpeech, ' ')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' ?\n ?'), '\n')
      .trim();
}
