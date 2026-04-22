import 'dart:convert';
import 'dart:io';

import '../cli/menu.dart';
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
  final TmdbClient tmdb;
  final LlmClient llm;
  final bool force;
  /// null = ask interactively; true = always use; false = never use.
  final bool? batchAssign;

  AutoNamer({
    required this.extractor,
    required this.tmdb,
    required this.llm,
    this.force = false,
    this.batchAssign,
  });

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
    stdout.writeln('   Naming: ${mkvFile.path}');
    return _resolveEpisode(
      seriesId: winner.id,
      seriesName: winner.label,
      fp: fp,
      subtitleText: sub.text,
      subLang: sub.language,
      seasonHint: seasonHint,
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
      stdout.writeln(
        '   [${i + 1}/${items.length}] Loading subtitle: '
        '${items[i].file.path}',
      );
      final s = await _loadSubtitle(items[i].file, items[i].srts);
      if (s != null) subs[i] = s;
    }
    if (subs.isEmpty) {
      stderr.writeln('   AutoNamer: no subtitles available for batch.');
      return {for (final it in items) it.file: null};
    }

    for (final entry in subs.entries) {
      stdout.writeln(
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
        stderr.writeln(
          '   AutoNamer: no seasons for "${winner.label}" — skipping.',
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
      stderr.writeln(
        '   AutoNamer: no episodes for "${winner.label}" — skipping.',
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
          );

    final results = <File, String?>{};
    for (var i = 0; i < items.length; i++) {
      final pick = picks[i];
      results[items[i].file] = pick?.stem;
      if (pick != null) {
        stdout.writeln(
          '   ${items[i].file.path} → ${pick.stem} "${pick.title}"',
        );
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

    stdout.writeln('   Extracting subtitle for identification...');
    final result = await extractor.extractFirstSubtitleText(
      mkvFile,
      maxChars: 500000,
    );
    if (result == null || result.text.trim().isEmpty) {
      stderr.writeln('   AutoNamer[step 1]: no subtitle track — skipping.');
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

    stdout.writeln('   Summarising subtitle (${excerpt.length} chars)...');
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
      stderr.writeln('   Summary: no response from LLM.');
      return Fingerprint.empty;
    }

    final parsed = _parseJsonWithMode(raw);
    if (parsed == null) {
      stderr.writeln(
        '   Summary: JSON parse failed. Raw: '
        '${raw.length > 120 ? "${raw.substring(0, 120)}..." : raw}',
      );
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
      stderr.writeln('   Fingerprint: (empty — LLM summary failed)');
      return;
    }
    stdout.writeln('   Fingerprint:');
    if (fp.summary.isNotEmpty) stdout.writeln('     summary:    ${fp.summary}');
    if (fp.titleGuess.isNotEmpty) {
      stdout.writeln('     titleGuess: ${fp.titleGuess}');
    }
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
      stderr.writeln('   AutoNamer[step 4]: no search query — skipping.');
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
      stderr.writeln(
        '   AutoNamer[step 4]: no TMDB candidates for "$query" — skipping.',
      );
      return null;
    }

    // Title-hint shortcut.
    if (titleHint != null && titleHint.isNotEmpty) {
      if (typeWanted == 'series' && series.isNotEmpty) {
        final s = series.first;
        stdout.writeln('   Title pick: "${s.name}" (TMDB top-1 for hint)');
        return _TitlePick(
          type: 'series',
          id: s.id,
          label: s.name,
          year: s.firstAirYear,
        );
      }
      if (typeWanted == 'movie' && movies.isNotEmpty) {
        final m = movies.first;
        stdout.writeln('   Title pick: "${m.title}" (TMDB top-1 for hint)');
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
    stdout.writeln(
      '   Title scores: '
      '${scored.take(5).map((c) => "${c.label}=${c.score.toStringAsFixed(1)}").join(", ")}',
    );

    if (top.score < _minTitleScore) {
      stderr.writeln(
        '   AutoNamer: deterministic title score only '
        '${top.score.toStringAsFixed(1)} — falling back to LLM pick.',
      );
      final picked = await _llmFallbackPick(
        fp: fp,
        top5: scored.take(5).toList(),
        kind: 'title',
      );
      if (picked == null) {
        stderr.writeln('   AutoNamer: LLM fallback declined — skipping.');
        return null;
      }
      return _titlePickFromScored(picked, movies, series);
    }

    final close = scored
        .where((c) => c != top && (top.score - c.score) < _tieMargin)
        .toList();
    if (close.isEmpty) {
      stdout.writeln(
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
    stdout.writeln(
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
    stdout.writeln('   Identified as movie: $stem');
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
  }) async {
    final pick = await _matchEpisode(
      seriesId: seriesId,
      seriesName: seriesName,
      fp: fp,
      subtitleText: subtitleText,
      subLang: subLang,
      seasonHint: seasonHint,
    );
    if (pick == null) return null;
    stdout.writeln(
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
    stdout.write(
      '   Use batch assignment? (sends all excerpts in one LLM call, '
      'works better with large models) [y/N] ',
    );
    final input = Menu.readLine().trim().toLowerCase();
    return input == 'y' || input == 'yes';
  }

  /// Per-file matching fallback: matches each subtitle independently.
  Future<Map<int, _EpisodePick?>> _matchEpisodesPerFile({
    required List<({int season, EpisodeInfo ep})> episodes,
    required List<({File file, String discName, List<File> srts})> items,
    required Map<int, ({String text, String language})> subs,
  }) async {
    final picks = <int, _EpisodePick?>{};
    final usedStems = <String, int>{};

    for (var i = 0; i < items.length; i++) {
      final sub = subs[i];
      final fp = Fingerprint.empty;
      if (sub == null) continue;
      stdout.writeln(
        '   [${i + 1}/${items.length}] Naming: ${items[i].file.path}',
      );
      final pick = await _llmEpisodeMatch(
        fp: fp,
        episodes: episodes,
        subtitleText: sub.text,
      );
      if (pick == null) {
        picks[i] = await _promptEpisodePick(episodes: episodes);
        continue;
      }
      final dup = usedStems[pick.stem];
      if (dup != null) {
        stderr.writeln(
          '   AutoNamer: ${items[i].file.path} duplicate stem '
          '${pick.stem}, kept ${items[dup].file.path} — skipping.',
        );
        picks[i] = null;
      } else {
        usedStems[pick.stem] = i;
        picks[i] = pick;
      }
    }
    return picks;
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
    final filteredEpisodes = _filterEpisodesBySimilarity(
      episodes,
      allSummaries,
    );
    stdout.writeln(
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
        stderr.writeln(
          '   Batch assignment: file ${i + 1} subtitle does not look English'
          ' and has no summary — flagged for LLM.',
        );
      } else if (!isEnglish) {
        stderr.writeln(
          '   Batch assignment: file ${i + 1} subtitle does not look English'
          ' — flagged for LLM.',
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
    stdout.writeln(
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
      stderr.writeln('   Batch assignment: no response from LLM.');
      return {};
    }

    final obj = _parseJsonObject(response);
    if (obj == null) {
      stderr.writeln(
        '   Batch assignment: JSON parse failed. Raw: '
        '${response.length > 200 ? "${response.substring(0, 200)}..." : response}',
      );
      return {};
    }

    if (obj.containsKey('reasoning')) {
      final reasoning = obj['reasoning'] as String? ?? '';
      if (reasoning.isNotEmpty) {
        stdout.writeln(
          '   LLM reasoning: '
          '${reasoning.length > 300 ? "${reasoning.substring(0, 300)}…" : reasoning}',
        );
      }
    }

    final rawAssignments = obj['assignments'];
    if (rawAssignments is! Map) {
      stderr.writeln('   Batch assignment: "assignments" missing or wrong type.');
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
        stdout.writeln(
          '   Batch assignment: file ${fileIdx + 1} → unassigned (ep=0).',
        );
        continue;
      }
      if (epIdx < 0 || epIdx >= filteredEpisodes.length) {
        stderr.writeln(
          '   Batch assignment: file ${fileIdx + 1} got ep=$rawEp '
          '(out of range) — dropping.',
        );
        continue;
      }
      if (confidence < 0.4) {
        stderr.writeln(
          '   Batch assignment: file ${fileIdx + 1} → ep $rawEp '
          'confidence=${confidence.toStringAsFixed(2)} < 0.4 — dropping.',
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
        stderr.writeln(
          '   Batch assignment: file ${displaced + 1} displaced by '
          'file ${fileIdx + 1} for ep ${epIdx + 1} '
          '(confidence ${conf.toStringAsFixed(2)} > '
          '${epToBest[epIdx]!.confidence.toStringAsFixed(2)}).',
        );
        epToBest[epIdx] = (fileIdx: fileIdx, confidence: conf);
      } else {
        stderr.writeln(
          '   Batch assignment: file ${fileIdx + 1} duplicate for ep ${epIdx + 1} '
          '— keeping file ${epToBest[epIdx]!.fileIdx + 1} '
          '(confidence ${epToBest[epIdx]!.confidence.toStringAsFixed(2)} >= '
          '${conf.toStringAsFixed(2)}).',
        );
      }
    }

    // Build final picks from resolved assignments.
    final picks = <int, _EpisodePick?>{};
    for (final entry in epToBest.entries) {
      final epIdx = entry.key;
      final fileIdx = entry.value.fileIdx;
      final c = filteredEpisodes[epIdx];
      final label =
          's${c.season.toString().padLeft(2, "0")}'
          'e${c.ep.number.toString().padLeft(2, "0")}';
      stdout.writeln(
        '   [${fileIdx + 1}/${items.length}] → $label "${c.ep.title}"',
      );
      picks[fileIdx] = _EpisodePick(
        stem: label,
        title: c.ep.title,
        season: c.season,
        ep: c.ep.number,
      );
    }

    return picks;
  }

  /// Filters [episodes] to the top [maxEpisodes] most similar to any of
  /// [summaries], using Jaccard word similarity on lowercased text.
  /// Returns the original list unchanged when there are no summaries or the
  /// list is already within the limit.
  static List<({int season, EpisodeInfo ep})> _filterEpisodesBySimilarity(
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
  }) async {
    // Determine seasons.
    final seasons = <int>[];
    if (seasonHint != null && seasonHint.isNotEmpty) {
      seasons.addAll(seasonHint);
    } else {
      final n = await tmdb.getNumberOfSeasons(seriesId);
      if (n == null || n == 0) {
        stderr.writeln(
          '   AutoNamer[step 5b]: no seasons for "$seriesName" — skipping.',
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
      stderr.writeln(
        '   AutoNamer[step 5b]: no episodes for "$seriesName" — skipping.',
      );
      return null;
    }

    // LLM matches subtitle excerpt to episode.
    final pick = await _llmEpisodeMatch(
      fp: fp,
      episodes: episodes,
      subtitleText: subtitleText,
    );
    if (pick != null) return pick;

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

    stdout.writeln(
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

    final response = await llm.chat(
      timeout: const Duration(minutes: 5),
      maxTokens: 4000,
      temperature: 0.0,
      [
        {
          'role': 'system',
          'content':
              'You identify which TV episode a subtitle belongs to.\n'
              'Read the subtitle excerpt and match it to the episode description.\n'
              'Output STRICT JSON only: {"pick":N} (1-based).\n'
              'Always pick the closest match. '
              'Use {"pick":0} only if completely unrecognisable.',
        },
        {
          'role': 'user',
          'content':
              'Subtitle:\n$subtitleText\n\nEpisodes:\n${epBuf}JSON:',
        },
      ],
    );

    if (response == null) {
      stderr.writeln('   LLM episode match: no response.');
      return null;
    }
    final obj = _parseJsonObject(response);
    if (obj == null) {
      stderr.writeln(
        '   LLM episode match: JSON parse failed. Raw: $response',
      );
      return null;
    }
    final n = (obj['pick'] is int)
        ? obj['pick'] as int
        : int.tryParse('${obj['pick']}') ?? 0;
    if (n < 1 || n > episodes.length) {
      stdout.writeln(
        '   LLM episode match: pick=$n — declined or out of range.',
      );
      return null;
    }

    final chosen = episodes[n - 1];
    final label =
        's${chosen.season.toString().padLeft(2, "0")}'
        'e${chosen.ep.number.toString().padLeft(2, "0")}';
    stdout.writeln('   LLM episode match: $label "${chosen.ep.title}"');
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
      stderr.writeln('   AutoNamer[force]: LLM declined — skipping.');
      return null;
    }

    stdout.writeln('   LLM could not identify the episode. Pick manually:');
    for (var i = 0; i < episodes.length; i++) {
      final c = episodes[i];
      final label =
          's${c.season.toString().padLeft(2, "0")}'
          'e${c.ep.number.toString().padLeft(2, "0")}';
      stdout.writeln('     ${i + 1}. $label "${c.ep.title}"');
    }
    stdout.write('   Pick 1-${episodes.length} (Enter = skip): ');
    final input = Menu.readLine().trim();
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
      stdout.writeln(
        '   AutoNamer[force]: tie on $kind — picked '
        '"${top.label}" (score ${top.score.toStringAsFixed(1)}).',
      );
      return top;
    }

    stdout.writeln('');
    stdout.writeln('   Multiple $kind candidates are close in score:');
    for (var i = 0; i < options.length; i++) {
      final o = options[i];
      stdout.writeln('     ${i + 1}. [${o.score.toStringAsFixed(1)}] ${o.label}');
    }
    stdout.write('   Pick 1-${options.length} (Enter = 1, 0 = skip): ');
    final input = Menu.readLine().trim();
    if (input.isEmpty) return options.first;
    final n = int.tryParse(input);
    if (n == 0) return null;
    if (n == null || n < 1 || n > options.length) {
      stderr.writeln('   Invalid choice — skipping.');
      return null;
    }
    return options[n - 1];
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  /// Strips a "Previously on …" recap section from raw SRT text.
  ///
  /// Activates only when the first subtitle block contains "previously on".
  /// Finds the first timestamp that follows a gap of more than [gapSeconds]
  /// seconds and returns the SRT from that point.
  static String _stripRecap(String rawSrt, {int gapSeconds = 60}) {
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
          stdout.writeln(
            '   Subtitle: stripped "Previously on" recap ($cutPos chars).',
          );
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

  _EpisodePick({
    required this.stem,
    required this.title,
    required this.season,
    required this.ep,
  });
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
