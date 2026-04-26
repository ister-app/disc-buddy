import '../utils/duration_ext.dart';
import 'video_title.dart';

class AudioTrack {
  final int index;       // IFO index (0-based)
  final int streamId;    // MPEG sub-stream ID (0x80–0x87)
  final String language;
  final String codec;
  final int channels;

  const AudioTrack({
    required this.index,
    required this.streamId,
    required this.language,
    required this.codec,
    required this.channels,
  });

  /// Human-readable label, e.g. "NL AC3 5.1"
  String get label {
    final lang  = language.isNotEmpty ? language.toUpperCase() : '??';
    final codec = this.codec.isNotEmpty ? this.codec.toUpperCase() : '';
    final ch    = switch (channels) {
      1 => '1.0',
      2 => '2.0',
      6 => '5.1',
      8 => '7.1',
      _ => channels > 0 ? '$channels ch' : '',
    };
    return [lang, codec, ch].where((s) => s.isNotEmpty).join(' ');
  }
}

class SubtitleTrack {
  final int index;       // IFO index (0-based)
  final int streamId;    // MPEG sub-stream ID (0x20–0x3F)
  final String language;

  const SubtitleTrack({
    required this.index,
    required this.streamId,
    required this.language,
  });

  String get label => language.isNotEmpty ? language.toUpperCase() : '??';
}

class DvdTitle implements VideoTitle {
  final int vtsNumber;    // VTS file number (1-based, for VOB files)
  final int pgcIndex;     // 0-based PGC index within the VTS (= angle - 1)
  final int totalAngles;  // number of PGCs in this VTS (1 = no angles)
  @override final Duration duration;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;
  /// Cells for this PGC (first/last sector), empty = read linearly.
  final List<({int first, int last})> cells;
  /// Chapter start timestamps (relative to title start), one per program.
  @override final List<Duration> chapters;
  /// PGC Color Lookup Table: 16 RGB values (0xRRGGBB). Empty if unavailable.
  final List<int> clut;
  /// Video frame height in lines (480 = NTSC, 576 = PAL). Used in IDX header.
  final int videoHeight;

  const DvdTitle({
    required this.vtsNumber,
    required this.pgcIndex,
    required this.totalAngles,
    required this.duration,
    required this.audioTracks,
    required this.subtitleTracks,
    this.cells       = const [],
    this.chapters    = const [],
    this.clut        = const [],
    this.videoHeight = 576,
  });

  /// Display key: "7" or "7.1" for multiple angles.
  @override
  String get displayKey =>
      totalAngles > 1 ? '$vtsNumber.${pgcIndex + 1}' : '$vtsNumber';

  /// "HH:MM:SS"
  @override
  String get durationLabel => duration.hmsLabel;

  /// "title_07.mkv" or "title_07_angle2.mkv"
  @override
  String get filename {
    final n = vtsNumber.toString().padLeft(2, '0');
    if (totalAngles > 1) return 'title_${n}_angle${pgcIndex + 1}.mkv';
    return 'title_$n.mkv';
  }

  /// Total sectors across all cells.  Used as a proxy for bitrate when
  /// comparing duplicate-duration PGCs: copy-protection decoys have the same
  /// IFO-declared duration as the real content but far fewer sectors.
  int get totalSectors =>
      cells.fold(0, (sum, c) => sum + (c.last - c.first + 1));

  @override int     get audioStreamCount    => audioTracks.length;
  @override int     get subtitleStreamCount => subtitleTracks.length;
  @override bool    get hasSubtitles        => subtitleTracks.isNotEmpty;
  @override List<String> get audioTrackLabels    => audioTracks.map((t) => t.label).toList();
  @override List<String> get subtitleTrackLabels => subtitleTracks.map((t) => t.label).toList();
  @override List<String> get audioLangCodes      => audioTracks.map((t) => t.language.toLowerCase()).toList();
  @override List<String> get subtitleLangCodes   => subtitleTracks.map((t) => t.language.toLowerCase()).toList();

  /// True for NTSC titles (videoHeight == 480) with no IFO-declared subtitle
  /// tracks.  EIA-608 closed captions may be embedded in the video stream and
  /// will be extracted as a sidecar SRT after ripping.
  bool get mayHaveCc => videoHeight == 480 && subtitleTracks.isEmpty;
  @override bool    get isPrimary           => pgcIndex == 0;
  @override String? get extraInfo =>
      totalAngles > 1 ? '  (angle ${pgcIndex + 1}/$totalAngles)' : null;

  /// Returns true if [key] matches this title's VTS number and this is the
  /// primary angle — allows users to type "3" to select VTS 3, angle 1.
  @override
  bool matchesKey(String key) =>
      vtsNumber.toString() == key && pgcIndex == 0;
}
