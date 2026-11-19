import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/log.dart';
import 'duration_probe.dart';
import '../utils/process_utils.dart';

/// A black stretch reported by ffmpeg's `blackdetect`, in file seconds.
typedef BlackInterval = ({double start, double end});

/// The two halves [StorySplitter.split] wrote next to the source file.
typedef StorySplit = ({File source, File first, File second, double cut});

/// Splits a file that holds two stories — a cartoon's two 11-minute
/// segments ripped as one 23-minute episode — at the black frame nearest
/// its middle, so each story can be matched (and named) on its own.
///
/// The cut is a stream copy (no re-encode): each half starts on the
/// keyframe at or before the cut, which sits inside the black stretch, so
/// a few black frames at most are duplicated. Chapters are dropped, their
/// times would be wrong for the second half.
class StorySplitter {
  StorySplitter({
    required this.ffmpeg,
    required this.ffprobe,
    this.onLog,
    DurationProbe? probe,
  }) : _probe = probe ?? DurationProbe(ffprobe: ffprobe);

  /// How far from the middle the story break may lie, in seconds.
  static const searchRadius = 90.0;

  /// Shortest black stretch that counts as a break, in seconds.
  static const minBlackSecs = 0.3;

  /// Allowed gap between the halves' summed duration and the source's.
  static const durationTolerance = 5.0;

  final String ffmpeg;
  final String ffprobe;
  final LogCallback? onLog;
  final DurationProbe _probe;

  void _log(String msg, {bool isError = false}) =>
      emitLog(onLog, msg, isError: isError);

  /// `<stem>.story1<ext>` / `<stem>.story2<ext>` next to [source].
  static ({File first, File second}) halvesFor(File source) {
    final stem = p.withoutExtension(source.path);
    final ext = p.extension(source.path);
    return (first: File('$stem.story1$ext'), second: File('$stem.story2$ext'));
  }

  /// Writes both halves of [source] and returns them, or null (after
  /// logging) when no break is found near the middle or ffmpeg fails.
  /// Never touches [source].
  Future<StorySplit?> split(File source) async {
    final duration = await _probe.secondsOf(source);
    if (duration == null || duration < 4 * searchRadius) {
      _log('   ${source.path}: too short or unknown duration — not split.',
          isError: true);
      return null;
    }
    final windowStart = duration / 2 - searchRadius;
    final blacks = await _detectBlack(source, windowStart, 2 * searchRadius);
    if (blacks == null) return null;
    final cut = pickCut(blacks, duration);
    if (cut == null) {
      _log('   ${source.path}: no black frame within ${searchRadius.round()} s '
          'of the middle — not split.', isError: true);
      return null;
    }

    final halves = halvesFor(source);
    final ok = await _copy(source, halves.first, end: cut) &&
        await _copy(source, halves.second, start: cut);
    if (ok) {
      final d1 = await _probe.secondsOf(halves.first);
      final d2 = await _probe.secondsOf(halves.second);
      if (d1 != null &&
          d2 != null &&
          (d1 + d2 - duration).abs() <= durationTolerance) {
        _log('   Split ${p.basename(source.path)} at ${_clock(cut)} '
            '(${_clock(d1)} + ${_clock(d2)}).');
        return (
          source: source,
          first: halves.first,
          second: halves.second,
          cut: cut,
        );
      }
      _log('   ${source.path}: halves ($d1 s + $d2 s) do not add up to '
          '$duration s — not split.', isError: true);
    }
    for (final f in [halves.first, halves.second]) {
      if (await f.exists()) await f.delete();
    }
    return null;
  }

  /// Parses `blackdetect` lines from ffmpeg's stderr; times are shifted by
  /// [offset] because the detection runs on a window starting there.
  static List<BlackInterval> parseBlackdetect(String stderr,
      {double offset = 0}) {
    final re = RegExp(r'black_start:\s*([\d.]+)\s+black_end:\s*([\d.]+)');
    return [
      for (final m in re.allMatches(stderr))
        (
          start: double.parse(m.group(1)!) + offset,
          end: double.parse(m.group(2)!) + offset,
        ),
    ];
  }

  /// The middle of the black stretch closest to the file's middle, or null
  /// when none lies within [radius] seconds of it.
  static double? pickCut(
    List<BlackInterval> blacks,
    double duration, {
    double radius = searchRadius,
  }) {
    final middle = duration / 2;
    double? best;
    for (final b in blacks) {
      final at = (b.start + b.end) / 2;
      if ((at - middle).abs() > radius) continue;
      if (best == null || (at - middle).abs() < (best - middle).abs()) {
        best = at;
      }
    }
    return best;
  }

  Future<List<BlackInterval>?> _detectBlack(
    File source,
    double start,
    double length,
  ) async {
    try {
      final result = await runWithTimeout(ffmpeg, [
        '-hide_banner', '-nostats',
        '-ss', start.toStringAsFixed(2),
        '-t', length.toStringAsFixed(2),
        '-i', source.path,
        '-map', '0:v:0',
        '-vf', 'blackdetect=d=$minBlackSecs:pix_th=0.10',
        '-an', '-sn',
        '-f', 'null', '-',
      ], timeout: const Duration(minutes: 10));
      if (result.exitCode != 0) {
        _log('   blackdetect failed for ${source.path} '
            '(exit ${result.exitCode}).', isError: true);
        return null;
      }
      return parseBlackdetect(result.stderr as String, offset: start);
    } on TimeoutException {
      _log('   blackdetect timed out for ${source.path}.', isError: true);
      return null;
    } on ProcessException catch (e) {
      _log('   blackdetect failed for ${source.path}: $e', isError: true);
      return null;
    }
  }

  Future<bool> _copy(File source, File out, {double? start, double? end}) async {
    try {
      final result = await runWithTimeout(ffmpeg, [
        '-loglevel', 'error',
        if (start != null) ...['-ss', start.toStringAsFixed(3)],
        '-i', source.path,
        if (end != null) ...['-t', end.toStringAsFixed(3)],
        '-map', '0',
        '-map_chapters', '-1',
        '-c', 'copy',
        '-y', out.path,
      ], timeout: const Duration(minutes: 30));
      if (result.exitCode != 0) {
        _log('   ffmpeg split failed for ${source.path} '
            '(exit ${result.exitCode}): ${result.stderr}', isError: true);
        return false;
      }
      return true;
    } on TimeoutException {
      _log('   ffmpeg split timed out for ${source.path}.', isError: true);
      return false;
    } on ProcessException catch (e) {
      _log('   ffmpeg split failed for ${source.path}: $e', isError: true);
      return false;
    }
  }

  static String _clock(double secs) {
    final s = secs.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
