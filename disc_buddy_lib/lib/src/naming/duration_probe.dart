import 'dart:convert';
import 'dart:io';

/// What one ffprobe call tells us about a media file.
typedef MediaInfo = ({double? seconds, List<String> audioLanguages});

/// Media duration and audio-layout lookup via ffprobe, cached per file path.
///
/// Prefers the video stream's duration over the container duration: a
/// subtitle track with a stray long-lived packet (common in mkvmerge'd DVD
/// rips) can double the container duration while video and audio are fine,
/// which would make a normal episode look like a two-parter.
class DurationProbe {
  DurationProbe({required this.ffprobe});

  final String ffprobe;
  final Map<String, MediaInfo> _cache = {};

  static const MediaInfo _unknown = (seconds: null, audioLanguages: []);

  /// Duration and audio language tags, from one cached ffprobe run.
  Future<MediaInfo> infoOf(File mediaFile) async {
    final key = mediaFile.path;
    final cached = _cache[key];
    if (cached != null) return cached;
    var info = _unknown;
    try {
      final result = await Process.run(ffprobe, [
        '-v', 'error',
        '-show_entries',
        'format=duration:stream=codec_type,duration'
            ':stream_tags=DURATION,language',
        '-of', 'json',
        mediaFile.path,
      ]);
      if (result.exitCode == 0) {
        info = parseProbeInfo(result.stdout as String);
      }
    } catch (_) {}
    _cache[key] = info;
    return info;
  }

  /// Duration in seconds (video stream, else audio, else container), or
  /// null when unavailable.
  Future<double?> secondsOf(File mediaFile) async =>
      (await infoOf(mediaFile)).seconds;

  /// Language tag of every audio stream in file order ('' when untagged).
  Future<List<String>> audioLanguagesOf(File mediaFile) async =>
      (await infoOf(mediaFile)).audioLanguages;

  /// Picks the best duration from ffprobe JSON output (see [parseProbeInfo]).
  static double? parseProbeJson(String json) => parseProbeInfo(json).seconds;

  /// Parses ffprobe JSON into duration plus the audio streams' language tags.
  static MediaInfo parseProbeInfo(String json) {
    final Map<String, dynamic> root;
    try {
      root = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return _unknown;
    }
    final streams = (root['streams'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final audioLanguages = <String>[
      for (final s in streams)
        if (s['codec_type'] == 'audio') _language(s),
    ];
    return (seconds: _bestSeconds(root, streams), audioLanguages: audioLanguages);
  }

  static String _language(Map<String, dynamic> s) {
    final tags = s['tags'];
    if (tags is Map<String, dynamic>) {
      final lang = tags['language'] ?? tags['LANGUAGE'];
      if (lang is String) return lang.trim().toLowerCase();
    }
    return '';
  }

  /// The first video stream's duration, else the first audio stream's,
  /// else the container's.
  static double? _bestSeconds(
    Map<String, dynamic> root,
    List<Map<String, dynamic>> streams,
  ) {
    for (final type in const ['video', 'audio']) {
      for (final s in streams) {
        if (s['codec_type'] != type) continue;
        final d = _streamSeconds(s);
        if (d != null && d > 0) return d;
      }
    }
    final format = root['format'];
    if (format is Map<String, dynamic>) {
      return double.tryParse('${format['duration']}');
    }
    return null;
  }

  static double? _streamSeconds(Map<String, dynamic> s) {
    final direct = double.tryParse('${s['duration']}');
    if (direct != null) return direct;
    // Matroska reports per-stream duration only as a tag: HH:MM:SS.nnn
    final tags = s['tags'];
    if (tags is Map<String, dynamic>) {
      final tag = tags['DURATION'] ?? tags['duration'];
      if (tag is String) return parseHms(tag);
    }
    return null;
  }

  /// Parses `HH:MM:SS(.fraction)` into seconds.
  static double? parseHms(String text) {
    final parts = text.trim().split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = double.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return h * 3600 + m * 60 + s;
  }
}
