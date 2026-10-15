import '../utils/prompter.dart';
import '../utils/sanitize.dart';
import 'llm_client.dart';
import 'llm_json.dart';
import 'naming_prompts.dart';
import 'naming_types.dart';
import 'subtitle_text.dart';
import 'tmdb_client.dart';

/// Step 4 of auto-naming: decide which TMDB movie or series a fingerprint
/// belongs to. Deterministic title-guess scoring first, an LLM pick when
/// the score is weak, and a user tie-break when several are close.
class TitleResolver {
  TitleResolver({
    required this.tmdb,
    required this.llm,
    required this.prompter,
    required this.log,
  });

  static const double minTitleScore = 4.0;
  static const double tieMargin = 2.0;

  final TmdbClient tmdb;
  final LlmClient llm;
  final Prompter prompter;
  final NamingLog log;

  static final genericDiscNames = RegExp(
    r'^(dvd[_\s-]?video|video[_\s-]?dvd|blu[_\s-]?ray|bdmv|disc\d*|disk\d*|'
    r'untitled|new[_\s]volume|video[_\s]ts|volume\d*)$',
    caseSensitive: false,
  );

  Future<TitlePick?> resolve({
    required String discName,
    required Fingerprint fp,
    String? titleHint,
    List<int>? seasonHint,
  }) async {
    final query = (titleHint != null && titleHint.isNotEmpty)
        ? titleHint
        : pickSearchQuery(fp, discName);
    if (query.isEmpty) {
      log('   AutoNamer[step 4]: no search query — skipping.', isError: true);
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
      log(
        '   AutoNamer[step 4]: no TMDB candidates for "$query" — skipping.',
        isError: true,
      );
      return null;
    }

    // Title-hint shortcut.
    if (titleHint != null && titleHint.isNotEmpty) {
      if (typeWanted == 'series' && series.isNotEmpty) {
        final s = series.first;
        log('   Title pick: "${s.name}" (TMDB top-1 for hint)');
        return TitlePick(
          type: 'series',
          id: s.id,
          label: s.name,
          year: s.firstAirYear,
        );
      }
      if (typeWanted == 'movie' && movies.isNotEmpty) {
        final m = movies.first;
        log('   Title pick: "${m.title}" (TMDB top-1 for hint)');
        return TitlePick(
          type: 'movie',
          id: m.id,
          label: m.title,
          year: m.year,
        );
      }
    }

    // Deterministic scoring based on titleGuess similarity.
    final scored = <ScoredCandidate>[];
    for (final m in movies) {
      scored.add(ScoredCandidate(
        id: m.id,
        type: 'movie',
        label: m.year != null ? '${m.title} (${m.year})' : m.title,
        score: scoreTitleCandidate(fp, TitleCandidate.movie(m)),
        reason: '',
      ));
    }
    for (final t in series) {
      scored.add(ScoredCandidate(
        id: t.id,
        type: 'series',
        label: t.firstAirYear != null
            ? '${t.name} (${t.firstAirYear})'
            : t.name,
        score: scoreTitleCandidate(fp, TitleCandidate.tv(t)),
        reason: '',
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final top = scored.first;
    log(
      '   Title scores: '
      '${scored.take(5).map((c) => "${c.label}=${c.score.toStringAsFixed(1)}").join(", ")}',
    );

    if (top.score < minTitleScore) {
      log(
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
        log('   AutoNamer: LLM fallback declined — skipping.', isError: true);
        return null;
      }
      return _titlePickFromScored(picked, movies, series);
    }

    final close = scored
        .where((c) => c != top && (top.score - c.score) < tieMargin)
        .toList();
    if (close.isEmpty) {
      log(
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
    log(
      '   Title pick: "${chosen.label}" '
      '(score ${chosen.score.toStringAsFixed(1)})',
    );
    return _titlePickFromScored(chosen, movies, series);
  }

  TitlePick _titlePickFromScored(
    ScoredCandidate c,
    List<MovieCandidate> movies,
    List<TvCandidate> series,
  ) {
    if (c.type == 'movie') {
      final m = movies.firstWhere((m) => m.id == c.id);
      return TitlePick(type: 'movie', id: m.id, label: m.title, year: m.year);
    }
    final s = series.firstWhere((s) => s.id == c.id);
    return TitlePick(
      type: 'series',
      id: s.id,
      label: s.name,
      year: s.firstAirYear,
    );
  }

  /// The LLM's title guess, else the disc label unless it is generic.
  static String pickSearchQuery(Fingerprint fp, String discName) {
    if (fp.titleGuess.isNotEmpty) return fp.titleGuess;
    if (!genericDiscNames.hasMatch(discName.trim())) return discName;
    return '';
  }

  /// 10 for an exact title match, 5 for containment, else scaled Jaccard.
  static double scoreTitleCandidate(Fingerprint fp, TitleCandidate c) {
    if (fp.titleGuess.isEmpty) return 0.0;
    final tgLower = fp.titleGuess.toLowerCase();
    final titleLower = c.title.toLowerCase();
    if (tgLower == titleLower) return 10.0;
    if (tgLower.contains(titleLower) || titleLower.contains(tgLower)) {
      return 5.0;
    }
    return wordSetSimilarity(tgLower, titleLower) * 4.0;
  }

  /// `"Title (Year)"` file stem for a movie pick.
  String movieStem(TitlePick pick) {
    final stem = pick.year != null && pick.year != 0
        ? '${pick.label} (${pick.year})'
        : pick.label;
    log('   Identified as movie: $stem');
    return sanitizeFilename(stem);
  }

  // ---------------------------------------------------------------------------
  // LLM fallback picker (single call, when deterministic score low)
  // ---------------------------------------------------------------------------

  Future<ScoredCandidate?> _llmFallbackPick({
    required Fingerprint fp,
    required List<ScoredCandidate> top5,
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
          'content': titleFallbackSystemPrompt(kind, top5.length),
        },
        {
          'role': 'user',
          'content': 'Summary: ${fp.summary}\n\nCandidates:\n${buf}JSON:',
        },
      ],
    );
    if (response == null) return null;
    final obj = parseJsonObject(response);
    if (obj == null) return null;
    final pick = jsonInt(obj['pick']);
    if (pick < 1 || pick > top5.length) return null;
    return top5[pick - 1];
  }

  // ---------------------------------------------------------------------------
  // Tie-break prompt
  // ---------------------------------------------------------------------------

  Future<ScoredCandidate?> _promptTieBreak({
    required String kind,
    required List<ScoredCandidate> options,
  }) async {
    if (options.isEmpty) return null;

    final idx = await prompter.choose(
      '   Multiple $kind candidates are close in score:',
      [for (final o in options) '[${o.score.toStringAsFixed(1)}] ${o.label}'],
      defaultIndex: 0,
    );
    if (idx == null) {
      log('   AutoNamer: tie on $kind — skipped.', isError: true);
      return null;
    }
    final pick = options[idx];
    log(
      '   AutoNamer: tie on $kind — picked '
      '"${pick.label}" (score ${pick.score.toStringAsFixed(1)}).',
    );
    return pick;
  }
}
