import 'package:disc_buddy/disc_buddy.dart';

/// Factories for the subtitle/naming tool chain, so flows can be tested with
/// fakes by passing a different [ExtractorFactory]/[AutoNamerFactory].
typedef ExtractorFactory = SubtitleExtractor Function(RipOptions opts);
typedef AutoNamerFactory = AutoNamer Function(
  RipOptions opts,
  SubtitleExtractor extractor, {
  bool? batchAssign,
});

SubtitleExtractor buildExtractor(RipOptions opts) => SubtitleExtractor(
      ffmpeg:     opts.ffmpeg,
      ffprobe:    opts.ffprobe,
      // May be built without OCR tools (whisper-only auto-naming); extraction
      // of image subtitles then fails gracefully via the ProcessException path.
      mkvextract: opts.mkvextract ?? 'mkvextract',
      subtileOcr: opts.subtileOcr ?? 'subtile-ocr',
    );

AutoNamer buildAutoNamer(
  RipOptions opts,
  SubtitleExtractor extractor, {
  bool? batchAssign,
  Prompter prompter = const TtyPrompter(),
}) =>
    AutoNamer(
      extractor: extractor,
      transcriber: opts.canTranscribe
          ? Transcriber(
              ffmpeg:       opts.ffmpeg,
              ffprobe:      opts.ffprobe,
              whisperCli:   opts.whisper!,
              whisperModel: opts.whisperModel!,
              language:     opts.transcribeLanguage,
            )
          : null,
      tmdb: TmdbClient(token: opts.tmdbToken!),
      llm: LlmClient(
        baseUrl: opts.llmUrl!,
        apiKey:  opts.llmKey ?? 'ollama',
        model:   opts.llmModel!,
      ),
      force: opts.force,
      batchAssign: batchAssign ?? opts.batchAssign,
      prompter: prompter,
    );
