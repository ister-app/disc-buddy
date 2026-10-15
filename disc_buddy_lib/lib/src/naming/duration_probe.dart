import 'dart:io';

/// Container duration lookup via ffprobe, cached per file path.
class DurationProbe {
  DurationProbe({required this.ffprobe});

  final String ffprobe;
  final Map<String, double?> _cache = {};

  /// Container duration in seconds, or null when unavailable.
  Future<double?> secondsOf(File mediaFile) async {
    final key = mediaFile.path;
    if (_cache.containsKey(key)) return _cache[key];
    double? secs;
    try {
      final result = await Process.run(ffprobe, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'csv=p=0',
        mediaFile.path,
      ]);
      if (result.exitCode == 0) {
        secs = double.tryParse((result.stdout as String).trim());
      }
    } catch (_) {}
    _cache[key] = secs;
    return secs;
  }
}
