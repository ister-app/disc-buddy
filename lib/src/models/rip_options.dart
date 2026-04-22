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
  });

  /// True when all tools and credentials needed for LLM-based auto-naming
  /// are available.
  bool get canAutoName =>
      tmdbToken != null &&
      llmUrl != null &&
      llmModel != null &&
      mkvextract != null &&
      subtileOcr != null;
}
