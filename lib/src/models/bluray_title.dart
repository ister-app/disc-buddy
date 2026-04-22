import '../utils/duration_ext.dart';
import 'video_title.dart';

class BlurayTitle implements VideoTitle {
  final int index;              // 1-based display index
  final String playlist;        // 5-digit MPLS name, e.g. "00001"
  @override final Duration duration;
  final int audioCount;         // number of audio streams (from CLPI)
  final int subtitleCount;      // number of subtitle streams (from CLPI)
  final List<String> audioLangs;    // ISO-639-2/B codes (from CLPI)
  final List<String> subtitleLangs; // ISO-639-2/B codes (from CLPI)
  /// Chapter start timestamps (relative to playlist start), from PlayListMark.
  @override final List<Duration> chapters;
  // CLPI-derived data cached at scan time so ripping never needs to re-parse.
  final List<String> clipNames;         // MPLS clip names, e.g. ["00001", "00002"]
  final Set<int> lpcmAudioIndices;      // 0-based indices of LPCM audio streams
  final List<String> audioTitles;       // per-stream titles for ffmpeg metadata
  final bool hasHevc;                   // true → 4K UHD disc (AACS 2.0)

  const BlurayTitle({
    required this.index,
    required this.playlist,
    required this.duration,
    required this.audioCount,
    required this.subtitleCount,
    required this.audioLangs,
    required this.subtitleLangs,
    this.chapters          = const [],
    this.clipNames         = const [],
    this.lpcmAudioIndices  = const {},
    this.audioTitles       = const [],
    this.hasHevc           = false,
  });

  /// Playlist number as string, e.g. "1", "42".
  @override String get displayKey => index.toString();

  /// "HH:MM:SS"
  @override String get durationLabel => duration.hmsLabel;

  /// "title_00001.mkv"
  @override String get filename => 'title_$playlist.mkv';

  @override int     get audioStreamCount    => audioCount;
  @override int     get subtitleStreamCount => subtitleCount;
  @override bool    get hasSubtitles        => subtitleCount > 0;
  @override bool    get isPrimary           => true;
  @override String? get extraInfo           => '  [$playlist]';
  @override bool    matchesKey(String key)  => false;
}
