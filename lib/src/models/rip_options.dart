class RipOptions {
  final String? device;
  final String outputDir;
  final String ffmpeg;
  final String ffprobe;
  final bool force;
  final String? mkvextract;
  final String? subtileOcr;
  final String? tmdbToken;
  final String? llmUrl;
  final String? llmKey;
  final String? llmModel;
  final String? titleHint;
  final int? seasonHint;

  const RipOptions({
    this.device,
    required this.outputDir,
    this.ffmpeg = 'ffmpeg',
    this.ffprobe = 'ffprobe',
    this.force = false,
    this.mkvextract,
    this.subtileOcr,
    this.tmdbToken,
    this.llmUrl,
    this.llmKey,
    this.llmModel,
    this.titleHint,
    this.seasonHint,
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
