import '../utils/duration_ext.dart';

class BlurayTitle {
  final int index;              // 1-based display index
  final String playlist;        // 5-digit MPLS name, e.g. "00001"
  final Duration duration;
  final int audioCount;         // number of audio streams (from CLPI)
  final int subtitleCount;      // number of subtitle streams (from CLPI)
  final List<String> audioLangs;    // ISO-639-2/B codes (from CLPI)
  final List<String> subtitleLangs; // ISO-639-2/B codes (from CLPI)
  /// Chapter start timestamps (relative to playlist start), from PlayListMark.
  final List<Duration> chapters;

  const BlurayTitle({
    required this.index,
    required this.playlist,
    required this.duration,
    required this.audioCount,
    required this.subtitleCount,
    required this.audioLangs,
    required this.subtitleLangs,
    this.chapters = const [],
  });

  /// "HH:MM:SS"
  String get durationLabel => duration.hmsLabel;

  /// "title_00001.mkv"
  String get filename => 'title_$playlist.mkv';
}
