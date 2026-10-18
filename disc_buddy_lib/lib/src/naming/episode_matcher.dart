import 'dart:io';
import 'dart:math' as math;

import '../utils/prompter.dart';
import 'duration_probe.dart';
import 'episode_conflicts.dart';
import 'episode_math.dart';
import 'llm_client.dart';
import 'llm_json.dart';
import 'naming_prompts.dart';
import 'naming_types.dart';
import 'subtitle_text.dart';
import 'tmdb_client.dart';

/// Step 5b of auto-naming: match one or many subtitle fingerprints to TMDB
/// episodes with the LLM, refine by file duration, verify, and resolve
/// files that claim the same episode (see [EpisodeConflicts]).
class EpisodeMatcher {
  EpisodeMatcher({
    required this.tmdb,
    required this.llm,
    required this.prompter,
    required this.probe,
    required this.log,
  });

  final TmdbClient tmdb;
  final LlmClient llm;
  final Prompter prompter;
  final DurationProbe probe;
  final NamingLog log;

  // ---------------------------------------------------------------------------
  // TMDB episode lists
  // ---------------------------------------------------------------------------

  /// Episodes of [seasons] (or every season 1..n when null/empty) for
  /// [seriesId], in season order. Returns null, after logging, when the
  /// series has no seasons or the seasons have no episodes.
  Future<List<SeasonEpisode>?> fetchEpisodes({
    required int seriesId,
    required String seriesName,
    required String subLang,
    List<int>? seasonHint,
    String logTag = 'AutoNamer',
  }) async {
    final seasons = <int>[];
    if (seasonHint != null && seasonHint.isNotEmpty) {
      seasons.addAll(seasonHint);
    } else {
      final n = await tmdb.getNumberOfSeasons(seriesId);
      if (n == null || n == 0) {
        log(
          '   $logTag: no seasons for "$seriesName" — skipping.',
          isError: true,
        );
        return null;
      }
      for (var s = 1; s <= n; s++) {
        seasons.add(s);
      }
    }

    final episodes = <SeasonEpisode>[];
    for (final s in seasons) {
      final eps = await tmdb.getSeasonEpisodes(seriesId, s, language: subLang);
      for (final ep in eps) {
        episodes.add((season: s, ep: ep));
      }
    }
    if (episodes.isEmpty) {
      log(
        '   $logTag: no episodes for "$seriesName" — skipping.',
        isError: true,
      );
      return null;
    }
    return episodes;
  }

  /// TMDB season 0 (specials): DVD bonus content usually lives there.
  Future<List<SeasonEpisode>> fetchSpecials(
    int seriesId,
    String subLang,
  ) async => (await tmdb.getSeasonEpisodes(
    seriesId,
    0,
    language: subLang,
  )).map((ep) => (season: 0, ep: ep)).toList();

  // ---------------------------------------------------------------------------
  // Single file
  // ---------------------------------------------------------------------------

  /// Fetches all episodes from TMDB and asks the LLM to match the subtitle
  /// to the correct episode. Falls back to a manual prompt if the LLM
  /// cannot identify the episode.
  Future<EpisodePick?> matchEpisode({
    required int seriesId,
    required String seriesName,
    required Fingerprint fp,
    required String subtitleText,
    required String subLang,
    List<int>? seasonHint,
    File? mediaFile,
  }) async {
    final episodes = await fetchEpisodes(
      seriesId: seriesId,
      seriesName: seriesName,
      subLang: subLang,
      seasonHint: seasonHint,
      logTag: 'AutoNamer[step 5b]',
    );
    if (episodes == null) return null;

    // LLM matches subtitle excerpt to episode.
    var pick = await llmEpisodeMatch(
      fp: fp,
      episodes: episodes,
      subtitleText: subtitleText,
    );
    if (pick == null) {
      // Retry once with a proper-noun-dense excerpt before giving up.
      log('   Episode match failed — retrying with name-dense excerpt.');
      pick = await llmEpisodeMatch(
        fp: fp,
        episodes: episodes,
        subtitleText: entityDenseExcerpt(subtitleText),
      );
    }
    if (pick != null) {
      if (mediaFile != null) {
        final refined = applyDurationRefinement(
          pick: pick,
          episodes: episodes,
          durationSecs: await probe.secondsOf(mediaFile),
          medianSecs: null,
          filePath: mediaFile.path,
        );
        if (refined == null) return null; // play-all title
        pick = refined;
      }
      if (!await verifyPick(fp: fp, pick: pick, episodes: episodes)) {
        return null;
      }
      return pick;
    }

    // Season-0 fallback: DVD bonus content lives in TMDB's specials.
    final specials = await fetchSpecials(seriesId, subLang);
    if (specials.isNotEmpty) {
      log('   No regular episode matched — trying season 0 (specials).');
      final spPick = await llmEpisodeMatch(
        fp: fp,
        episodes: specials,
        subtitleText: subtitleText,
      );
      if (spPick != null &&
          await verifyPick(fp: fp, pick: spPick, episodes: specials)) {
        return spPick;
      }
    }

    // LLM declined — ask user (or skip when non-interactive).
    return promptEpisodePick(episodes: episodes);
  }

  // ---------------------------------------------------------------------------
  // Many files, one at a time
  // ---------------------------------------------------------------------------

  /// Per-file matching fallback: matches each subtitle independently.
  Future<Map<int, EpisodePick?>> matchEpisodesPerFile({
    required List<SeasonEpisode> episodes,
    required List<NamingItem> items,
    required Map<int, SubtitleText> subs,
    required Map<int, Fingerprint> fps,
    required int seriesId,
    required String subLang,
  }) async {
    final picks = <int, EpisodePick?>{};
    final usedStems = <String, int>{};

    // TMDB season 0 (specials) — fetched lazily, once, for files that match
    // no regular episode: DVD bonus content usually lives there.
    List<SeasonEpisode>? specials;
    Future<List<SeasonEpisode>> loadSpecials() async =>
        specials ??= await fetchSpecials(seriesId, subLang);

    // Probe real durations once; the median anchors multi-part and
    // play-all detection when TMDB runtimes are missing.
    final durations = <int, double>{};
    for (var i = 0; i < items.length; i++) {
      final d = await probe.secondsOf(items[i].file);
      if (d != null) durations[i] = d;
    }
    final medianSecs = median(durations.values);

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

    // Files that must stay unnamed even when a gap in the sequence would
    // fit them: duplicate copies and play-all titles.
    final noGapFill = <int>{};

    for (var i = 0; i < items.length; i++) {
      final sub = subs[i];
      // Reuse the per-file summary computed earlier; it's the strongest signal.
      final fp = fps[i] ?? Fingerprint.empty;
      if (sub == null) continue;
      final dupSrc = duplicateOf[i];
      if (dupSrc != null) {
        log(
          '   AutoNamer: ${items[i].file.path} has near-identical subtitles '
          'to ${items[dupSrc].file.path} — duplicate copy, leaving unnamed.',
          isError: true,
        );
        picks[i] = null;
        noGapFill.add(i);
        continue;
      }
      log('   [${i + 1}/${items.length}] Naming: ${items[i].file.path}');
      var pick = await llmEpisodeMatch(
        fp: fp,
        episodes: episodes,
        subtitleText: sub.text,
      );
      if (pick == null) {
        // Retry once with a proper-noun-dense excerpt before giving up.
        log('   Episode match failed — retrying with name-dense excerpt.');
        pick = await llmEpisodeMatch(
          fp: fp,
          episodes: episodes,
          subtitleText: entityDenseExcerpt(sub.text),
        );
      }
      if (pick == null) {
        // Season-0 fallback: DVD bonus content lives in TMDB's specials.
        final sp = await loadSpecials();
        if (sp.isNotEmpty) {
          log('   No regular episode matched — trying season 0 (specials).');
          pick = await llmEpisodeMatch(
            fp: fp,
            episodes: sp,
            subtitleText: sub.text,
          );
          if (pick != null &&
              !await verifyPick(fp: fp, pick: pick, episodes: sp)) {
            pick = null;
          }
        }
        if (pick == null) {
          picks[i] = await promptEpisodePick(episodes: episodes);
          continue;
        }
        // Specials get no duration refinement (their runtimes vary wildly).
        final dupSp = usedStems[pick.stem];
        if (dupSp != null) {
          log(
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

      final refined = applyDurationRefinement(
        pick: pick,
        episodes: episodes,
        durationSecs: durations[i],
        medianSecs: medianSecs,
        filePath: items[i].file.path,
      );
      if (refined == null) {
        picks[i] = null; // play-all title
        noGapFill.add(i);
        continue;
      }
      pick = refined;

      final dup = usedStems[pick.stem];
      if (dup != null) {
        pick = await handleStemConflict(
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

      if (!await verifyPick(
        fp: fp,
        pick: pick,
        episodes: episodes,
        claimedBy: usedStems,
      )) {
        picks[i] = null;
        continue;
      }
      usedStems[pick.stem] = i;
      picks[i] = pick;
    }

    applyGapFills(
      picks: picks,
      eligible: {
        for (final i in subs.keys)
          if (!noGapFill.contains(i)) i,
      },
      episodes: episodes,
      items: items,
      durations: durations,
      medianSecs: medianSecs,
    );
    return picks;
  }

  /// Names unnamed files that sit in a single gap between two named
  /// neighbours (see [fillSingleGaps]) and logs each fill.
  void applyGapFills({
    required Map<int, EpisodePick?> picks,
    required Set<int> eligible,
    required List<SeasonEpisode> episodes,
    required List<NamingItem> items,
    required Map<int, double> durations,
    required double? medianSecs,
  }) {
    final fills = fillSingleGaps(
      count: items.length,
      picks: picks,
      eligible: eligible,
      episodes: episodes,
      durations: durations,
      medianSecs: medianSecs,
    );
    for (final entry in fills.entries) {
      final i = entry.key;
      final pick = entry.value;
      log(
        '   [${i + 1}/${items.length}] ${items[i].file.path} → ${pick.stem} '
        '"${pick.title}" by elimination (neighbours '
        '${picks[i - 1]!.stem} and ${picks[i + 1]!.stem}).',
      );
      picks[i] = pick;
    }
  }

  /// Re-matches file [i] against only the episodes no file has claimed
  /// (plus [exclude], the contested pick). Used when a stem conflict could
  /// not be settled: the LLM then has to choose among what is still open.
  /// Returns null when nothing is open, the LLM declines, or its pick
  /// collides with an existing claim.
  Future<EpisodePick?> rematchExcludingClaimed({
    required int i,
    required Fingerprint fp,
    required String subtitleText,
    required List<SeasonEpisode> episodes,
    required List<NamingItem> items,
    required Map<int, EpisodePick?> picks,
    required Map<String, int> usedStems,
    required EpisodePick exclude,
    required Map<int, double> durations,
    required double? medianSecs,
  }) async {
    final claimed = claimedEpisodes([...picks.values, exclude]);
    final open = unclaimedEpisodes(episodes, claimed);
    if (open.isEmpty || open.length == episodes.length) return null;
    log(
      '   Re-matching ${items[i].file.path} with '
      '${episodes.length - open.length} claimed episode(s) excluded.',
    );
    var pick = await llmEpisodeMatch(
      fp: fp,
      episodes: open,
      subtitleText: subtitleText,
    );
    pick ??= await llmEpisodeMatch(
      fp: fp,
      episodes: open,
      subtitleText: entityDenseExcerpt(subtitleText),
    );
    if (pick == null) return null;
    final refined = applyDurationRefinement(
      pick: pick,
      episodes: episodes,
      durationSecs: durations[i],
      medianSecs: medianSecs,
      filePath: items[i].file.path,
    );
    if (refined == null) return null;
    for (var n = refined.ep; n <= refined.epEnd; n++) {
      if (claimed.contains((season: refined.season, ep: n)) ||
          usedStems.containsKey(refined.stem)) {
        log(
          '   Re-match: ${refined.stem} overlaps an existing claim — leaving '
          '${items[i].file.path} unnamed.',
          isError: true,
        );
        return null;
      }
    }
    log(
      '   Re-match: ${items[i].file.path} → ${refined.stem} "${refined.title}".',
    );
    return refined;
  }

  // ---------------------------------------------------------------------------
  // Batch assignment — one LLM call assigns all files to episodes at once.
  // ---------------------------------------------------------------------------

  Future<Map<int, EpisodePick?>> llmBatchAssign({
    required List<SeasonEpisode> episodes,
    required List<NamingItem> items,
    required Map<int, SubtitleText> subs,
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
    log(
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
      final isEnglish = looksEnglish(sub.text);
      final weak = hasSummary && isWeakSummary(fp.summary);

      if (!isEnglish && !hasSummary) {
        log(
          '   Batch assignment: file ${i + 1} subtitle does not look English'
          ' and has no summary — flagged for LLM.',
          isError: true,
        );
      } else if (!isEnglish) {
        log(
          '   Batch assignment: file ${i + 1} subtitle does not look English'
          ' — flagged for LLM.',
          isError: true,
        );
      }

      subBuf.write('[${i + 1}]');
      if (!isEnglish) {
        // Non-English: summary is the only usable signal.
        if (hasSummary) {
          subBuf.writeln(
            ' ⚠️ Non-English subtitle — summary only: ${fp.summary}',
          );
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
          episodeExcerpt(
            sub.text,
            chunkSize: 1200,
          ).split('\n').map((l) => '  $l').join('\n'),
        );
      } else if (hasSummary) {
        // Strong English summary: use it as the sole signal.
        subBuf.writeln(' ${fp.summary}');
      } else {
        // No summary: fall back to a compact excerpt.
        subBuf.writeln();
        subBuf.writeln(
          episodeExcerpt(
            sub.text,
            chunkSize: 800,
          ).split('\n').map((l) => '  $l').join('\n'),
        );
      }
      subBuf.writeln();
    }

    // Build episode list with extracted entities for better matching.
    final epBuf = StringBuffer();
    for (var i = 0; i < filteredEpisodes.length; i++) {
      final c = filteredEpisodes[i];
      final label = episodeStem(c.season, c.ep.number);
      final entities = extractEntities(c.ep.overview);
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
    log(
      '   Batch assignment: $n subtitle(s) → $m episode(s) '
      '(${subBuf.length} chars).',
    );

    final response = await llm.chat(
      timeout: const Duration(minutes: 10),
      maxTokens: 32000,
      temperature: 0.0,
      [
        {'role': 'system', 'content': batchAssignSystemPrompt(n, m)},
        {
          'role': 'user',
          'content': 'Subtitle files:\n$subBuf\nEpisodes:\n$epBuf\nJSON:',
        },
      ],
    );

    if (response == null) {
      log('   Batch assignment: no response from LLM.', isError: true);
      return {};
    }

    final obj = parseJsonObject(response);
    if (obj == null) {
      log(
        '   Batch assignment: JSON parse failed. Raw: $response',
        isError: true,
      );
      return {};
    }

    if (obj.containsKey('reasoning')) {
      final reasoning = obj['reasoning'] as String? ?? '';
      if (reasoning.isNotEmpty) {
        log('   LLM reasoning: $reasoning');
      }
    }

    final rawAssignments = obj['assignments'];
    if (rawAssignments is! Map) {
      log(
        '   Batch assignment: "assignments" missing or wrong type.',
        isError: true,
      );
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
        rawEp = jsonInt(m['ep']);
        confidence = m['confidence'] is num
            ? (m['confidence'] as num).toDouble()
            : 0.7;
      } else {
        rawEp = jsonInt(entry.value);
        confidence = 0.7;
      }

      final epIdx = rawEp - 1; // -1 when LLM returned 0 (unassigned)

      if (epIdx == -1) {
        log('   Batch assignment: file ${fileIdx + 1} → unassigned (ep=0).');
        continue;
      }
      if (epIdx < 0 || epIdx >= filteredEpisodes.length) {
        log(
          '   Batch assignment: file ${fileIdx + 1} got ep=$rawEp '
          '(out of range) — dropping.',
          isError: true,
        );
        continue;
      }
      if (confidence < 0.4) {
        log(
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
        log(
          '   Batch assignment: file ${displaced + 1} displaced by '
          'file ${fileIdx + 1} for ep ${epIdx + 1} '
          '(confidence ${conf.toStringAsFixed(2)} > '
          '${epToBest[epIdx]!.confidence.toStringAsFixed(2)}).',
          isError: true,
        );
        epToBest[epIdx] = (fileIdx: fileIdx, confidence: conf);
      } else {
        log(
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
      final d = await probe.secondsOf(items[i].file);
      if (d != null) durations[i] = d;
    }
    final medianSecs = median(durations.values);

    final picks = <int, EpisodePick?>{};
    for (final entry in epToBest.entries) {
      final epIdx = entry.key;
      final fileIdx = entry.value.fileIdx;
      final c = filteredEpisodes[epIdx];
      final pick = EpisodePick(
        stem: episodeStem(c.season, c.ep.number),
        title: c.ep.title,
        season: c.season,
        ep: c.ep.number,
      );
      final refined = applyDurationRefinement(
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
      log(
        '   [${fileIdx + 1}/${items.length}] → ${refined.stem} '
        '"${refined.title}"',
      );
      picks[fileIdx] = refined;
    }

    // Files dropped as duplicates or low-confidence may still sit in a
    // single gap between two placed neighbours; play-all titles never do.
    final playAll = {
      for (final e in picks.entries)
        if (e.value == null) e.key,
    };
    applyGapFills(
      picks: picks,
      eligible: {
        for (final i in subs.keys)
          if (!playAll.contains(i)) i,
      },
      episodes: episodes,
      items: items,
      durations: durations,
      medianSecs: medianSecs,
    );

    return picks;
  }

  // ---------------------------------------------------------------------------
  // LLM episode match — raw subtitle excerpt + TMDB episode list
  // ---------------------------------------------------------------------------

  Future<EpisodePick?> llmEpisodeMatch({
    required Fingerprint fp,
    required List<SeasonEpisode> episodes,
    required String subtitleText,
  }) async {
    if (episodes.isEmpty) return null;

    log(
      '   Episode match: sending ${subtitleText.length} chars of subtitle text.',
    );

    final epBuf = StringBuffer();
    for (var i = 0; i < episodes.length; i++) {
      final c = episodes[i];
      final label = episodeStem(c.season, c.ep.number);
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
          'content': episodeMatchSystemPrompt(hasSummary: hasSummary),
        },
        {'role': 'user', 'content': userContent},
      ],
    );

    if (response == null) {
      log('   LLM episode match: no response.', isError: true);
      return null;
    }
    final obj = parseJsonObject(response);
    if (obj == null) {
      log(
        '   LLM episode match: JSON parse failed. Raw: $response',
        isError: true,
      );
      return null;
    }
    final n = jsonInt(obj['pick']);
    if (n < 1 || n > episodes.length) {
      log('   LLM episode match: pick=$n — declined or out of range.');
      return null;
    }

    final pick = pickFromEpisodeIndex(episodes, n);
    log('   LLM episode match: ${pick.stem} "${pick.title}"');
    return pick;
  }

  // ---------------------------------------------------------------------------
  // Manual episode picker (fallback when LLM declines)
  // ---------------------------------------------------------------------------

  Future<EpisodePick?> promptEpisodePick({
    required List<SeasonEpisode> episodes,
  }) async {
    final labels = [
      for (final c in episodes)
        '${episodeStem(c.season, c.ep.number)} "${c.ep.title}"',
    ];
    final idx = await prompter.choose(
      '   LLM could not identify the episode. Pick manually:',
      labels,
    );
    if (idx == null) {
      log('   AutoNamer: LLM declined — skipping.', isError: true);
      return null;
    }
    return pickFromEpisodeIndex(episodes, idx + 1);
  }

  // ---------------------------------------------------------------------------
  // Duration-aware refinement (multi-part ranges, play-all detection)
  // ---------------------------------------------------------------------------

  /// Applies [refineWithDuration] to a pick. Returns null for a play-all
  /// title (which must not claim an episode name); otherwise the pick,
  /// upgraded to a range stem when the duration covers a multi-part group.
  EpisodePick? applyDurationRefinement({
    required EpisodePick pick,
    required List<SeasonEpisode> episodes,
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
      log(
        '   AutoNamer: $filePath is $mins min — looks like a play-all/'
        'concatenated disc title, not episode ${pick.stem} — leaving unnamed.',
        isError: true,
      );
      return null;
    }
    if (r.epStart == pick.ep && r.epEnd == pick.ep) {
      // Kept as a single episode — warn when the duration clearly exceeds
      // the expected length (likely an extended or episode-plus-extras cut).
      final expected = expectedSecsFor(pick, episodes, medianSecs);
      if (durationSecs != null &&
          expected != null &&
          durationSecs > expected * 1.5) {
        log(
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
    log(
      '   Duration ${((durationSecs ?? 0) / 60).toStringAsFixed(1)} min '
      'covers a multi-part episode → $stem "$title".',
    );
    return EpisodePick(
      stem: stem,
      title: title,
      season: pick.season,
      ep: r.epStart,
      epEnd: r.epEnd,
    );
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
  ///
  /// [claimedBy] (stem → file index of other files' picks) makes a
  /// contradiction that names an episode another file already holds count
  /// as inconclusive: two files cannot both be that episode, and the
  /// primary match already settled who is.
  Future<bool> verifyPick({
    required Fingerprint fp,
    required EpisodePick pick,
    required List<SeasonEpisode> episodes,
    Map<String, int> claimedBy = const {},
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
        {'role': 'system', 'content': verifyPickSystemPrompt},
        {
          'role': 'user',
          'content': 'Summary:\n${fp.summary}\n\nEpisodes:\n$epBuf\nJSON:',
        },
      ],
    );
    if (response == null) return true;
    final obj = parseJsonObject(response);
    if (obj == null) return true;
    final n = jsonInt(obj['pick']);
    if (n < 1 || n > episodes.length) return true; // inconclusive → accept

    final re = episodes[n - 1];
    final samePick =
        re.season == pick.season &&
        re.ep.number >= pick.ep &&
        re.ep.number <= pick.epEnd;
    // Same part group also counts: parts of one special are one story.
    final group = partGroup(episodes, pick.season, pick.ep);
    final sameGroup =
        group != null &&
        re.season == pick.season &&
        re.ep.number >= group.start &&
        re.ep.number <= group.end;
    if (samePick || sameGroup) return true;

    final reStem = episodeStem(re.season, re.ep.number);
    if (claimedBy.containsKey(reStem)) {
      log(
        '   Verification: blind re-match says $reStem, but that episode is '
        'already taken by another file — accepting ${pick.stem}.',
      );
      return true;
    }

    log(
      '   ⚠ Verification: blind re-match says '
      '${episodeStem(re.season, re.ep.number)} "${re.ep.title}", '
      'not ${pick.stem} "${pick.title}" — leaving unnamed.',
      isError: true,
    );
    return false;
  }

  // ---------------------------------------------------------------------------
  // Duplicate-stem disambiguation (LLM)
  // ---------------------------------------------------------------------------

  /// Two files claimed the same episode; at most one is right. One LLM call
  /// compares both summaries against the episode list and reassigns each.
  /// Returns 1-based episode indices (0 = could not place) for the earlier
  /// claimant and the new claimant, or null when the LLM gave no usable answer.
  Future<({int first, int second})?> resolveStemConflict({
    required Fingerprint firstFp,
    required Fingerprint secondFp,
    required EpisodePick contested,
    required List<SeasonEpisode> episodes,
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
          'content': stemConflictSystemPrompt(
            contestedTitle: contested.title,
            contestedStem: contested.stem,
          ),
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
    final obj = parseJsonObject(response);
    if (obj == null) return null;
    final first = jsonInt(obj['first']);
    final second = jsonInt(obj['second']);
    if (first < 0 || first > episodes.length) return null;
    if (second < 0 || second > episodes.length) return null;
    if (first == second && first != 0) return null;
    return (first: first, second: second);
  }
}
