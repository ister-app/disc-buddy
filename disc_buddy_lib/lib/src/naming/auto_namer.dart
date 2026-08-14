import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../utils/tty.dart';
import '../audio/transcriber.dart';
import '../subtitles/subtitle_extractor.dart';
import '../utils/sanitize.dart';
import 'llm_client.dart';
import 'tmdb_client.dart';

/// LLM-extracted summary used for title resolution and episode matching.
class Fingerprint {
  final String summary;
  final String titleGuess; // probable show / movie name (for TMDB search)

  const Fingerprint({required this.summary, required this.titleGuess});

  static const Fingerprint empty = Fingerprint(summary: '', titleGuess: '');

  bool get isEmpty => summary.isEmpty && titleGuess.isEmpty;
}

/// Role of one file among several cuts of the same episode.
/// See [AutoNamer.classifyVersions].
enum VersionRole { primary, extended, leaveUnnamed }

/// LLM-based auto-namer.
///
/// Two LLM calls per file:
///   1. Summary extraction — full subtitle text → summary + title guess.
///   2. Episode matching   — summary + TMDB episode list → episode pick.
///
/// No character-name scoring: TMDB guest stars are unreliable because
/// recurring plot characters appear in many subtitle files but are only
/// listed as guests in a single episode.
class AutoNamer {
  static const double _minTitleScore = 4.0;
  static const double _tieMargin = 2.0;
  static const int _summaryMaxChars = 20000;

  final SubtitleExtractor extractor;
  /// Optional whisper.cpp fallback for titles without any subtitle track.
  final Transcriber? transcriber;
  final TmdbClient tmdb;
  final LlmClient llm;
  final bool force;
  /// null = ask interactively; true = always use; false = never use.
  final bool? batchAssign;
  final void Function(String, {bool isError})? onLog;

  AutoNamer({
    required this.extractor,
    this.transcriber,
    required this.tmdb,
    required this.llm,
    this.force = false,
    this.batchAssign,
    this.onLog,
  });

  void _log(String msg, {bool isError = false}) {
    if (onLog != null) {
      onLog!(msg, isError: isError);
    } else if (isError) {
      stderr.writeln(msg);
    } else {
      stdout.writeln(msg);
    }
  }

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
    final sub = await _loadSubtitle(mkvFile, existingSrts);
    if (sub == null) return null;

    final fp = await _extractSummary(sub.text);
    _logFingerprint(fp);

    final winner = await _resolveTitle(
      discName: discName,
      fp: fp,
      titleHint: titleHint,
      seasonHint: seasonHint,
    );
    if (winner == null) return null;

    if (winner.type == 'movie') return _movieStem(winner);
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
    List<({File file, String discName, List<File> srts})> items, {
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
    final subs = <int, ({String text, String language})>{};
    final fps = <int, Fingerprint>{};
    for (var i = 0; i < items.length; i++) {
      _log(
        '   [${i + 1}/${items.length}] Loading subtitle: '
        '${items[i].file.path}',
      );
      final s = await _loadSubtitle(items[i].file, items[i].srts);
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
      fps[entry.key] = await _extractSummary(entry.value.text);
    }

    // 2. Resolve title once using the first file's fingerprint.
    final firstIdx = subs.keys.first;
    final winner = await _resolveTitle(
      discName: items.first.discName,
      fp: fps[firstIdx]!,
      titleHint: titleHint,
      seasonHint: seasonHint,
    );
    if (winner == null) {
      return {for (final it in items) it.file: null};
    }

    if (winner.type == 'movie') {
      final stem = _movieStem(winner);
      return {for (final it in items) it.file: stem};
    }

    // 3. Fetch episodes once.
    final subLang = subs.values.first.language;
    final seasons = <int>[];
    if (seasonHint != null && seasonHint.isNotEmpty) {
      seasons.addAll(seasonHint);
    } else {
      final n = await tmdb.getNumberOfSeasons(winner.id);
      if (n == null || n == 0) {
        _log(
          '   AutoNamer: no seasons for "${winner.label}" — skipping.',
          isError: true,
        );
        return {for (final it in items) it.file: null};
      }
      for (var s = 1; s <= n; s++) {
        seasons.add(s);
      }
    }
    final episodes = <({int season, EpisodeInfo ep})>[];
    for (final s in seasons) {
      final eps = await tmdb.getSeasonEpisodes(winner.id, s, language: subLang);
      for (final ep in eps) {
        episodes.add((season: s, ep: ep));
      }
    }
    if (episodes.isEmpty) {
      _log(
        '   AutoNamer: no episodes for "${winner.label}" — skipping.',
        isError: true,
      );
      return {for (final it in items) it.file: null};
    }

    // 4. Decide whether to use batch assignment.
    final useBatch = _resolveBatchAssign(items.length);

    // 5. Match episodes — batch or per-file.
    final picks = useBatch
        ? await _llmBatchAssign(
            episodes: episodes,
            items: items,
            subs: subs,
            fps: fps,
          )
        : await _matchEpisodesPerFile(
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
  // Step 1 — subtitle loading
  // ---------------------------------------------------------------------------

  Future<({String text, String language})?> _loadSubtitle(
    File mkvFile,
    List<File> existingSrts,
  ) async {
    if (existingSrts.isNotEmpty) {
      final en = existingSrts.firstWhere(
        (f) => _langFromSrtFile(f) == 'en',
        orElse: () => existingSrts.first,
      );
      try {
        final raw = await en.readAsString();
        final text = _stripSrtFormatting(_stripRecap(raw));
        if (text.trim().isNotEmpty) {
          return (text: text, language: _langFromSrtFile(en));
        }
      } catch (_) {}
    }

    _log('   Extracting subtitle for identification...');
    final result = await extractor.extractFirstSubtitleText(
      mkvFile,
      maxChars: 500000,
    );
    if (result == null || result.text.trim().isEmpty) {
      if (transcriber != null) {
        _log('   No subtitle track — transcribing audio with whisper...');
        final t = await transcriber!.transcribe(mkvFile);
        if (t != null && t.text.trim().isNotEmpty) {
          return (text: t.text, language: t.language);
        }
      }
      _log('   AutoNamer[step 1]: no subtitle track'
          '${transcriber != null ? ' and no usable transcript' : ''}'
          ' — skipping.', isError: true);
      return null;
    }
    return (
      text: _stripSrtFormatting(_stripRecap(result.text)),
      language: result.language,
    );
  }

  // ---------------------------------------------------------------------------
  // Step 2 — summary extraction (single LLM call on full subtitle text)
  // ---------------------------------------------------------------------------

  static const String _summarySystemPrompt =
      'Summarize this subtitle to identify which specific TV episode it is. '
      'Output STRICT JSON only. No markdown, no code fences.\n\n'
      'Schema: {"summary":"identifying description","titleGuess":"title or empty string"}\n\n'
      'Rules:\n'
      '- summary: 4-6 sentences. Focus on SPECIFIC UNIQUE events that '
      'distinguish this episode from all others in the series: '
      'character deaths or near-deaths, marriages or proposals, '
      'key objects (e.g. a specific pie, a shoe, a ring), '
      'first meetings or final confrontations, '
      'specific crimes or revelations, '
      'memorable dialogue quotes.\n'
      '- titleGuess: show or movie title if recognisable, else "".\n'
      '- On failure return exactly: {}';

  Future<Fingerprint> _extractSummary(String fullText) async {
    if (fullText.isEmpty) return Fingerprint.empty;
    // Sample from beginning, middle and end so climax scenes are included.
    final excerpt = _episodeExcerpt(fullText, chunkSize: _summaryMaxChars ~/ 3);

    _log('   Summarising subtitle (${excerpt.length} chars)...');
    final raw = await llm.chat(
      [
        {'role': 'system', 'content': _summarySystemPrompt},
        {'role': 'user', 'content': 'Subtitle:\n$excerpt'},
      ],
      timeout: const Duration(minutes: 5),
      maxTokens: 8000,
      temperature: 0.0,
    );

    if (raw == null || raw.trim().isEmpty) {
      _log('   Summary: no response from LLM.', isError: true);
      return Fingerprint.empty;
    }

    final parsed = _parseJsonWithMode(raw);
    if (parsed == null) {
      _log('   Summary: JSON parse failed. Raw: $raw', isError: true);
      return Fingerprint.empty;
    }

    final obj = parsed.obj;
    return Fingerprint(
      summary: (obj['summary'] as String? ?? '').trim(),
      titleGuess: (obj['titleGuess'] as String? ?? '').trim(),
    );
  }

  void _logFingerprint(Fingerprint fp) {
    if (fp.isEmpty) {
      _log('   Fingerprint: (empty — LLM summary failed)', isError: true);
      return;
    }
    _log('   Fingerprint:');
    if (fp.summary.isNotEmpty) _log('     summary:    ${fp.summary}');
    if (fp.titleGuess.isNotEmpty) _log('     titleGuess: ${fp.titleGuess}');
  }

  // ---------------------------------------------------------------------------
  // Step 4 — title resolution (deterministic, with LLM fallback)
  // ---------------------------------------------------------------------------

  Future<_TitlePick?> _resolveTitle({
    required String discName,
    required Fingerprint fp,
    String? titleHint,
    List<int>? seasonHint,
  }) async {
    final query = (titleHint != null && titleHint.isNotEmpty)
        ? titleHint
        : _pickSearchQuery(fp, discName);
    if (query.isEmpty) {
      _log('   AutoNamer[step 4]: no search query — skipping.', isError: true);
      return null;
    }

    final typeWanted = seasonHint != null ? 'series' : 'both';

    final movies = <MovieCandidate>[];
    final series = <TvCandidate>[];
    if (typeWanted == 'movie' || typeWanted == 'both') {
      movies.addAll(await tmdb.searchMovieCandidates(query));
    }
    if (typeWanted == 'series' || typeWanted == 'both') {
      series.addAll(await tmdb.searchTvCandidates(query));
    }
    if (movies.isEmpty && series.isEmpty) {
      _log(
        '   AutoNamer[step 4]: no TMDB candidates for "$query" — skipping.',
        isError: true,
      );
      return null;
    }

    // Title-hint shortcut.
    if (titleHint != null && titleHint.isNotEmpty) {
      if (typeWanted == 'series' && series.isNotEmpty) {
        final s = series.first;
        _log('   Title pick: "${s.name}" (TMDB top-1 for hint)');
        return _TitlePick(
          type: 'series',
          id: s.id,
          label: s.name,
          year: s.firstAirYear,
        );
      }
      if (typeWanted == 'movie' && movies.isNotEmpty) {
        final m = movies.first;
        _log('   Title pick: "${m.title}" (TMDB top-1 for hint)');
        return _TitlePick(
          type: 'movie',
          id: m.id,
          label: m.title,
          year: m.year,
        );
      }
    }

    // Deterministic scoring based on titleGuess similarity.
    final scored = <_ScoredCandidate>[];
    for (final m in movies) {
      scored.add(_ScoredCandidate(
        id: m.id,
        type: 'movie',
        label: m.year != null ? '${m.title} (${m.year})' : m.title,
        score: _scoreTitleCandidate(fp, _TitleCandidate.movie(m)),
        reason: '',
      ));
    }
    for (final t in series) {
      scored.add(_ScoredCandidate(
        id: t.id,
        type: 'series',
        label: t.firstAirYear != null
            ? '${t.name} (${t.firstAirYear})'
            : t.name,
        score: _scoreTitleCandidate(fp, _TitleCandidate.tv(t)),
        reason: '',
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final top = scored.first;
    _log(
      '   Title scores: '
      '${scored.take(5).map((c) => "${c.label}=${c.score.toStringAsFixed(1)}").join(", ")}',
    );

    if (top.score < _minTitleScore) {
      _log(
        '   AutoNamer: deterministic title score only '
        '${top.score.toStringAsFixed(1)} — falling back to LLM pick.',
        isError: true,
      );
      final picked = await _llmFallbackPick(
        fp: fp,
        top5: scored.take(5).toList(),
        kind: 'title',
      );
      if (picked == null) {
        _log('   AutoNamer: LLM fallback declined — skipping.', isError: true);
        return null;
      }
      return _titlePickFromScored(picked, movies, series);
    }

    final close = scored
        .where((c) => c != top && (top.score - c.score) < _tieMargin)
        .toList();
    if (close.isEmpty) {
      _log(
        '   Title pick: "${top.label}" '
        '(score ${top.score.toStringAsFixed(1)})',
      );
      return _titlePickFromScored(top, movies, series);
    }

    final chosen = await _promptTieBreak(
      kind: 'title',
      options: [top, ...close],
    );
    if (chosen == null) return null;
    _log(
      '   Title pick: "${chosen.label}" '
      '(score ${chosen.score.toStringAsFixed(1)})',
    );
    return _titlePickFromScored(chosen, movies, series);
  }

  _TitlePick _titlePickFromScored(
    _ScoredCandidate c,
    List<MovieCandidate> movies,
    List<TvCandidate> series,
  ) {
    if (c.type == 'movie') {
      final m = movies.firstWhere((m) => m.id == c.id);
      return _TitlePick(type: 'movie', id: m.id, label: m.title, year: m.year);
    }
    final s = series.firstWhere((s) => s.id == c.id);
    return _TitlePick(
      type: 'series',
      id: s.id,
      label: s.name,
      year: s.firstAirYear,
    );
  }

  String _pickSearchQuery(Fingerprint fp, String discName) {
    if (fp.titleGuess.isNotEmpty) return fp.titleGuess;
    if (!_genericDiscNames.hasMatch(discName.trim())) return discName;
    return '';
  }

  double _scoreTitleCandidate(Fingerprint fp, _TitleCandidate c) {
    if (fp.titleGuess.isEmpty) return 0.0;
    final tgLower = fp.titleGuess.toLowerCase();
    final titleLower = c.title.toLowerCase();
    if (tgLower == titleLower) return 10.0;
    if (tgLower.contains(titleLower) || titleLower.contains(tgLower)) {
      return 5.0;
    }
    return _similarity(tgLower, titleLower) * 4.0;
  }

  // ---------------------------------------------------------------------------
  // Step 5a — movie stem
  // ---------------------------------------------------------------------------

  String _movieStem(_TitlePick pick) {
    final stem = pick.year != null && pick.year != 0
        ? '${pick.label} (${pick.year})'
        : pick.label;
    _log('   Identified as movie: $stem');
    return sanitizeFilename(stem);
  }

  // ---------------------------------------------------------------------------
  // Step 5b — episode resolution
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
    final pick = await _matchEpisode(
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
  /// - null + force → false (safer default for unknown models).
  /// - null + interactive → ask the user.
  bool _resolveBatchAssign(int fileCount) {
    if (batchAssign != null) return batchAssign!;
    if (fileCount <= 1) return false;
    if (force) return false;
    _log(
      '   Use batch assignment? (sends all excerpts in one LLM call, '
      'works better with large models) [y/N] ',
    );
    final input = ttyReadLine().trim().toLowerCase();
    return input == 'y' || input == 'yes';
  }

  /// Per-file matching fallback: matches each subtitle independently.
  Future<Map<int, _EpisodePick?>> _matchEpisodesPerFile({
    required List<({int season, EpisodeInfo ep})> episodes,
    required List<({File file, String discName, List<File> srts})> items,
    required Map<int, ({String text, String language})> subs,
    required Map<int, Fingerprint> fps,
    required int seriesId,
    required String subLang,
  }) async {
    final picks = <int, _EpisodePick?>{};
    final usedStems = <String, int>{};

    // TMDB season 0 (specials) — fetched lazily, once, for files that match
    // no regular episode: DVD bonus content usually lives there.
    List<({int season, EpisodeInfo ep})>? specials;
    Future<List<({int season, EpisodeInfo ep})>> loadSpecials() async =>
        specials ??=
            (await tmdb.getSeasonEpisodes(seriesId, 0, language: subLang))
                .map((ep) => (season: 0, ep: ep))
                .toList();

    // Probe real durations once; the median anchors multi-part and
    // play-all detection when TMDB runtimes are missing.
    final durations = <int, double>{};
    for (var i = 0; i < items.length; i++) {
      final d = await _probeDurationSecs(items[i].file);
      if (d != null) durations[i] = d;
    }
    final medianSecs = _median(durations.values);

    // The same episode ripped from two discs: name the first copy only.
    final duplicateOf = <int, int>{};
    final subIdxs = subs.keys.toList()..sort();
    for (var a = 0; a < subIdxs.length; a++) {
      for (var b = a + 1; b < subIdxs.length; b++) {
        final i = subIdxs[a], j = subIdxs[b];
        if (duplicateOf.containsKey(j)) continue;
        if (isNearDuplicateText(subs[i]!.text, subs[j]!.text)) {
          duplicateOf[j] = i;
        }
      }
    }

    for (var i = 0; i < items.length; i++) {
      final sub = subs[i];
      // Reuse the per-file summary computed earlier; it's the strongest signal.
      final fp = fps[i] ?? Fingerprint.empty;
      if (sub == null) continue;
      final dupSrc = duplicateOf[i];
      if (dupSrc != null) {
        _log(
          '   AutoNamer: ${items[i].file.path} has near-identical subtitles '
          'to ${items[dupSrc].file.path} — duplicate copy, leaving unnamed.',
          isError: true,
        );
        picks[i] = null;
        continue;
      }
      _log(
        '   [${i + 1}/${items.length}] Naming: ${items[i].file.path}',
      );
      var pick = await _llmEpisodeMatch(
        fp: fp,
        episodes: episodes,
        subtitleText: sub.text,
      );
      if (pick == null) {
        // Retry once with a proper-noun-dense excerpt before giving up.
        _log('   Episode match failed — retrying with name-dense excerpt.');
        pick = await _llmEpisodeMatch(
          fp: fp,
          episodes: episodes,
          subtitleText: entityDenseExcerpt(sub.text),
        );
      }
      if (pick == null) {
        // Season-0 fallback: DVD bonus content lives in TMDB's specials.
        final sp = await loadSpecials();
        if (sp.isNotEmpty) {
          _log('   No regular episode matched — trying season 0 (specials).');
          pick = await _llmEpisodeMatch(
            fp: fp,
            episodes: sp,
            subtitleText: sub.text,
          );
          if (pick != null &&
              !await _verifyPick(fp: fp, pick: pick, episodes: sp)) {
            pick = null;
          }
        }
        if (pick == null) {
          picks[i] = await _promptEpisodePick(episodes: episodes);
          continue;
        }
        // Specials get no duration refinement (their runtimes vary wildly).
        final dupSp = usedStems[pick.stem];
        if (dupSp != null) {
          _log(
            '   AutoNamer: ${items[i].file.path} duplicate special '
            '${pick.stem}, kept ${items[dupSp].file.path} — skipping.',
            isError: true,
          );
          picks[i] = null;
        } else {
          usedStems[pick.stem] = i;
          picks[i] = pick;
        }
        continue;
      }

      final refined = _applyDurationRefinement(
        pick: pick,
        episodes: episodes,
        durationSecs: durations[i],
        medianSecs: medianSecs,
        filePath: items[i].file.path,
      );
      if (refined == null) {
        picks[i] = null; // play-all title
        continue;
      }
      pick = refined;

      final dup = usedStems[pick.stem];
      if (dup != null) {
        pick = await _handleStemConflict(
          i: i,
          dupIdx: dup,
          pick: pick,
          episodes: episodes,
          items: items,
          fps: fps,
          subs: subs,
          picks: picks,
          usedStems: usedStems,
          durations: durations,
          medianSecs: medianSecs,
        );
        if (pick == null) {
          picks[i] = null;
          continue;
        }
      }

      if (!await _verifyPick(fp: fp, pick: pick, episodes: episodes)) {
        picks[i] = null;
        continue;
      }
      usedStems[pick.stem] = i;
      picks[i] = pick;
    }
    return picks;
  }

  /// Resolves a duplicate-stem conflict between file [i] and earlier file
  /// [dupIdx]. Similar subtitle texts mean the disc carries the same episode
  /// in different cuts — resolved by duration (primary/extended/bonus).
  /// Dissimilar texts mean at most one file is that episode — resolved via
  /// one LLM disambiguation call, which may reassign [dupIdx]'s pick in
  /// place. Returns file [i]'s corrected pick, or null to leave it unnamed.
  Future<_EpisodePick?> _handleStemConflict({
    required int i,
    required int dupIdx,
    required _EpisodePick pick,
    required List<({int season, EpisodeInfo ep})> episodes,
    required List<({File file, String discName, List<File> srts})> items,
    required Map<int, Fingerprint> fps,
    required Map<int, ({String text, String language})> subs,
    required Map<int, _EpisodePick?> picks,
    required Map<String, int> usedStems,
    required Map<int, double> durations,
    required double? medianSecs,
  }) async {
    final textA = subs[dupIdx]?.text ?? '';
    final textB = subs[i]?.text ?? '';
    final similarity = textSimilarity(textA, textB);
    if (textA.isNotEmpty && textB.isNotEmpty && similarity >= 0.5) {
      return _resolveVersionConflict(
        i: i,
        dupIdx: dupIdx,
        pick: pick,
        episodes: episodes,
        items: items,
        picks: picks,
        usedStems: usedStems,
        durations: durations,
        medianSecs: medianSecs,
        similarity: similarity,
      );
    }

    _log(
      '   AutoNamer: ${items[i].file.path} and ${items[dupIdx].file.path} '
      'both matched ${pick.stem} — asking LLM to disambiguate.',
      isError: true,
    );
    final resolved = await _resolveStemConflict(
      firstFp: fps[dupIdx] ?? Fingerprint.empty,
      secondFp: fps[i] ?? Fingerprint.empty,
      contested: pick,
      episodes: episodes,
    );
    if (resolved == null) {
      _log(
        '   Disambiguation failed — keeping ${items[dupIdx].file.path}, '
        'leaving ${items[i].file.path} unnamed.',
        isError: true,
      );
      return null;
    }

    // Reassign the earlier claimant when the LLM moved it elsewhere.
    if (resolved.first > 0) {
      final newFirst = _refineOrNull(
        _pickFromEpisodeIndex(episodes, resolved.first),
        episodes: episodes,
        durationSecs: durations[dupIdx],
        medianSecs: medianSecs,
        filePath: items[dupIdx].file.path,
      );
      if (newFirst != null && newFirst.stem != picks[dupIdx]?.stem) {
        _log(
          '   Disambiguation: ${items[dupIdx].file.path} reassigned '
          '→ ${newFirst.stem} "${newFirst.title}".',
        );
        usedStems.remove(picks[dupIdx]?.stem);
        picks[dupIdx] = newFirst;
        usedStems[newFirst.stem] = dupIdx;
      }
    } else {
      _log(
        '   Disambiguation: ${items[dupIdx].file.path} could not be placed '
        '— leaving it unnamed.',
        isError: true,
      );
      usedStems.remove(picks[dupIdx]?.stem);
      picks[dupIdx] = null;
    }

    if (resolved.second == 0) {
      _log(
        '   Disambiguation: ${items[i].file.path} could not be placed '
        '— leaving unnamed.',
        isError: true,
      );
      return null;
    }
    final newPick = _refineOrNull(
      _pickFromEpisodeIndex(episodes, resolved.second),
      episodes: episodes,
      durationSecs: durations[i],
      medianSecs: medianSecs,
      filePath: items[i].file.path,
    );
    if (newPick == null) return null;
    if (usedStems.containsKey(newPick.stem)) {
      _log(
        '   Disambiguation: ${newPick.stem} already taken — leaving '
        '${items[i].file.path} unnamed.',
        isError: true,
      );
      return null;
    }
    return newPick;
  }

  /// Same-episode-different-cuts resolution: the file whose duration best
  /// matches the TMDB runtime keeps the plain stem, an extended cut gets an
  /// " (extended)" suffix, an episode-plus-extras cut stays unnamed.
  /// May demote the earlier claimant [dupIdx] in place.
  _EpisodePick? _resolveVersionConflict({
    required int i,
    required int dupIdx,
    required _EpisodePick pick,
    required List<({int season, EpisodeInfo ep})> episodes,
    required List<({File file, String discName, List<File> srts})> items,
    required Map<int, _EpisodePick?> picks,
    required Map<String, int> usedStems,
    required Map<int, double> durations,
    required double? medianSecs,
    required double similarity,
  }) {
    _log(
      '   AutoNamer: ${items[i].file.path} and ${items[dupIdx].file.path} '
      'carry the same episode ${pick.stem} in different cuts '
      '(similarity ${similarity.toStringAsFixed(2)}) — resolving by duration.',
    );
    final expected = _expectedSecsFor(pick, episodes, medianSecs);
    final roles = classifyVersions(
      durationsSecs: [durations[dupIdx], durations[i]],
      expectedSecs: expected,
    );

    // Builds the pick for a non-primary role, registering its stem.
    _EpisodePick? assignSecondary(int fileIdx, VersionRole role) {
      if (role == VersionRole.leaveUnnamed) {
        _log(
          '   Version: ${items[fileIdx].file.path} runs '
          '${((durations[fileIdx] ?? 0) / 60).toStringAsFixed(1)} min — '
          'episode-plus-extras cut, leaving unnamed.',
          isError: true,
        );
        return null;
      }
      final stem = _uniqueExtendedStem(pick.stem, usedStems);
      _log(
        '   Version: ${items[fileIdx].file.path} → "$stem" (longer cut).',
      );
      return _EpisodePick(
        stem: stem,
        title: pick.title,
        season: pick.season,
        ep: pick.ep,
        epEnd: pick.epEnd,
      );
    }

    if (roles[1] == VersionRole.primary) {
      // New file is the better version: demote the earlier claimant.
      usedStems.remove(pick.stem);
      final demoted = assignSecondary(dupIdx, roles[0]);
      picks[dupIdx] = demoted;
      if (demoted != null) usedStems[demoted.stem] = dupIdx;
      _log('   Version: ${items[i].file.path} keeps ${pick.stem}.');
      return pick;
    }
    // Earlier claimant stays primary; place the new file.
    return assignSecondary(i, roles[1]);
  }

  /// Expected duration in seconds of the episode(s) covered by [pick]:
  /// summed TMDB runtimes, with [medianSecs] filling in per missing part.
  double? _expectedSecsFor(
    _EpisodePick pick,
    List<({int season, EpisodeInfo ep})> episodes,
    double? medianSecs,
  ) {
    var total = 0.0;
    for (var n = pick.ep; n <= pick.epEnd; n++) {
      final e = episodes
          .where((x) => x.season == pick.season && x.ep.number == n)
          .toList();
      final r = e.isEmpty ? null : e.first.ep.runtime;
      if (r != null) {
        total += r * 60;
      } else if (medianSecs != null) {
        total += medianSecs;
      } else {
        return null;
      }
    }
    return total == 0 ? null : total;
  }

  static String _uniqueExtendedStem(String base, Map<String, int> usedStems) {
    var stem = '$base (extended)';
    for (var n = 2; usedStems.containsKey(stem); n++) {
      stem = '$base (extended $n)';
    }
    return stem;
  }

  _EpisodePick? _refineOrNull(
    _EpisodePick pick, {
    required List<({int season, EpisodeInfo ep})> episodes,
    required double? durationSecs,
    required double? medianSecs,
    required String filePath,
  }) =>
      _applyDurationRefinement(
        pick: pick,
        episodes: episodes,
        durationSecs: durationSecs,
        medianSecs: medianSecs,
        filePath: filePath,
      );

  static double? _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.length < 3) return null;
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  // ---------------------------------------------------------------------------
  // Batch assignment — one LLM call assigns all files to episodes at once.
  // ---------------------------------------------------------------------------

  /// Three chunks: beginning, middle (50%), and end of episode.
  /// Sampling the true end is critical — climax scenes are often the most
  /// distinctive (character deaths, weddings, confrontations).
  static String _episodeExcerpt(String text, {int chunkSize = 2500}) {
    if (text.length <= chunkSize * 3) return text;
    final half   = text.length ~/ 2;
    final endOff = text.length - chunkSize;
    return '${text.substring(0, chunkSize)}\n...\n'
        '${text.substring(half, half + chunkSize)}\n...\n'
        '${text.substring(endOff)}';
  }

  /// Returns true when [text] looks like English based on stopword frequency.
  static bool _looksEnglish(String text) {
    const stopwords = {
      'the', 'and', 'you', 'that', 'was', 'for', 'are', 'with',
      'his', 'they', 'this', 'have', 'from', 'not', 'but', 'what',
      'all', 'were', 'when', 'your', 'she', 'him',
    };
    final sample = text.length > 800 ? text.substring(0, 800) : text;
    final words = sample
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((w) => w.length >= 2)
        .toList();
    if (words.isEmpty) return false;
    final hits = words.where(stopwords.contains).length;
    // At least 8% of sample words should be English stopwords.
    return hits / words.length >= 0.08;
  }

  Future<Map<int, _EpisodePick?>> _llmBatchAssign({
    required List<({int season, EpisodeInfo ep})> episodes,
    required List<({File file, String discName, List<File> srts})> items,
    required Map<int, ({String text, String language})> subs,
    required Map<int, Fingerprint> fps,
  }) async {
    // Pre-filter episodes to most relevant subset using summary similarity.
    final allSummaries = fps.values
        .map((fp) => fp.summary)
        .where((s) => s.isNotEmpty)
        .toList();
    final filteredEpisodes = filterEpisodesBySimilarity(
      episodes,
      allSummaries,
      // Never filter below the number of files to assign (+ headroom, since
      // the Jaccard pre-filter can push out an exact-match candidate).
      maxEpisodes: math.max(25, items.length + 10),
    );
    _log(
      '   Batch assignment: episodes before filter=${episodes.length}, '
      'after filter=${filteredEpisodes.length}.',
    );

    // Build subtitle block: summaries are primary; raw excerpts are fallback.
    final subBuf = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final sub = subs[i];
      if (sub == null) continue;
      final fp = fps[i];
      final hasSummary = fp != null && fp.summary.isNotEmpty;
      final isEnglish = _looksEnglish(sub.text);
      final weak = hasSummary && isWeakSummary(fp.summary);

      if (!isEnglish && !hasSummary) {
        _log(
          '   Batch assignment: file ${i + 1} subtitle does not look English'
          ' and has no summary — flagged for LLM.',
          isError: true,
        );
      } else if (!isEnglish) {
        _log(
          '   Batch assignment: file ${i + 1} subtitle does not look English'
          ' — flagged for LLM.',
          isError: true,
        );
      }

      subBuf.write('[${i + 1}]');
      if (!isEnglish) {
        // Non-English: summary is the only usable signal.
        if (hasSummary) {
          subBuf.writeln(' ⚠️ Non-English subtitle — summary only: ${fp.summary}');
        } else {
          subBuf.writeln(
            ' ⚠️ Non-English subtitle with no summary — no reliable signal.',
          );
        }
      } else if (weak) {
        // Weak English summary: include it but also provide a larger excerpt.
        subBuf.writeln(' ⚠️ Weak summary — rely more on subtitle text:');
        subBuf.writeln('  Summary: ${fp.summary}');
        subBuf.writeln(
          _episodeExcerpt(sub.text, chunkSize: 1200)
              .split('\n')
              .map((l) => '  $l')
              .join('\n'),
        );
      } else if (hasSummary) {
        // Strong English summary: use it as the sole signal.
        subBuf.writeln(' ${fp.summary}');
      } else {
        // No summary: fall back to a compact excerpt.
        subBuf.writeln();
        subBuf.writeln(
          _episodeExcerpt(sub.text, chunkSize: 800)
              .split('\n')
              .map((l) => '  $l')
              .join('\n'),
        );
      }
      subBuf.writeln();
    }

    // Build episode list with extracted entities for better matching.
    final epBuf = StringBuffer();
    for (var i = 0; i < filteredEpisodes.length; i++) {
      final c = filteredEpisodes[i];
      final label =
          's${c.season.toString().padLeft(2, "0")}'
          'e${c.ep.number.toString().padLeft(2, "0")}';
      final entities = _extractEntities(c.ep.overview);
      epBuf.write('(${i + 1}) $label "${c.ep.title}"');
      if (entities.isNotEmpty) {
        epBuf.write(' [Entities: ${entities.join(", ")}]');
      }
      epBuf.write(': ${c.ep.overview}');
      if (c.ep.guestStars.isNotEmpty) {
        epBuf.write(' [Guests: ${c.ep.guestStars}]');
      }
      epBuf.writeln();
    }

    final n = items.length;
    final m = filteredEpisodes.length;
    _log(
      '   Batch assignment: $n subtitle(s) → $m episode(s) '
      '(${subBuf.length} chars).',
    );

    final response = await llm.chat(
      timeout: const Duration(minutes: 10),
      maxTokens: 32000,
      temperature: 0.0,
      [
        {
          'role': 'system',
          'content':
              'Match each subtitle file (1..$n) to the episode (1..$m) '
              'it belongs to.\n'
              'Rules:\n'
              '- Each file belongs to AT MOST one episode. Use ep=0 if no '
              'confident match is found. Episodes may go unassigned.\n'
              '- File position numbers and any filenames carry NO information '
              'about episode order — files may be arbitrarily ordered.\n'
              '- DO NOT use any prior knowledge of the show. '
              'Decide ONLY by matching subtitle content against the episode '
              'descriptions provided below.\n'
              '- If a summary is available, use it as the PRIMARY signal.\n'
              '- If only raw subtitle text is available, find a specific line '
              'in the excerpt that matches a phrase in an episode description '
              '— that quote is your evidence.\n'
              '- For files marked ⚠️ Non-English, use the summary ONLY — '
              'do NOT quote subtitle text.\n'
              '- For files marked ⚠️ Weak summary, rely more on subtitle text.\n'
              '- Consider all files together: prefer consistent season '
              'progression and avoid contradictory assignments.\n'
              'In your reasoning: for each file write '
              '"File N: [evidence] → matches ep M because [reason]" '
              'or "File N: no confident match".\n'
              'Then output JSON.\n'
              'Output format (confidence is 0.0–1.0, ep=0 means unassigned):\n'
              '{"reasoning":"evidence for every file",'
              '"assignments":{"1":{"ep":N,"confidence":0.0},...}}',
        },
        {
          'role': 'user',
          'content': 'Subtitle files:\n$subBuf\nEpisodes:\n$epBuf\nJSON:',
        },
      ],
    );

    if (response == null) {
      _log('   Batch assignment: no response from LLM.', isError: true);
      return {};
    }

    final obj = _parseJsonObject(response);
    if (obj == null) {
      _log(
        '   Batch assignment: JSON parse failed. Raw: $response',
        isError: true,
      );
      return {};
    }

    if (obj.containsKey('reasoning')) {
      final reasoning = obj['reasoning'] as String? ?? '';
      if (reasoning.isNotEmpty) {
        _log('   LLM reasoning: $reasoning');
      }
    }

    final rawAssignments = obj['assignments'];
    if (rawAssignments is! Map) {
      _log('   Batch assignment: "assignments" missing or wrong type.',
          isError: true);
      return {};
    }

    // Parse all raw assignments; accept both int and {"ep":N,"confidence":C}.
    final fileAssignments = <int, ({int epIdx, double confidence})>{};
    for (final entry in rawAssignments.entries) {
      final fileIdx = (int.tryParse('${entry.key}') ?? 0) - 1;
      if (fileIdx < 0 || fileIdx >= items.length) continue;

      int rawEp;
      double confidence;
      if (entry.value is Map) {
        final m = entry.value as Map;
        rawEp = m['ep'] is int
            ? m['ep'] as int
            : int.tryParse('${m['ep']}') ?? 0;
        confidence = m['confidence'] is num
            ? (m['confidence'] as num).toDouble()
            : 0.7;
      } else {
        rawEp = entry.value is int
            ? entry.value as int
            : int.tryParse('${entry.value}') ?? 0;
        confidence = 0.7;
      }

      final epIdx = rawEp - 1; // -1 when LLM returned 0 (unassigned)

      if (epIdx == -1) {
        _log('   Batch assignment: file ${fileIdx + 1} → unassigned (ep=0).');
        continue;
      }
      if (epIdx < 0 || epIdx >= filteredEpisodes.length) {
        _log(
          '   Batch assignment: file ${fileIdx + 1} got ep=$rawEp '
          '(out of range) — dropping.',
          isError: true,
        );
        continue;
      }
      if (confidence < 0.4) {
        _log(
          '   Batch assignment: file ${fileIdx + 1} → ep $rawEp '
          'confidence=${confidence.toStringAsFixed(2)} < 0.4 — dropping.',
          isError: true,
        );
        continue;
      }

      fileAssignments[fileIdx] = (epIdx: epIdx, confidence: confidence);
    }

    // Resolve duplicate episode assignments: keep highest confidence.
    final epToBest = <int, ({int fileIdx, double confidence})>{};
    for (final entry in fileAssignments.entries) {
      final fileIdx = entry.key;
      final epIdx = entry.value.epIdx;
      final conf = entry.value.confidence;

      if (!epToBest.containsKey(epIdx)) {
        epToBest[epIdx] = (fileIdx: fileIdx, confidence: conf);
      } else if (conf > epToBest[epIdx]!.confidence) {
        final displaced = epToBest[epIdx]!.fileIdx;
        _log(
          '   Batch assignment: file ${displaced + 1} displaced by '
          'file ${fileIdx + 1} for ep ${epIdx + 1} '
          '(confidence ${conf.toStringAsFixed(2)} > '
          '${epToBest[epIdx]!.confidence.toStringAsFixed(2)}).',
          isError: true,
        );
        epToBest[epIdx] = (fileIdx: fileIdx, confidence: conf);
      } else {
        _log(
          '   Batch assignment: file ${fileIdx + 1} duplicate for ep ${epIdx + 1} '
          '— keeping file ${epToBest[epIdx]!.fileIdx + 1} '
          '(confidence ${epToBest[epIdx]!.confidence.toStringAsFixed(2)} >= '
          '${conf.toStringAsFixed(2)}).',
          isError: true,
        );
      }
    }

    // Build final picks from resolved assignments, refined against the
    // files' real durations (multi-part ranges, play-all rejection).
    final durations = <int, double>{};
    for (var i = 0; i < items.length; i++) {
      final d = await _probeDurationSecs(items[i].file);
      if (d != null) durations[i] = d;
    }
    final medianSecs = _median(durations.values);

    final picks = <int, _EpisodePick?>{};
    for (final entry in epToBest.entries) {
      final epIdx = entry.key;
      final fileIdx = entry.value.fileIdx;
      final c = filteredEpisodes[epIdx];
      final pick = _EpisodePick(
        stem: episodeStem(c.season, c.ep.number),
        title: c.ep.title,
        season: c.season,
        ep: c.ep.number,
      );
      final refined = _applyDurationRefinement(
        pick: pick,
        episodes: episodes,
        durationSecs: durations[fileIdx],
        medianSecs: medianSecs,
        filePath: items[fileIdx].file.path,
      );
      if (refined == null) {
        picks[fileIdx] = null; // play-all title
        continue;
      }
      _log(
        '   [${fileIdx + 1}/${items.length}] → ${refined.stem} '
        '"${refined.title}"',
      );
      picks[fileIdx] = refined;
    }

    return picks;
  }

  // ---------------------------------------------------------------------------
  // Duration-aware refinement (multi-part ranges, play-all detection)
  // ---------------------------------------------------------------------------

  /// Builds an `s01e02` stem, or `s01e02-e04` when [epEnd] > [epStart].
  static String episodeStem(int season, int epStart, [int? epEnd]) {
    final s = season.toString().padLeft(2, '0');
    final e1 = epStart.toString().padLeft(2, '0');
    if (epEnd == null || epEnd == epStart) return 's${s}e$e1';
    return 's${s}e$e1-e${epEnd.toString().padLeft(2, "0")}';
  }

  /// Strips a trailing part marker — "(2)", "[2]", "Part 3", "- Part One" —
  /// so multi-part episodes ("iPsycho (1)"/"iPsycho (2)") share a base title.
  static String baseEpisodeTitle(String title) => title
      .replaceFirst(
        RegExp(
          r'\s*[-–—:,]?\s*(?:[(\[]\s*(?:part\s*)?(?:\d+|one|two|three)\s*[)\]]'
          r'|\bpart\s+(?:\d+|one|two|three))\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  /// Returns the consecutive run of episodes in [season] that share the same
  /// base title as episode [epNumber] (a multi-part group), or null when the
  /// episode stands alone.
  static ({int start, int end})? partGroup(
    List<({int season, EpisodeInfo ep})> episodes,
    int season,
    int epNumber,
  ) {
    final inSeason = episodes.where((e) => e.season == season).toList()
      ..sort((a, b) => a.ep.number.compareTo(b.ep.number));
    final idx = inSeason.indexWhere((e) => e.ep.number == epNumber);
    if (idx < 0) return null;
    final base = baseEpisodeTitle(inSeason[idx].ep.title);
    if (base.isEmpty) return null;

    var start = idx;
    while (start > 0 &&
        inSeason[start - 1].ep.number == inSeason[start].ep.number - 1 &&
        baseEpisodeTitle(inSeason[start - 1].ep.title) == base) {
      start--;
    }
    var end = idx;
    while (end < inSeason.length - 1 &&
        inSeason[end + 1].ep.number == inSeason[end].ep.number + 1 &&
        baseEpisodeTitle(inSeason[end + 1].ep.title) == base) {
      end++;
    }
    if (start == end) return null;
    return (start: inSeason[start].ep.number, end: inSeason[end].ep.number);
  }

  /// Classifies a matched episode against the file's real duration.
  ///
  /// Returns the episode range the file most plausibly covers, or
  /// `playAll: true` when the duration is far beyond any multi-part group
  /// (a whole-disc "play all" title that should not claim an episode name).
  /// TMDB per-episode runtimes are the primary yardstick — a 44-minute
  /// special whose TMDB runtime is 44 stays a single episode; the batch
  /// median only fills in when runtimes are missing.
  static ({int epStart, int epEnd, bool playAll}) refineWithDuration({
    required List<({int season, EpisodeInfo ep})> episodes,
    required int season,
    required int epNumber,
    required double? durationSecs,
    required double? medianSecs,
  }) {
    final single = (epStart: epNumber, epEnd: epNumber, playAll: false);
    if (durationSecs == null) return single;

    final inSeason = episodes.where((e) => e.season == season).toList();
    final picked = inSeason.where((e) => e.ep.number == epNumber).toList();
    final ownRuntime = picked.isEmpty ? null : picked.first.ep.runtime;
    final fallbackMins = medianSecs != null ? medianSecs / 60 : null;

    double? groupSumMins;
    final group = partGroup(episodes, season, epNumber);
    if (group != null) {
      groupSumMins = 0;
      for (var n = group.start; n <= group.end; n++) {
        final e = inSeason.where((e) => e.ep.number == n).toList();
        final r = e.isEmpty ? null : e.first.ep.runtime;
        final mins = r?.toDouble() ?? ownRuntime?.toDouble() ?? fallbackMins;
        if (mins == null) {
          groupSumMins = null;
          break;
        }
        groupSumMins = groupSumMins! + mins;
      }
    }

    // Play-all: several times the median and well beyond the part group.
    if (medianSecs != null && durationSecs / medianSecs >= 3.6) {
      final beyondGroup =
          groupSumMins == null || durationSecs > groupSumMins * 60 * 1.3;
      if (beyondGroup) return (epStart: epNumber, epEnd: epNumber, playAll: true);
    }

    // Matches its own single-episode runtime → single, even for long specials.
    if (ownRuntime != null && durationSecs <= ownRuntime * 60 * 1.5) {
      return single;
    }

    if (group != null) {
      if (groupSumMins != null &&
          (durationSecs - groupSumMins * 60).abs() <= groupSumMins * 60 * 0.25) {
        return (epStart: group.start, epEnd: group.end, playAll: false);
      }
      // No usable runtimes: infer the part count from the median.
      if (medianSecs != null) {
        final k = (durationSecs / medianSecs)
            .round()
            .clamp(1, group.end - group.start + 1);
        if (k >= 2) {
          return (
            epStart: group.start,
            epEnd: group.start + k - 1,
            playAll: false,
          );
        }
      }
      return single;
    }

    // No part group: only claim a range when consecutive runtimes genuinely
    // sum to the file duration (within 20%).
    final expectedMins = ownRuntime?.toDouble() ?? fallbackMins;
    if (expectedMins == null || durationSecs <= expectedMins * 60 * 1.5) {
      return single;
    }
    ({int epStart, int epEnd, bool playAll})? bestRange;
    var bestErr = double.infinity;
    final sorted = [...inSeason]
      ..sort((a, b) => a.ep.number.compareTo(b.ep.number));
    final startIdx = sorted.indexWhere((e) => e.ep.number == epNumber);
    if (startIdx >= 0) {
      var sumMins = 0.0;
      for (var i = startIdx; i < sorted.length && i < startIdx + 4; i++) {
        if (i > startIdx &&
            sorted[i].ep.number != sorted[i - 1].ep.number + 1) {
          break;
        }
        final r = sorted[i].ep.runtime?.toDouble() ?? fallbackMins;
        if (r == null) break;
        sumMins += r;
        if (i == startIdx) continue;
        final err = (durationSecs - sumMins * 60).abs() / (sumMins * 60);
        if (err <= 0.2 && err < bestErr) {
          bestErr = err;
          bestRange = (
            epStart: epNumber,
            epEnd: sorted[i].ep.number,
            playAll: false,
          );
        }
      }
    }
    return bestRange ?? single;
  }

  /// Jaccard word-set similarity between two subtitle texts (case-folded).
  /// Unlike [isNearDuplicateText] there is no length-ratio gate, so an
  /// extended cut still scores high against its broadcast version.
  static double textSimilarity(String a, String b) =>
      _similarity(a.toLowerCase(), b.toLowerCase());

  /// Assigns a [VersionRole] to each of several files that carry the same
  /// episode in different cuts. The file whose duration sits closest to
  /// [expectedSecs] becomes [VersionRole.primary]; the rest become
  /// [VersionRole.extended] up to 1.5× the expected duration and
  /// [VersionRole.leaveUnnamed] beyond that (episode-plus-extras cuts).
  /// With no expected duration or no known durations the first file wins and
  /// the rest are extended — skipping without evidence is too aggressive.
  static List<VersionRole> classifyVersions({
    required List<double?> durationsSecs,
    required double? expectedSecs,
  }) {
    if (durationsSecs.isEmpty) return const [];
    var best = 0;
    if (expectedSecs != null) {
      var bestErr = double.infinity;
      for (var i = 0; i < durationsSecs.length; i++) {
        final d = durationsSecs[i];
        if (d == null) continue;
        final err = (d - expectedSecs).abs();
        if (err < bestErr) {
          bestErr = err;
          best = i;
        }
      }
    }
    return [
      for (var i = 0; i < durationsSecs.length; i++)
        i == best
            ? VersionRole.primary
            : (expectedSecs == null ||
                    durationsSecs[i] == null ||
                    durationsSecs[i]! <= expectedSecs * 1.5)
                ? VersionRole.extended
                : VersionRole.leaveUnnamed,
    ];
  }

  /// True when two subtitle texts are near-identical — the same episode
  /// ripped from two discs. Compares length ratio plus Jaccard word-set
  /// similarity, so capitalisation and small CC differences don't matter.
  static bool isNearDuplicateText(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    final ratio = a.length < b.length ? a.length / b.length : b.length / a.length;
    if (ratio < 0.8) return false;
    return _similarity(a.toLowerCase(), b.toLowerCase()) >= 0.8;
  }

  /// Filters [episodes] to the top [maxEpisodes] most similar to any of
  /// [summaries], using Jaccard word similarity on lowercased text.
  /// Returns the original list unchanged when there are no summaries or the
  /// list is already within the limit.
  static List<({int season, EpisodeInfo ep})> filterEpisodesBySimilarity(
    List<({int season, EpisodeInfo ep})> episodes,
    List<String> summaries, {
    int maxEpisodes = 25,
  }) {
    if (summaries.isEmpty || episodes.length <= maxEpisodes) return episodes;

    final scored = episodes.map((e) {
      final overviewLower = e.ep.overview.toLowerCase();
      var best = 0.0;
      for (final summary in summaries) {
        final s = _similarity(summary.toLowerCase(), overviewLower);
        if (s > best) best = s;
      }
      return (entry: e, score: best);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return scored.take(maxEpisodes).map((s) => s.entry).toList();
  }

  /// Returns true when [s] is too short, lacks punctuation, or is not English.
  static bool isWeakSummary(String s) {
    if (s.length < 80) return true;
    if (!RegExp(r'[.!?,;]').hasMatch(s)) return true;
    if (!_looksEnglish(s)) return true;
    return false;
  }

  /// Extracts up to 8 unique capitalised names / phrases from [text].
  static List<String> _extractEntities(String text) {
    final seen = <String>{};
    final entities = <String>[];
    for (final m in RegExp(r'\b[A-Z][a-z]{1,}(?:\s[A-Z][a-z]{1,})*\b')
        .allMatches(text)) {
      final word = m.group(0)!;
      if (seen.add(word)) entities.add(word);
      if (entities.length >= 8) break;
    }
    return entities;
  }

  /// Fetches all episodes from TMDB and asks the LLM to match the subtitle
  /// to the correct episode. Falls back to a manual prompt if the LLM
  /// cannot identify the episode.
  Future<_EpisodePick?> _matchEpisode({
    required int seriesId,
    required String seriesName,
    required Fingerprint fp,
    required String subtitleText,
    required String subLang,
    List<int>? seasonHint,
    File? mediaFile,
  }) async {
    // Determine seasons.
    final seasons = <int>[];
    if (seasonHint != null && seasonHint.isNotEmpty) {
      seasons.addAll(seasonHint);
    } else {
      final n = await tmdb.getNumberOfSeasons(seriesId);
      if (n == null || n == 0) {
        _log(
          '   AutoNamer[step 5b]: no seasons for "$seriesName" — skipping.',
          isError: true,
        );
        return null;
      }
      for (var s = 1; s <= n; s++) {
        seasons.add(s);
      }
    }

    // Gather all episodes.
    final episodes = <({int season, EpisodeInfo ep})>[];
    for (final s in seasons) {
      final eps = await tmdb.getSeasonEpisodes(seriesId, s, language: subLang);
      for (final ep in eps) {
        episodes.add((season: s, ep: ep));
      }
    }
    if (episodes.isEmpty) {
      _log(
        '   AutoNamer[step 5b]: no episodes for "$seriesName" — skipping.',
        isError: true,
      );
      return null;
    }

    // LLM matches subtitle excerpt to episode.
    var pick = await _llmEpisodeMatch(
      fp: fp,
      episodes: episodes,
      subtitleText: subtitleText,
    );
    if (pick == null) {
      // Retry once with a proper-noun-dense excerpt before giving up.
      _log('   Episode match failed — retrying with name-dense excerpt.');
      pick = await _llmEpisodeMatch(
        fp: fp,
        episodes: episodes,
        subtitleText: entityDenseExcerpt(subtitleText),
      );
    }
    if (pick != null) {
      if (mediaFile != null) {
        final refined = _applyDurationRefinement(
          pick: pick,
          episodes: episodes,
          durationSecs: await _probeDurationSecs(mediaFile),
          medianSecs: null,
          filePath: mediaFile.path,
        );
        if (refined == null) return null; // play-all title
        pick = refined;
      }
      if (!await _verifyPick(fp: fp, pick: pick, episodes: episodes)) {
        return null;
      }
      return pick;
    }

    // Season-0 fallback: DVD bonus content lives in TMDB's specials.
    final specials =
        (await tmdb.getSeasonEpisodes(seriesId, 0, language: subLang))
            .map((ep) => (season: 0, ep: ep))
            .toList();
    if (specials.isNotEmpty) {
      _log('   No regular episode matched — trying season 0 (specials).');
      final spPick = await _llmEpisodeMatch(
        fp: fp,
        episodes: specials,
        subtitleText: subtitleText,
      );
      if (spPick != null &&
          await _verifyPick(fp: fp, pick: spPick, episodes: specials)) {
        return spPick;
      }
    }

    // LLM declined — ask user (or skip in force mode).
    return _promptEpisodePick(episodes: episodes);
  }

  // ---------------------------------------------------------------------------
  // LLM episode match — raw subtitle excerpt + TMDB episode list
  // ---------------------------------------------------------------------------

  Future<_EpisodePick?> _llmEpisodeMatch({
    required Fingerprint fp,
    required List<({int season, EpisodeInfo ep})> episodes,
    required String subtitleText,
  }) async {
    if (episodes.isEmpty) return null;

    _log(
      '   Episode match: sending ${subtitleText.length} chars of subtitle text.',
    );

    final epBuf = StringBuffer();
    for (var i = 0; i < episodes.length; i++) {
      final c = episodes[i];
      final label =
          's${c.season.toString().padLeft(2, "0")}'
          'e${c.ep.number.toString().padLeft(2, "0")}';
      epBuf.write('${i + 1}. $label "${c.ep.title}": ${c.ep.overview}');
      if (c.ep.guestStars.isNotEmpty) {
        epBuf.write(' [Guests: ${c.ep.guestStars}]');
      }
      epBuf.writeln();
    }

    // A pre-computed plot summary (when available) is a far stronger signal
    // than raw subtitle text, so surface it to the model as the primary cue.
    final hasSummary = fp.summary.isNotEmpty;
    final userContent = hasSummary
        ? 'Plot summary (primary signal):\n${fp.summary}\n\n'
            'Subtitle excerpt (supporting evidence):\n$subtitleText\n\n'
            'Episodes:\n${epBuf}JSON:'
        : 'Subtitle:\n$subtitleText\n\nEpisodes:\n${epBuf}JSON:';

    final response = await llm.chat(
      timeout: const Duration(minutes: 5),
      maxTokens: 4000,
      temperature: 0.0,
      [
        {
          'role': 'system',
          'content':
              'You identify which TV episode a subtitle belongs to.\n'
              '${hasSummary ? 'Use the plot summary as the primary signal and '
                  'the subtitle excerpt as supporting evidence.\n' : 'Read the '
                  'subtitle excerpt and match it to the episode description.\n'}'
              'Output STRICT JSON only: {"pick":N} (1-based).\n'
              'Always pick the closest match. '
              'Use {"pick":0} only if completely unrecognisable.',
        },
        {
          'role': 'user',
          'content': userContent,
        },
      ],
    );

    if (response == null) {
      _log('   LLM episode match: no response.', isError: true);
      return null;
    }
    final obj = _parseJsonObject(response);
    if (obj == null) {
      _log('   LLM episode match: JSON parse failed. Raw: $response',
          isError: true);
      return null;
    }
    final n = (obj['pick'] is int)
        ? obj['pick'] as int
        : int.tryParse('${obj['pick']}') ?? 0;
    if (n < 1 || n > episodes.length) {
      _log('   LLM episode match: pick=$n — declined or out of range.');
      return null;
    }

    final chosen = episodes[n - 1];
    final label =
        's${chosen.season.toString().padLeft(2, "0")}'
        'e${chosen.ep.number.toString().padLeft(2, "0")}';
    _log('   LLM episode match: $label "${chosen.ep.title}"');
    return _EpisodePick(
      stem: label,
      title: chosen.ep.title,
      season: chosen.season,
      ep: chosen.ep.number,
    );
  }

  // ---------------------------------------------------------------------------
  // Manual episode picker (fallback when LLM declines)
  // ---------------------------------------------------------------------------

  Future<_EpisodePick?> _promptEpisodePick({
    required List<({int season, EpisodeInfo ep})> episodes,
  }) async {
    if (force) {
      _log('   AutoNamer[force]: LLM declined — skipping.', isError: true);
      return null;
    }

    _log('   LLM could not identify the episode. Pick manually:');
    for (var i = 0; i < episodes.length; i++) {
      final c = episodes[i];
      final label =
          's${c.season.toString().padLeft(2, "0")}'
          'e${c.ep.number.toString().padLeft(2, "0")}';
      _log('     ${i + 1}. $label "${c.ep.title}"');
    }
    _log('   Pick 1-${episodes.length} (Enter = skip): ');
    final input = ttyReadLine().trim();
    if (input.isEmpty) return null;
    final n = int.tryParse(input);
    if (n == null || n < 1 || n > episodes.length) return null;
    final chosen = episodes[n - 1];
    final label =
        's${chosen.season.toString().padLeft(2, "0")}'
        'e${chosen.ep.number.toString().padLeft(2, "0")}';
    return _EpisodePick(
      stem: label,
      title: chosen.ep.title,
      season: chosen.season,
      ep: chosen.ep.number,
    );
  }

  // ---------------------------------------------------------------------------
  // LLM fallback picker for title (single call, when deterministic score low)
  // ---------------------------------------------------------------------------

  Future<_ScoredCandidate?> _llmFallbackPick({
    required Fingerprint fp,
    required List<_ScoredCandidate> top5,
    required String kind,
  }) async {
    if (top5.isEmpty) return null;

    final buf = StringBuffer();
    for (var i = 0; i < top5.length; i++) {
      buf.writeln('${i + 1}. ${top5[i].label}');
    }

    final response = await llm.chat(
      timeout: const Duration(minutes: 3),
      maxTokens: 4000,
      temperature: 0.0,
      [
        {
          'role': 'system',
          'content':
              'Pick the best matching $kind based on the summary. '
              'Output STRICT JSON: {"pick":N} with N in 1..${top5.length}, '
              'or {"pick":0} if none clearly fit.',
        },
        {
          'role': 'user',
          'content': 'Summary: ${fp.summary}\n\nCandidates:\n${buf}JSON:',
        },
      ],
    );
    if (response == null) return null;
    final obj = _parseJsonObject(response);
    if (obj == null) return null;
    final pick = (obj['pick'] is int)
        ? obj['pick'] as int
        : int.tryParse('${obj['pick']}') ?? 0;
    if (pick < 1 || pick > top5.length) return null;
    return top5[pick - 1];
  }

  // ---------------------------------------------------------------------------
  // Title tie-break prompt
  // ---------------------------------------------------------------------------

  Future<_ScoredCandidate?> _promptTieBreak({
    required String kind,
    required List<_ScoredCandidate> options,
  }) async {
    if (options.isEmpty) return null;

    if (force) {
      final top = options.first;
      _log(
        '   AutoNamer[force]: tie on $kind — picked '
        '"${top.label}" (score ${top.score.toStringAsFixed(1)}).',
      );
      return top;
    }

    _log('');
    _log('   Multiple $kind candidates are close in score:');
    for (var i = 0; i < options.length; i++) {
      final o = options[i];
      _log('     ${i + 1}. [${o.score.toStringAsFixed(1)}] ${o.label}');
    }
    _log('   Pick 1-${options.length} (Enter = 1, 0 = skip): ');
    final input = ttyReadLine().trim();
    if (input.isEmpty) return options.first;
    final n = int.tryParse(input);
    if (n == 0) return null;
    if (n == null || n < 1 || n > options.length) {
      _log('   Invalid choice — skipping.', isError: true);
      return null;
    }
    return options[n - 1];
  }

  // ---------------------------------------------------------------------------
  // Duration probing
  // ---------------------------------------------------------------------------

  final Map<String, double?> _durationCache = {};

  /// Container duration in seconds via ffprobe, or null when unavailable.
  Future<double?> _probeDurationSecs(File mediaFile) async {
    final key = mediaFile.path;
    if (_durationCache.containsKey(key)) return _durationCache[key];
    double? secs;
    try {
      final result = await Process.run(extractor.ffprobe, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'csv=p=0',
        mediaFile.path,
      ]);
      if (result.exitCode == 0) {
        secs = double.tryParse((result.stdout as String).trim());
      }
    } catch (_) {}
    _durationCache[key] = secs;
    return secs;
  }

  /// Applies [refineWithDuration] to a pick. Returns null for a play-all
  /// title (which must not claim an episode name); otherwise the pick,
  /// upgraded to a range stem when the duration covers a multi-part group.
  _EpisodePick? _applyDurationRefinement({
    required _EpisodePick pick,
    required List<({int season, EpisodeInfo ep})> episodes,
    required double? durationSecs,
    required double? medianSecs,
    required String filePath,
  }) {
    final r = refineWithDuration(
      episodes: episodes,
      season: pick.season,
      epNumber: pick.ep,
      durationSecs: durationSecs,
      medianSecs: medianSecs,
    );
    if (r.playAll) {
      final mins = (durationSecs! / 60).toStringAsFixed(0);
      _log(
        '   AutoNamer: $filePath is $mins min — looks like a play-all/'
        'concatenated disc title, not episode ${pick.stem} — leaving unnamed.',
        isError: true,
      );
      return null;
    }
    if (r.epStart == pick.ep && r.epEnd == pick.ep) {
      // Kept as a single episode — warn when the duration clearly exceeds
      // the expected length (likely an extended or episode-plus-extras cut).
      final expected = _expectedSecsFor(pick, episodes, medianSecs);
      if (durationSecs != null &&
          expected != null &&
          durationSecs > expected * 1.5) {
        _log(
          '   ⚠ $filePath runs ${(durationSecs / 60).toStringAsFixed(1)} min '
          'but ${pick.stem} expects ~${(expected / 60).toStringAsFixed(0)} min '
          '— possible extended/bonus cut.',
          isError: true,
        );
      }
      return pick;
    }
    final stem = episodeStem(pick.season, r.epStart, r.epEnd);
    final first = episodes
        .where((e) => e.season == pick.season && e.ep.number == r.epStart)
        .toList();
    final title = first.isEmpty
        ? pick.title
        : baseEpisodeTitle(first.first.ep.title);
    _log(
      '   Duration ${((durationSecs ?? 0) / 60).toStringAsFixed(1)} min '
      'covers a multi-part episode → $stem "$title".',
    );
    return _EpisodePick(
      stem: stem,
      title: title,
      season: pick.season,
      ep: r.epStart,
      epEnd: r.epEnd,
    );
  }

  // ---------------------------------------------------------------------------
  // Entity-dense retry excerpt
  // ---------------------------------------------------------------------------

  /// Builds an excerpt of sentences dense in recurring proper nouns —
  /// character and place names are the strongest episode-identification
  /// signal when a plain excerpt failed.
  static String entityDenseExcerpt(String text, {int maxChars = 8000}) {
    final counts = <String, int>{};
    for (final m in RegExp(r'\b[A-Z][a-z]{2,}\b').allMatches(text)) {
      final w = m.group(0)!;
      counts[w] = (counts[w] ?? 0) + 1;
    }
    final recurring = counts.entries
        .where((e) => e.value >= 3)
        .map((e) => e.key)
        .toSet();
    if (recurring.isEmpty) return _episodeExcerpt(text);

    final buf = StringBuffer();
    for (final sentence in text.split(RegExp(r'(?<=[.!?])\s+'))) {
      if (buf.length >= maxChars) break;
      final hasEntity = RegExp(r'\b[A-Z][a-z]{2,}\b')
          .allMatches(sentence)
          .any((m) => recurring.contains(m.group(0)));
      if (hasEntity) buf.write('$sentence ');
    }
    final out = buf.toString().trim();
    return out.isEmpty ? _episodeExcerpt(text) : out;
  }

  // ---------------------------------------------------------------------------
  // Post-assignment verification
  // ---------------------------------------------------------------------------

  /// Second-opinion check: an independent re-match of the summary against
  /// the episode list, without the original pick in sight. The pick is
  /// rejected only when this blind re-match lands on a DIFFERENT episode —
  /// an inconclusive answer (pick 0) accepts, so sparse evidence (short
  /// whisper transcripts, thin TMDB overviews) never blocks a rename that
  /// the primary match and the re-match agree on.
  Future<bool> _verifyPick({
    required Fingerprint fp,
    required _EpisodePick pick,
    required List<({int season, EpisodeInfo ep})> episodes,
  }) async {
    if (fp.summary.isEmpty) return true;

    final epBuf = StringBuffer();
    for (var i = 0; i < episodes.length; i++) {
      final c = episodes[i];
      epBuf.writeln(
        '${i + 1}. ${episodeStem(c.season, c.ep.number)} '
        '"${c.ep.title}": ${c.ep.overview}',
      );
    }

    final response = await llm.chat(
      timeout: const Duration(minutes: 2),
      maxTokens: 2000,
      temperature: 0.0,
      [
        {
          'role': 'system',
          'content':
              'You identify which TV episode a plot summary describes.\n'
              'Output STRICT JSON: {"pick":N} (1-based index into the '
              'episode list), or {"pick":0} when unsure.',
        },
        {
          'role': 'user',
          'content': 'Summary:\n${fp.summary}\n\nEpisodes:\n$epBuf\nJSON:',
        },
      ],
    );
    if (response == null) return true;
    final obj = _parseJsonObject(response);
    if (obj == null) return true;
    final n = obj['pick'] is int
        ? obj['pick'] as int
        : int.tryParse('${obj['pick']}') ?? 0;
    if (n < 1 || n > episodes.length) return true; // inconclusive → accept

    final re = episodes[n - 1];
    final samePick = re.season == pick.season &&
        re.ep.number >= pick.ep &&
        re.ep.number <= pick.epEnd;
    // Same part group also counts: parts of one special are one story.
    final group = partGroup(episodes, pick.season, pick.ep);
    final sameGroup = group != null &&
        re.season == pick.season &&
        re.ep.number >= group.start &&
        re.ep.number <= group.end;
    if (samePick || sameGroup) return true;

    _log(
      '   ⚠ Verification: blind re-match says '
      '${episodeStem(re.season, re.ep.number)} "${re.ep.title}", '
      'not ${pick.stem} "${pick.title}" — leaving unnamed.',
      isError: true,
    );
    return false;
  }

  // ---------------------------------------------------------------------------
  // Duplicate-stem conflict resolution
  // ---------------------------------------------------------------------------

  /// Two files claimed the same episode; at most one is right. One LLM call
  /// compares both summaries against the episode list and reassigns each.
  /// Returns 1-based episode indices (0 = could not place) for the earlier
  /// claimant and the new claimant, or null when the LLM gave no usable answer.
  Future<({int first, int second})?> _resolveStemConflict({
    required Fingerprint firstFp,
    required Fingerprint secondFp,
    required _EpisodePick contested,
    required List<({int season, EpisodeInfo ep})> episodes,
  }) async {
    if (firstFp.summary.isEmpty || secondFp.summary.isEmpty) return null;

    final epBuf = StringBuffer();
    for (var i = 0; i < episodes.length; i++) {
      final c = episodes[i];
      epBuf.writeln(
        '${i + 1}. ${episodeStem(c.season, c.ep.number)} '
        '"${c.ep.title}": ${c.ep.overview}',
      );
    }

    final response = await llm.chat(
      timeout: const Duration(minutes: 3),
      maxTokens: 4000,
      temperature: 0.0,
      [
        {
          'role': 'system',
          'content':
              'Two subtitle summaries were both matched to episode '
              '"${contested.title}" (${contested.stem}), but each summary '
              'belongs to a DIFFERENT episode — at most one of them is that '
              'episode. Assign each summary to the episode it really '
              'describes, choosing from the numbered list.\n'
              'Output STRICT JSON: {"first":N,"second":M} (1-based indices '
              'into the episode list, 0 = cannot place). first and second '
              'must differ unless both are 0.',
        },
        {
          'role': 'user',
          'content':
              'Summary FIRST:\n${firstFp.summary}\n\n'
              'Summary SECOND:\n${secondFp.summary}\n\n'
              'Episodes:\n$epBuf\nJSON:',
        },
      ],
    );
    if (response == null) return null;
    final obj = _parseJsonObject(response);
    if (obj == null) return null;
    int parse(dynamic v) =>
        v is int ? v : int.tryParse('$v') ?? 0;
    final first = parse(obj['first']);
    final second = parse(obj['second']);
    if (first < 0 || first > episodes.length) return null;
    if (second < 0 || second > episodes.length) return null;
    if (first == second && first != 0) return null;
    return (first: first, second: second);
  }

  _EpisodePick _pickFromEpisodeIndex(
    List<({int season, EpisodeInfo ep})> episodes,
    int oneBased,
  ) {
    final c = episodes[oneBased - 1];
    return _EpisodePick(
      stem: episodeStem(c.season, c.ep.number),
      title: c.ep.title,
      season: c.season,
      ep: c.ep.number,
    );
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  /// Strips a "Previously on …" recap section from raw SRT text.
  ///
  /// Activates only when the first subtitle block contains "previously on".
  /// Finds the first timestamp that follows a gap of more than [gapSeconds]
  /// seconds and returns the SRT from that point.
  String _stripRecap(String rawSrt, {int gapSeconds = 60}) {
    final firstBlock = RegExp(
      r'^\d+\r?\n[^\r\n]+\r?\n([^\r\n]+)',
      multiLine: true,
    ).firstMatch(rawSrt);
    if (firstBlock == null) return rawSrt;
    if (!firstBlock.group(1)!.toLowerCase().contains('previously on')) {
      return rawSrt;
    }

    final tsPattern = RegExp(r'(\d+):(\d+):(\d+),\d+ -->');
    int? prevSecs;
    for (final m in tsPattern.allMatches(rawSrt)) {
      final secs = int.parse(m.group(1)!) * 3600 +
          int.parse(m.group(2)!) * 60 +
          int.parse(m.group(3)!);
      if (prevSecs != null && secs - prevSecs > gapSeconds) {
        final before = rawSrt.substring(0, m.start);
        final blankIdx = before.lastIndexOf('\n\n');
        final cutPos = blankIdx >= 0 ? blankIdx + 2 : 0;
        if (cutPos > 0) {
          _log('   Subtitle: stripped "Previously on" recap ($cutPos chars).');
          return rawSrt.substring(cutPos);
        }
      }
      prevSecs = secs;
    }
    return rawSrt;
  }

  static ({String mode, Map<String, dynamic> obj})? _parseJsonWithMode(
    String raw,
  ) {
    final cleaned = raw.replaceAll(RegExp(r'```[a-zA-Z]*'), '').trim();
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final slice = cleaned.substring(start, end + 1);

    Map<String, dynamic>? tryParse(String s) {
      try {
        final obj = jsonDecode(s);
        return obj is Map<String, dynamic> ? obj : null;
      } catch (_) {
        return null;
      }
    }

    final strict = tryParse(slice);
    if (strict != null) return (mode: 'strict', obj: strict);
    final repaired = tryParse(_repairJson(slice));
    if (repaired != null) return (mode: 'recovered', obj: repaired);
    return null;
  }

  static Map<String, dynamic>? _parseJsonObject(String raw) =>
      _parseJsonWithMode(raw)?.obj;

  static String _repairJson(String raw) {
    var out = raw
        .replaceAll("\\'", "'")   // invalid JSON escape: \' → '
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z_])None(?![A-Za-z_])'),
          (_) => 'null',
        )
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z_])True(?![A-Za-z_])'),
          (_) => 'true',
        )
        .replaceAllMapped(
          RegExp(r'(?<![A-Za-z_])False(?![A-Za-z_])'),
          (_) => 'false',
        );
    out = out.replaceAllMapped(
      RegExp(r'([{,]\s*)"(\w+):\s*(null|true|false|-?\d|\[|\{|")'),
      (m) => '${m.group(1)}"${m.group(2)}": ${m.group(3)}',
    );
    out = out.replaceAll(RegExp(r',(\s*[}\]])'), r'$1');
    return out;
  }

  static String _stripSrtFormatting(String srt) {
    final buf = StringBuffer();
    for (final line in srt.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (RegExp(r'^\d+$').hasMatch(t)) continue;
      if (t.contains('-->')) continue;
      buf.write('$t ');
    }
    return buf.toString().trimRight();
  }

  static String _langFromSrtFile(File srt) {
    final name = srt.uri.pathSegments.last;
    final match = RegExp(r'\.([a-z]{2,3})\.srt$').firstMatch(name);
    if (match == null) return 'en';
    final code = match.group(1)!;
    const iso2 = {
      'eng': 'en',
      'nld': 'nl',
      'dut': 'nl',
      'fra': 'fr',
      'fre': 'fr',
      'deu': 'de',
      'ger': 'de',
      'spa': 'es',
      'ita': 'it',
      'por': 'pt',
      'rus': 'ru',
      'jpn': 'ja',
      'zho': 'zh',
      'chi': 'zh',
      'kor': 'ko',
    };
    return iso2[code] ?? code;
  }

  static double _similarity(String a, String b) {
    final sa = a.split(RegExp(r'\s+')).where((w) => w.length >= 3).toSet();
    final sb = b.split(RegExp(r'\s+')).where((w) => w.length >= 3).toSet();
    if (sa.isEmpty || sb.isEmpty) return 0.0;
    final inter = sa.intersection(sb).length;
    final union = sa.union(sb).length;
    return inter / union;
  }

  static final _genericDiscNames = RegExp(
    r'^(dvd[_\s-]?video|video[_\s-]?dvd|blu[_\s-]?ray|bdmv|disc\d*|disk\d*|'
    r'untitled|new[_\s]volume|video[_\s]ts|volume\d*)$',
    caseSensitive: false,
  );
}

class _TitleCandidate {
  final int id;
  final String title;
  final int? year;
  final String overview;
  final String type;

  _TitleCandidate({
    required this.id,
    required this.title,
    required this.year,
    required this.overview,
    required this.type,
  });

  factory _TitleCandidate.movie(MovieCandidate m) => _TitleCandidate(
    id: m.id,
    title: m.title,
    year: m.year,
    overview: m.overview,
    type: 'movie',
  );

  factory _TitleCandidate.tv(TvCandidate t) => _TitleCandidate(
    id: t.id,
    title: t.name,
    year: t.firstAirYear,
    overview: t.overview,
    type: 'series',
  );
}

class _TitlePick {
  final String type;
  final int id;
  final String label;
  final int? year;

  _TitlePick({
    required this.type,
    required this.id,
    required this.label,
    this.year,
  });
}

class _EpisodePick {
  final String stem;
  final String title;
  final int season;
  final int ep;
  /// Last episode covered by this file; equals [ep] for single episodes.
  final int epEnd;

  _EpisodePick({
    required this.stem,
    required this.title,
    required this.season,
    required this.ep,
    int? epEnd,
  }) : epEnd = epEnd ?? ep;
}

class _ScoredCandidate {
  final int id;
  final String type;
  final String label;
  final double score;
  final String reason;

  _ScoredCandidate({
    required this.id,
    required this.type,
    required this.label,
    required this.score,
    required this.reason,
  });
}
