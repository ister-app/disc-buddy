class RipOptions {
  final String? device;
  final String outputDir;
  final String ffmpeg;
  final String ffprobe;
  final bool force;
  /// Automatically use LLM auto-naming for all titles (equivalent to answering
  /// `?` at the rename prompt).  Requires [canAutoName] to be true.
  final bool autoName;
  /// After each successful rip, automatically eject and wait for the next disc
  /// instead of asking (equivalent to answering `r` at the eject prompt).
  final bool loop;
  final String? mkvextract;
  final String? subtileOcr;
  final String? tmdbToken;
  final String? llmUrl;
  final String? llmKey;
  final String? llmModel;
  final String? titleHint;
  final List<int>? seasonHint;
  /// null = ask the user interactively; true/false = forced.
  final bool? batchAssign;
  /// null = ask interactively; empty set = all languages; non-empty = filter.
  final Set<String>? subtitleLangs;
  /// null = include all audio tracks; non-null = include only these 0-based indices.
  final Set<int>? audioTrackIndices;
  /// null = include all subtitle tracks; non-null = include only these 0-based indices.
  final Set<int>? subtitleTrackIndices;
  /// null = keep all audio tracks; non-empty = only keep tracks in these languages.
  /// Ignored when audioTrackIndices is set.
  final Set<String>? audioMkvLangs;
  /// null = keep all subtitle tracks; non-empty = only keep tracks in these languages.
  /// Ignored when subtitleTrackIndices is set.
  final Set<String>? subtitleMkvLangs;

  const RipOptions({
    this.device,
    required this.outputDir,
    this.ffmpeg = 'ffmpeg',
    this.ffprobe = 'ffprobe',
    this.force = false,
    this.autoName = false,
    this.loop = false,
    this.mkvextract,
    this.subtileOcr,
    this.tmdbToken,
    this.llmUrl,
    this.llmKey,
    this.llmModel,
    this.titleHint,
    this.seasonHint,
    this.batchAssign,
    this.subtitleLangs,
    this.audioTrackIndices,
    this.subtitleTrackIndices,
    this.audioMkvLangs,
    this.subtitleMkvLangs,
  });

  /// True when all tools and credentials needed for LLM-based auto-naming
  /// are available.
  bool get canAutoName =>
      tmdbToken != null &&
      llmUrl != null &&
      llmModel != null &&
      mkvextract != null &&
      subtileOcr != null;

  RipOptions copyWithTrackFilter({
    Set<int>? audioTrackIndices,
    Set<int>? subtitleTrackIndices,
  }) => RipOptions(
    device: device,
    outputDir: outputDir,
    ffmpeg: ffmpeg,
    ffprobe: ffprobe,
    force: force,
    autoName: autoName,
    loop: loop,
    mkvextract: mkvextract,
    subtileOcr: subtileOcr,
    tmdbToken: tmdbToken,
    llmUrl: llmUrl,
    llmKey: llmKey,
    llmModel: llmModel,
    titleHint: titleHint,
    seasonHint: seasonHint,
    batchAssign: batchAssign,
    subtitleLangs: subtitleLangs,
    audioTrackIndices: audioTrackIndices,
    subtitleTrackIndices: subtitleTrackIndices,
    audioMkvLangs: audioMkvLangs,
    subtitleMkvLangs: subtitleMkvLangs,
  );

  RipOptions copyWithHints({String? titleHint, List<int>? seasonHint, bool? autoName, bool? batchAssign}) => RipOptions(
    device: device,
    outputDir: outputDir,
    ffmpeg: ffmpeg,
    ffprobe: ffprobe,
    force: force,
    autoName: autoName ?? this.autoName,
    loop: loop,
    mkvextract: mkvextract,
    subtileOcr: subtileOcr,
    tmdbToken: tmdbToken,
    llmUrl: llmUrl,
    llmKey: llmKey,
    llmModel: llmModel,
    titleHint: titleHint ?? this.titleHint,
    seasonHint: seasonHint ?? this.seasonHint,
    batchAssign: batchAssign ?? this.batchAssign,
    subtitleLangs: subtitleLangs,
    audioMkvLangs: audioMkvLangs,
    subtitleMkvLangs: subtitleMkvLangs,
  );
}

