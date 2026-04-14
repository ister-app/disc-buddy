import 'dart:convert';
import 'dart:io';
import '../subtitles/subtitle_extractor.dart';
import '../utils/sanitize.dart';
import 'llm_client.dart';
import 'tmdb_client.dart';

class AutoNamer {
  final SubtitleExtractor extractor;
  final TmdbClient tmdb;
  final LlmClient llm;

  const AutoNamer({
    required this.extractor,
    required this.tmdb,
    required this.llm,
  });

  /// Returns a new filename stem (without `.mkv`) for [mkvFile], or null if
  /// identification failed (caller should fall back to the default name).
  ///
  /// If [existingSrts] are provided (SRT files already sitting next to the
  /// MKV from a prior extraction step), the first one is read and passed to
  /// the LLM instead of extracting a new temp subtitle.
  ///
  /// [titleHint] and [seasonHint] short-circuit LLM identification when the
  /// user already knows the title and/or season.
  Future<String?> nameFile(
    File mkvFile,
    String discName, {
    List<File> existingSrts = const [],
    String? titleHint,
    int? seasonHint,
  }) async {
    // 1. Get subtitle text and language.
    String? subText;
    String  subLang = 'en'; // ISO 639-1, default English

    if (existingSrts.isNotEmpty) {
      try {
        final raw = await existingSrts.first.readAsString();
        subText  = _subtitleExcerpt(raw);
        subLang  = _langFromSrtFile(existingSrts.first);
      } catch (_) {}
    }
    if (subText == null) {
      stdout.writeln('   Extracting subtitle for identification...');
      final result = await extractor.extractFirstSubtitleText(
          mkvFile, maxChars: 50000);
      if (result != null) {
        subText = _subtitleExcerpt(result.text);
        subLang = result.language;
      }
    }
    if (subText == null || subText.trim().isEmpty) {
      stderr.writeln('   No subtitle text available, cannot auto-name.');
      return null;
    }
    stdout.writeln('   Subtitle language: $subLang');

    // 2. Route based on available hints.
    if (titleHint != null && seasonHint != null) {
      // Both known → skip identification entirely.
      stdout.writeln('   Using hint: series "$titleHint" season $seasonHint');
      return _nameSeries(titleHint, subText, onlySeason: seasonHint, language: subLang);
    }

    if (titleHint != null) {
      // Title known, type unknown → ask LLM only for type.
      final id = await _identifyContent(discName, subText, titleHint: titleHint);
      if (id == null) return null;
      final (type: contentType, query: searchQuery, year: year) = id;
      if (contentType == 'movie') return _nameMovie(searchQuery, year);
      return _nameSeries(searchQuery, subText, language: subLang);
    }

    if (seasonHint != null) {
      // Season known, title unknown → let LLM identify series name.
      final id = await _identifyContent(discName, subText);
      if (id == null) return null;
      if (id.type != 'series') {
        stderr.writeln('   LLM identified content as movie but season hint was given — skipping.');
        return null;
      }
      return _nameSeries(id.query, subText, onlySeason: seasonHint, language: subLang);
    }

    // 3. No hints → full auto (current behaviour).
    final id = await _identifyContent(discName, subText);
    if (id == null) return null;
    final (type: contentType, query: searchQuery, year: year) = id;
    if (contentType == 'movie') return _nameMovie(searchQuery, year);
    return _nameSeries(searchQuery, subText, language: subLang);
  }

  void close() {
    tmdb.close();
    llm.close();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Strips SRT sequence numbers, timestamps, and blank separator lines,
  /// leaving only the dialogue as a single block of text.
  static String _stripSrtFormatting(String srt) {
    final buf = StringBuffer();
    for (final line in srt.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (RegExp(r'^\d+$').hasMatch(t)) continue;   // sequence numbers
      if (t.contains('-->')) continue;               // timestamp lines
      buf.write('$t ');
    }
    return buf.toString().trimRight();
  }

  /// Strips SRT formatting and returns the full dialogue text.
  static String _subtitleExcerpt(String raw) => _stripSrtFormatting(raw);

  /// Extracts the ISO 639-1 language code from an SRT filename.
  /// E.g. `movie.nl.srt` → `"nl"`, `s01e01.en.srt` → `"en"`.
  /// Falls back to `"en"` if the pattern is not found.
  static String _langFromSrtFile(File srt) {
    final name = srt.uri.pathSegments.last; // basename
    final match = RegExp(r'\.([a-z]{2,3})\.srt$').firstMatch(name);
    if (match == null) return 'en';
    final code = match.group(1)!;
    // Map 3-letter codes to 2-letter if needed (same map as SubtitleExtractor).
    const iso2 = {
      'eng': 'en', 'nld': 'nl', 'dut': 'nl', 'fra': 'fr', 'fre': 'fr',
      'deu': 'de', 'ger': 'de', 'spa': 'es', 'ita': 'it', 'por': 'pt',
      'rus': 'ru', 'jpn': 'ja', 'zho': 'zh', 'chi': 'zh', 'kor': 'ko',
    };
    return iso2[code] ?? code;
  }

  /// Common generic disc volume labels that carry no title information.
  static final _genericDiscNames = RegExp(
    r'^(dvd[_\s-]?video|video[_\s-]?dvd|blu[_\s-]?ray|bdmv|disc\d*|disk\d*|'
    r'untitled|new[_\s]volume|video[_\s]ts|volume\d*)$',
    caseSensitive: false,
  );

  Future<({String type, String query, int? year})?> _identifyContent(
    String discName,
    String subText, {
    String? titleHint,
  }) async {
    final isGenericDisc = _genericDiscNames.hasMatch(discName.trim());

    final discContext = isGenericDisc
        ? '(The disc name "$discName" is a generic label — ignore it and rely on the subtitle text.)'
        : 'Disc name: "$discName"';

    final hintLine = titleHint != null
        ? 'The user identified this content as: "$titleHint" — use this as the search query '
          'and only determine if it is a movie or a TV series.\n\n'
        : '';

    final response = await llm.chat([
      {
        'role': 'system',
        'content':
            'You identify movies and TV shows from optical disc names and subtitle text, '
            'and produce TMDB search queries. Follow these rules:\n'
            '1. If the user has provided a title hint, it is the strongest signal and must '
            'be used as the query — only determine the type (movie or series).\n'
            '2. If the disc name is meaningful, it is a strong signal.\n'
            '3. If the disc name is generic (DVD_VIDEO, DISC1, etc.), rely entirely on '
            'the subtitle text to identify the content.\n'
            '4. Classify as "series" when the subtitle shows episodic structure: '
            'recurring characters across short scenes, sitcom/drama dialogue, '
            'or references to a known TV show.\n'
            '5. Classify as "movie" only when the content is clearly a single standalone film.\n'
            '6. Use the clean show/movie title as the query — strip technical junk '
            '(S01, DISC1, BLURAY, 1080P, etc.).\n'
            '7. Respond with valid JSON only — no markdown, no explanation.',
      },
      {
        'role': 'user',
        'content': '$hintLine$discContext\n\n'
            'Subtitle excerpt:\n$subText\n\n'
            'Is this a movie or a TV series? Provide a TMDB search query as JSON:\n'
            '{"type":"movie","query":"Search Title","year":1994}\n'
            '{"type":"series","query":"Search Series Title"}',
      },
    ]);
    if (response == null) {
      stderr.writeln('   LLM did not return a response (timeout or error).');
      return null;
    }

    try {
      final clean =
          response.replaceAll(RegExp(r'```[a-z]*\n?'), '').trim();
      final json = jsonDecode(clean) as Map<String, dynamic>;
      final type = json['type'] as String? ?? 'movie';
      var query = (json['query'] as String? ?? '').trim();
      // If the LLM returned an empty query but the user provided a title hint,
      // fall back to the hint.
      if (query.isEmpty && titleHint != null) query = titleHint;
      if (query.isEmpty) {
        stderr.writeln('   LLM returned empty query.');
        return null;
      }
      final year = json['year'] as int?;
      stdout.writeln('   LLM identified as $type: "$query"'
          '${year != null ? " ($year)" : ""}');
      return (type: type, query: query, year: year);
    } catch (_) {
      stderr.writeln('   LLM response could not be parsed as JSON: $response');
      return null;
    }
  }

  Future<String?> _nameMovie(String query, int? year) async {
    final result = await tmdb.searchMovie(query, year: year);
    if (result == null) {
      stderr.writeln('   TMDB: no movie found for "$query".');
      // Fall back to the LLM query as filename stem.
      final stem = year != null ? '$query ($year)' : query;
      stdout.writeln('   Using LLM query as fallback: $stem');
      return sanitizeFilename(stem);
    }
    final stem = '${result.$1} (${result.$2})';
    stdout.writeln('   Identified as movie: $stem');
    return sanitizeFilename(stem);
  }

  Future<String?> _nameSeries(String query, String subText,
      {int? onlySeason, String language = 'en'}) async {
    final series = await tmdb.searchTv(query);
    if (series == null) {
      stderr.writeln('   TMDB: no TV series found for "$query".');
      return null;
    }

    // --- Single-season shortcut ---
    if (onlySeason != null) {
      stdout.writeln('   Checking season $onlySeason of "${series.$2}"...');
      final episodes = await tmdb.getSeasonEpisodes(series.$1, onlySeason, language: language);
      if (episodes.isEmpty) {
        stderr.writeln('   TMDB: no episodes found for season $onlySeason of "${series.$2}".');
        return null;
      }
      final epNum = await _bestEpisodeInSeason(subText, episodes, series.$2, onlySeason);
      if (epNum == null) {
        stderr.writeln('   Could not match an episode in season $onlySeason.');
        return null;
      }
      final sp = onlySeason.toString().padLeft(2, '0');
      final ep = epNum.toString().padLeft(2, '0');
      stdout.writeln('   Identified as series: ${series.$2} s${sp}e$ep');
      return 's${sp}e$ep';
    }

    // --- Tournament: all seasons ---
    final numSeasons = await tmdb.getNumberOfSeasons(series.$1);
    if (numSeasons == null || numSeasons == 0) {
      stderr.writeln('   TMDB: could not determine season count for "${series.$2}".');
      return null;
    }

    stdout.writeln('   Matching "${series.$2}" across $numSeasons seasons...');

    // Round 1: per season, ask the LLM which episode fits best.
    final candidates =
        <({int season, int ep, String title, String overview, String guestStars, String airDate})>[];
    for (var s = 1; s <= numSeasons; s++) {
      final episodes = await tmdb.getSeasonEpisodes(series.$1, s, language: language);
      if (episodes.isEmpty) continue;
      final epNum = await _bestEpisodeInSeason(subText, episodes, series.$2, s);
      if (epNum == null) continue;
      final match = episodes.firstWhere(
        (e) => e.number == epNum,
        orElse: () => episodes.first,
      );
      candidates.add((
        season:     s,
        ep:         match.number,
        title:      match.title,
        overview:   match.overview,
        guestStars: match.guestStars,
        airDate:    match.airDate,
      ));
      final pad  = s.toString().padLeft(2, '0');
      final epad = match.number.toString().padLeft(2, '0');
      stdout.writeln('   s${pad}e$epad best match: "${match.title}"');
    }

    if (candidates.isEmpty) {
      stderr.writeln('   LLM could not match any episode.');
      return null;
    }

    // Round 2: from the per-season winners, pick the overall best.
    final best = candidates.length == 1
        ? candidates.first
        : await _selectBestCandidate(subText, candidates, series.$2);
    if (best == null) {
      stderr.writeln('   LLM could not select the best candidate.');
      return null;
    }

    final s = best.season.toString().padLeft(2, '0');
    final e = best.ep.toString().padLeft(2, '0');
    stdout.writeln('   Identified as series: ${series.$2} s${s}e$e');
    return 's${s}e$e';
  }

  /// Round 1: returns the episode number that best matches [subText] within
  /// a single season's episode list.
  Future<int?> _bestEpisodeInSeason(
    String subText,
    List<EpisodeInfo> episodes,
    String seriesTitle,
    int season,
  ) async {
    final epList = episodes.map((ep) {
      final n        = ep.number.toString().padLeft(2, '0');
      final date     = ep.airDate.isNotEmpty   ? ' (${ep.airDate})' : '';
      final overview = ep.overview.isNotEmpty  ? ' — ${ep.overview}' : '';
      final guests   = ep.guestStars.isNotEmpty ? ' [Guest characters: ${ep.guestStars}]' : '';
      return 'e$n. "${ep.title}"$date$overview$guests';
    }).join('\n');

    final response = await llm.chat(
      [
        {
          'role': 'system',
          'content':
              'You match subtitle dialogue to a specific TV episode.\n'
              'Identify the key characters, locations, and plot events in the subtitle, '
              'then pick the episode whose details best fit.\n'
              'Reply with ONLY the episode number (integer) if one clearly matches, '
              'or ONLY the word "none" if no episode fits.\n'
              'No explanation, no other text.',
        },
        {
          'role': 'user',
          'content': 'Show: "$seriesTitle" — season $season\n\n'
              'Subtitle:\n$subText\n\n'
              'Episodes:\n$epList\n\n'
              'Best matching episode number? (or "none" if no match)',
        },
      ],
      timeout: const Duration(seconds: 60),
    );
    if (response == null) return null;
    final answer = response.trim().toLowerCase();
    if (answer.contains('none')) return null;
    final n = RegExp(r'\d+').firstMatch(answer)?.group(0);
    return n != null ? int.tryParse(n) : null;
  }

  /// Round 2: from one winner per season, picks the overall best match.
  Future<({int season, int ep, String title, String overview, String guestStars, String airDate})?>
      _selectBestCandidate(
    String subText,
    List<({int season, int ep, String title, String overview, String guestStars, String airDate})>
        candidates,
    String seriesTitle,
  ) async {
    final list = candidates.map((c) {
      final s        = c.season.toString().padLeft(2, '0');
      final e        = c.ep.toString().padLeft(2, '0');
      final date     = c.airDate.isNotEmpty    ? ' (${c.airDate})' : '';
      final overview = c.overview.isNotEmpty   ? ' — ${c.overview}' : '';
      final guests   = c.guestStars.isNotEmpty ? ' [Guest characters: ${c.guestStars}]' : '';
      return 's${s}e$e. "${c.title}"$date$overview$guests';
    }).join('\n');

    final response = await llm.chat([
      {
        'role': 'system',
        'content':
            'You pick which episode best matches a subtitle from a short candidate list.\n'
            'Reply with two integers: season number then episode number. '
            'Example: 6 1\nNo other text.',
      },
      {
        'role': 'user',
        'content': 'Show: "$seriesTitle"\n\n'
            'Subtitle:\n$subText\n\n'
            'Candidates (one per season):\n$list\n\n'
            'Which candidate best matches the subtitle? Reply with: <season> <episode>',
      },
    ]);
    if (response == null) return null;
    final nums = RegExp(r'\d+')
        .allMatches(response)
        .map((m) => int.parse(m.group(0)!))
        .toList();
    if (nums.length < 2) return null;
    final season = nums[0];
    final ep     = nums[1];
    return candidates.firstWhere(
      (c) => c.season == season && c.ep == ep,
      orElse: () => candidates.first,
    );
  }
}
