import 'package:disc_buddy/disc_buddy.dart';

class Settings {
  final bool isLoaded;
  final String? videoDir;
  final String? musicDir;
  final String? ffmpeg;
  final String? ffprobe;
  final String? mkvextract;
  final String? subtileOcr;
  final String? tmdbToken;
  final String? llmUrl;
  final String? llmKey;
  final String? llmModel;
  final bool autoName;
  final bool batchAssign;
  /// Comma-separated ISO 639 language codes for audio tracks to keep in the MKV.
  /// Null / empty = keep all.
  final String? audioLangs;
  /// Comma-separated ISO 639 language codes for subtitle tracks to keep in the MKV.
  /// Null / empty = keep all.
  final String? subtitleTrackLangs;

  const Settings({
    this.isLoaded = true,
    this.videoDir,
    this.musicDir,
    this.ffmpeg,
    this.ffprobe,
    this.mkvextract,
    this.subtileOcr,
    this.tmdbToken,
    this.llmUrl,
    this.llmKey,
    this.llmModel,
    this.autoName = false,
    this.batchAssign = false,
    this.audioLangs,
    this.subtitleTrackLangs,
  });

  /// The output directory to actually use for video: explicit setting or XDG_VIDEOS_DIR.
  String get effectiveOutputDir =>
      videoDir ?? xdgUserDir('VIDEOS', fallback: r'$HOME/Videos');

  /// The output directory to use for audio CDs: explicit setting or XDG_MUSIC_DIR.
  String get effectiveMusicDir =>
      musicDir ?? xdgUserDir('MUSIC', fallback: r'$HOME/Music');

  factory Settings.defaults() => const Settings(isLoaded: false);

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    videoDir:  json['output'] as String?,
    musicDir:  json['music-output'] as String?,
    ffmpeg: json['ffmpeg'] as String?,
    ffprobe: json['ffprobe'] as String?,
    mkvextract: json['mkvextract'] as String?,
    subtileOcr: json['subtile-ocr'] as String?,
    tmdbToken: json['tmdb-token'] as String?,
    llmUrl: json['llm-url'] as String?,
    llmKey: json['llm-key'] as String?,
    llmModel: json['llm-model'] as String?,
    autoName: json['auto-name'] as bool? ?? false,
    batchAssign: json['batch-assign'] as bool? ?? false,
    audioLangs: json['audio-langs'] as String?,
    subtitleTrackLangs: json['subtitle-track-langs'] as String?,
  );

  Map<String, dynamic> toJson() => {
    if (videoDir  != null) 'output': videoDir,
    if (musicDir  != null) 'music-output': musicDir,
    if (ffmpeg != null) 'ffmpeg': ffmpeg,
    if (ffprobe != null) 'ffprobe': ffprobe,
    if (mkvextract != null) 'mkvextract': mkvextract,
    if (subtileOcr != null) 'subtile-ocr': subtileOcr,
    if (tmdbToken != null) 'tmdb-token': tmdbToken,
    if (llmUrl != null) 'llm-url': llmUrl,
    if (llmKey != null) 'llm-key': llmKey,
    if (llmModel != null) 'llm-model': llmModel,
    'auto-name': autoName,
    'batch-assign': batchAssign,
    if (audioLangs != null) 'audio-langs': audioLangs,
    if (subtitleTrackLangs != null) 'subtitle-track-langs': subtitleTrackLangs,
  };

  static Set<String>? _parseLangs(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    final set = s.split(RegExp(r'[,\s]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
    return set.isEmpty ? null : set;
  }

  RipOptions toRipOptions({String? device, String? outputDir}) => RipOptions(
    device: device,
    outputDir: outputDir ?? effectiveOutputDir,
    ffmpeg: ffmpeg ?? 'ffmpeg',
    ffprobe: ffprobe ?? 'ffprobe',
    mkvextract: mkvextract,
    subtileOcr: subtileOcr,
    tmdbToken: tmdbToken,
    llmUrl: llmUrl,
    llmKey: llmKey,
    llmModel: llmModel,
    force: true,
    autoName: autoName,
    batchAssign: batchAssign,
    audioMkvLangs: _parseLangs(audioLangs),
    subtitleMkvLangs: _parseLangs(subtitleTrackLangs),
  );

  Settings copyWith({
    bool? isLoaded,
    Object? videoDir = _sentinel,
    Object? musicDir = _sentinel,
    Object? ffmpeg = _sentinel,
    Object? ffprobe = _sentinel,
    Object? mkvextract = _sentinel,
    Object? subtileOcr = _sentinel,
    Object? tmdbToken = _sentinel,
    Object? llmUrl = _sentinel,
    Object? llmKey = _sentinel,
    Object? llmModel = _sentinel,
    bool? autoName,
    bool? batchAssign,
    Object? audioLangs = _sentinel,
    Object? subtitleTrackLangs = _sentinel,
  }) => Settings(
    isLoaded: isLoaded ?? this.isLoaded,
    videoDir:  videoDir == _sentinel ? this.videoDir  : videoDir  as String?,
    musicDir:  musicDir == _sentinel ? this.musicDir  : musicDir  as String?,
    ffmpeg: ffmpeg == _sentinel ? this.ffmpeg : ffmpeg as String?,
    ffprobe: ffprobe == _sentinel ? this.ffprobe : ffprobe as String?,
    mkvextract: mkvextract == _sentinel ? this.mkvextract : mkvextract as String?,
    subtileOcr: subtileOcr == _sentinel ? this.subtileOcr : subtileOcr as String?,
    tmdbToken: tmdbToken == _sentinel ? this.tmdbToken : tmdbToken as String?,
    llmUrl: llmUrl == _sentinel ? this.llmUrl : llmUrl as String?,
    llmKey: llmKey == _sentinel ? this.llmKey : llmKey as String?,
    llmModel: llmModel == _sentinel ? this.llmModel : llmModel as String?,
    autoName: autoName ?? this.autoName,
    batchAssign: batchAssign ?? this.batchAssign,
    audioLangs: audioLangs == _sentinel ? this.audioLangs : audioLangs as String?,
    subtitleTrackLangs: subtitleTrackLangs == _sentinel ? this.subtitleTrackLangs : subtitleTrackLangs as String?,
  );
}

const _sentinel = Object();
