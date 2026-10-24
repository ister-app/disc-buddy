import 'dart:io';

import '../audio/transcriber.dart';
import '../subtitles/subtitle_extractor.dart';
import '../utils/log.dart';
import '../utils/prompter.dart';
import 'duration_probe.dart';
import 'episode_matcher.dart';
import 'episode_math.dart' as em;
import 'llm_client.dart';
import 'naming_types.dart';
import 'subtitle_source.dart';
import 'subtitle_text.dart' as st;
import 'title_resolver.dart';
import 'tmdb_client.dart';

export 'naming_types.dart' show Fingerprint, VersionRole;

/// LLM-based auto-namer.
///
/// Two LLM calls per file:
///   1. Summary extraction — full subtitle text → summary + title guess.
///   2. Episode matching   — summary + TMDB episode list → episode pick.
///
/// No character-name scoring: TMDB guest stars are unreliable because
/// recurring plot characters appear in many subtitle files but are only
/// listed as guests in a single episode.
///
/// The work is split over three collaborators: [SubtitleSource] (steps 1-2),
/// [TitleResolver] (step 4) and [EpisodeMatcher] (step 5b). This class
/// orchestrates them and owns the one [DurationProbe] cache they share.
class AutoNamer {
  final SubtitleExtractor extractor;
  /// Optional whisper.cpp fallback for titles without any subtitle track.
  final Transcriber? transcriber;
  final TmdbClient tmdb;
  final LlmClient llm;
  final bool force;
  /// null = ask interactively; true = always use; false = never use.
  final bool? batchAssign;
  final LogCallback? onLog;

  /// Asks the user when the LLM cannot decide. `force` always wins: with it
  /// set every question is answered with its default.
  final Prompter _prompter;

  late final SubtitleSource _subtitles = SubtitleSource(
    extractor: extractor,
    transcriber: transcriber,
    llm: llm,
    log: _log,
  );
  late final TitleResolver _titles = TitleResolver(
    tmdb: tmdb,
    llm: llm,
    prompter: _prompter,
    log: _log,
  );
  late final EpisodeMatcher _episodes = EpisodeMatcher(
    tmdb: tmdb,
    llm: llm,
    prompter: _prompter,
    probe: DurationProbe(ffprobe: extractor.ffprobe),
    log: _log,
  );

  AutoNamer({
    required this.extractor,
    this.transcriber,
    required this.tmdb,
    required this.llm,
    this.force = false,
    this.batchAssign,
    this.onLog,
    Prompter? prompter,
  }) : _prompter = force
            ? const NonInteractivePrompter()
            : (prompter ?? const NonInteractivePrompter());

  void _log(String msg, {bool isError = false}) =>
      emitLog(onLog, msg, isError: isError);

  void close() {
    tmdb.close();
    llm.close();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<String?> nameFile(
    File mkvFile,
    String discName, {
    List<File> existingSrts = const [],
    String? titleHint,
    List<int>? seasonHint,
  }) async {
    final sub = await _subtitles.load(mkvFile, existingSrts);
    if (sub == null) return null;

    final fp = await _subtitles.extractSummary(sub.text);
    _subtitles.logFingerprint(fp);

    final winner = await _titles.resolve(
      discName: discName,
      fp: fp,
      titleHint: titleHint,
      seasonHint: seasonHint,
    );
    if (winner == null) return null;

    if (winner.type == 'movie') return _titles.movieStem(winner);
    _log('   Naming: ${mkvFile.path}');
    return _resolveEpisode(
      seriesId: winner.id,
      seriesName: winner.label,
      fp: fp,
      subtitleText: sub.text,
      subLang: sub.language,
      seasonHint: seasonHint,
      mediaFile: mkvFile,
    );
  }

  Future<Map<File, String?>> nameFilesBatch(
    List<NamingItem> items, {
    String? titleHint,
    List<int>? seasonHint,
  }) async {
    if (items.isEmpty) return {};

    if (items.length == 1 || titleHint == null) {
      final results = <File, String?>{};
      for (final item in items) {
        results[item.file] = await nameFile(
          item.file,
          item.discName,
          existingSrts: item.srts,
          titleHint: titleHint,
          seasonHint: seasonHint,
        );
      }
      return results;
    }

    // 1. Load subtitles + extract per-file summaries.
    final subs = <int, SubtitleText>{};
    final fps = <int, Fingerprint>{};
    for (var i = 0; i < items.length; i++) {
      _log(
        '   [${i + 1}/${items.length}] Loading subtitle: '
        '${items[i].file.path}',
      );
      final s = await _subtitles.load(items[i].file, items[i].srts);
      if (s != null) subs[i] = s;
    }
    if (subs.isEmpty) {
      _log('   AutoNamer: no subtitles available for batch.', isError: true);
      return {for (final it in items) it.file: null};
    }

    for (final entry in subs.entries) {
      _log(
        '   [${entry.key + 1}/${items.length}] Summarising: '
        '${items[entry.key].file.path}',
      );
      fps[entry.key] = await _subtitles.extractSummary(entry.value.text);
      _subtitles.logFingerprint(fps[entry.key]!);
    }

    // 2. Resolve title once using the first file's fingerprint.
    final firstIdx = subs.keys.first;
    final winner = await _titles.resolve(
      discName: items.first.discName,
      fp: fps[firstIdx]!,
      titleHint: titleHint,
      seasonHint: seasonHint,
    );
    if (winner == null) {
      return {for (final it in items) it.file: null};
    }

    if (winner.type == 'movie') {
      final stem = _titles.movieStem(winner);
      return {for (final it in items) it.file: stem};
    }

    // 3. Fetch episodes once.
    final subLang = subs.values.first.language;
    final episodes = await _episodes.fetchEpisodes(
      seriesId: winner.id,
      seriesName: winner.label,
      subLang: subLang,
      seasonHint: seasonHint,
    );
    if (episodes == null) {
      return {for (final it in items) it.file: null};
    }

    // 4. Decide whether to use batch assignment.
    final useBatch = await _resolveBatchAssign(items.length);

    // 5. Match episodes — batch or per-file.
    final picks = useBatch
        ? await _episodes.llmBatchAssign(
            episodes: episodes,
            items: items,
            subs: subs,
            fps: fps,
          )
        : await _episodes.matchEpisodesPerFile(
            episodes: episodes,
            items: items,
            subs: subs,
            fps: fps,
            seriesId: winner.id,
            subLang: subLang,
          );

    final results = <File, String?>{};
    for (var i = 0; i < items.length; i++) {
      final pick = picks[i];
      results[items[i].file] = pick?.stem;
      if (pick != null) {
        _log('   ${items[i].file.path} → ${pick.stem} "${pick.title}"');
      }
    }
    return results;
  }

  // ---------------------------------------------------------------------------
  // Episode resolution for a single file
  // ---------------------------------------------------------------------------

  Future<String?> _resolveEpisode({
    required int seriesId,
    required String seriesName,
    required Fingerprint fp,
    required String subtitleText,
    required String subLang,
    List<int>? seasonHint,
    File? mediaFile,
  }) async {
    final pick = await _episodes.matchEpisode(
      seriesId: seriesId,
      seriesName: seriesName,
      fp: fp,
      subtitleText: subtitleText,
      subLang: subLang,
      seasonHint: seasonHint,
      mediaFile: mediaFile,
    );
    if (pick == null) return null;
    _log(
      '   Identified as series: $seriesName '
      '${pick.stem} "${pick.title}"',
    );
    return pick.stem;
  }

  // ---------------------------------------------------------------------------
  // Batch vs per-file routing
  // ---------------------------------------------------------------------------

  /// Resolves whether to use batch assignment.
  /// - [batchAssign] == true/false → use that.
  /// - null + non-interactive (force) → false (safer default for unknown models).
  /// - null + interactive → ask the user.
  Future<bool> _resolveBatchAssign(int fileCount) async {
    if (batchAssign != null) return batchAssign!;
    if (fileCount <= 1) return false;
    return _prompter.confirm(
      '   Use batch assignment? (sends all excerpts in one LLM call, '
      'works better with large models) [y/N] ',
    );
  }

  // ---------------------------------------------------------------------------
  // Pure helpers, kept on the class for callers and tests that reach them
  // as `AutoNamer.x`. Implementations live in episode_math.dart and
  // subtitle_text.dart.
  // ---------------------------------------------------------------------------

  static String episodeStem(int season, int epStart, [int? epEnd]) =>
      em.episodeStem(season, epStart, epEnd);

  static String baseEpisodeTitle(String title) => em.baseEpisodeTitle(title);

  static ({int start, int end})? partGroup(
    List<SeasonEpisode> episodes,
    int season,
    int epNumber,
  ) =>
      em.partGroup(episodes, season, epNumber);

  static ({int epStart, int epEnd, bool playAll}) refineWithDuration({
    required List<SeasonEpisode> episodes,
    required int season,
    required int epNumber,
    required double? durationSecs,
    required double? medianSecs,
  }) =>
      em.refineWithDuration(
        episodes: episodes,
        season: season,
        epNumber: epNumber,
        durationSecs: durationSecs,
        medianSecs: medianSecs,
      );

  static List<VersionRole> classifyVersions({
    required List<double?> durationsSecs,
    required double? expectedSecs,
  }) =>
      em.classifyVersions(
          durationsSecs: durationsSecs, expectedSecs: expectedSecs);

  static List<SeasonEpisode> filterEpisodesBySimilarity(
    List<SeasonEpisode> episodes,
    List<String> summaries, {
    int maxEpisodes = 25,
  }) =>
      em.filterEpisodesBySimilarity(episodes, summaries,
          maxEpisodes: maxEpisodes);

  static double textSimilarity(String a, String b) => st.textSimilarity(a, b);

  static bool isNearDuplicateText(String a, String b) =>
      st.isNearDuplicateText(a, b);

  static String entityDenseExcerpt(String text, {int maxChars = 8000}) =>
      st.entityDenseExcerpt(text, maxChars: maxChars);

  static bool isWeakSummary(String s) => st.isWeakSummary(s);
}
