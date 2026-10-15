extension DurationLabel on Duration {
  /// Returns the duration as "HH:MM:SS".
  String get hmsLabel {
    final h = inHours.toString().padLeft(2, '0');
    final m = (inMinutes % 60).toString().padLeft(2, '0');
    final s = (inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// Whether a ripped file's [actual] container duration is acceptably close
/// to the title's [expected] duration. Undershoot beyond
/// `max(absTolerance, expected * relTolerance)` fails (truncated rip);
/// overshoot passes (padding or a slightly longer stream is harmless).
bool durationWithinTolerance({
  required Duration expected,
  required Duration actual,
  Duration absTolerance = const Duration(seconds: 5),
  double relTolerance = 0.02,
}) {
  if (actual >= expected) return true;
  final relMs = (expected.inMilliseconds * relTolerance).round();
  final tolMs = relMs > absTolerance.inMilliseconds ? relMs : absTolerance.inMilliseconds;
  return expected.inMilliseconds - actual.inMilliseconds <= tolMs;
}
