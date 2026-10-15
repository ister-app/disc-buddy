import '../device/resilient_read.dart' show ReadStats;
import '../utils/duration_ext.dart';

/// Outcome details of one ripped title, beyond "a file was produced".
///
/// Rippers append one per title to their `reports` list so a front end can
/// summarise read errors and suspicious durations after the run.
class TitleRipReport {
  TitleRipReport({
    required this.titleKey,
    required this.outputPath,
    required this.read,
    required this.expected,
    required this.actual,
  });

  /// Display key of the title (e.g. `3` or `6.2`).
  final String titleKey;
  final String outputPath;
  /// Sector-level read tally; `null` when the source was not read block-wise
  /// (VOB concat, Blu-ray).
  final ReadStats? read;
  /// Duration the disc metadata promised.
  final Duration expected;
  /// Container duration ffprobe reported for the output; `null` when the
  /// probe failed (treated as "unknown", not as a problem).
  final Duration? actual;

  bool get hasReadErrors => read?.hasErrors ?? false;

  /// False when the output is clearly shorter than the title.
  bool get durationOk => actual == null ||
      durationWithinTolerance(expected: expected, actual: actual!);

  bool get hasWarnings => hasReadErrors || !durationOk;

  /// One line per report, for a post-rip summary.
  String describe() {
    final parts = <String>[];
    if (read != null && read!.hasErrors) parts.add(read!.summary());
    if (!durationOk) {
      parts.add('duration ${actual!.hmsLabel} of ${expected.hmsLabel} — '
          'probably truncated');
    }
    return '$titleKey: ${parts.isEmpty ? 'ok' : parts.join('; ')}';
  }
}
