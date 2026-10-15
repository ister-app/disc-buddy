import 'episode_matcher.dart';
import 'episode_math.dart';
import 'naming_types.dart';
import 'subtitle_text.dart';

/// Resolution of two files that claim the same episode stem during
/// per-file matching. Mutates the shared `picks`/`usedStems` maps in place
/// because an earlier claimant may be demoted or reassigned.
extension EpisodeConflicts on EpisodeMatcher {
  /// Resolves a duplicate-stem conflict between file [i] and earlier file
  /// [dupIdx]. Similar subtitle texts mean the disc carries the same episode
  /// in different cuts — resolved by duration (primary/extended/bonus).
  /// Dissimilar texts mean at most one file is that episode — resolved via
  /// one LLM disambiguation call, which may reassign [dupIdx]'s pick in
  /// place. Returns file [i]'s corrected pick, or null to leave it unnamed.
  Future<EpisodePick?> handleStemConflict({
    required int i,
    required int dupIdx,
    required EpisodePick pick,
    required List<SeasonEpisode> episodes,
    required List<NamingItem> items,
    required Map<int, Fingerprint> fps,
    required Map<int, SubtitleText> subs,
    required Map<int, EpisodePick?> picks,
    required Map<String, int> usedStems,
    required Map<int, double> durations,
    required double? medianSecs,
  }) async {
    final textA = subs[dupIdx]?.text ?? '';
    final textB = subs[i]?.text ?? '';
    final similarity = textSimilarity(textA, textB);
    if (textA.isNotEmpty && textB.isNotEmpty && similarity >= 0.5) {
      return resolveVersionConflict(
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

    log(
      '   AutoNamer: ${items[i].file.path} and ${items[dupIdx].file.path} '
      'both matched ${pick.stem} — asking LLM to disambiguate.',
      isError: true,
    );
    final resolved = await resolveStemConflict(
      firstFp: fps[dupIdx] ?? Fingerprint.empty,
      secondFp: fps[i] ?? Fingerprint.empty,
      contested: pick,
      episodes: episodes,
    );
    if (resolved == null) {
      log(
        '   Disambiguation failed — keeping ${items[dupIdx].file.path}, '
        'leaving ${items[i].file.path} unnamed.',
        isError: true,
      );
      return null;
    }

    // Reassign the earlier claimant when the LLM moved it elsewhere.
    if (resolved.first > 0) {
      final newFirst = applyDurationRefinement(
        pick: pickFromEpisodeIndex(episodes, resolved.first),
        episodes: episodes,
        durationSecs: durations[dupIdx],
        medianSecs: medianSecs,
        filePath: items[dupIdx].file.path,
      );
      if (newFirst != null && newFirst.stem != picks[dupIdx]?.stem) {
        log(
          '   Disambiguation: ${items[dupIdx].file.path} reassigned '
          '→ ${newFirst.stem} "${newFirst.title}".',
        );
        usedStems.remove(picks[dupIdx]?.stem);
        picks[dupIdx] = newFirst;
        usedStems[newFirst.stem] = dupIdx;
      }
    } else {
      log(
        '   Disambiguation: ${items[dupIdx].file.path} could not be placed '
        '— leaving it unnamed.',
        isError: true,
      );
      usedStems.remove(picks[dupIdx]?.stem);
      picks[dupIdx] = null;
    }

    if (resolved.second == 0) {
      log(
        '   Disambiguation: ${items[i].file.path} could not be placed '
        '— leaving unnamed.',
        isError: true,
      );
      return null;
    }
    final newPick = applyDurationRefinement(
      pick: pickFromEpisodeIndex(episodes, resolved.second),
      episodes: episodes,
      durationSecs: durations[i],
      medianSecs: medianSecs,
      filePath: items[i].file.path,
    );
    if (newPick == null) return null;
    if (usedStems.containsKey(newPick.stem)) {
      log(
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
  EpisodePick? resolveVersionConflict({
    required int i,
    required int dupIdx,
    required EpisodePick pick,
    required List<SeasonEpisode> episodes,
    required List<NamingItem> items,
    required Map<int, EpisodePick?> picks,
    required Map<String, int> usedStems,
    required Map<int, double> durations,
    required double? medianSecs,
    required double similarity,
  }) {
    log(
      '   AutoNamer: ${items[i].file.path} and ${items[dupIdx].file.path} '
      'carry the same episode ${pick.stem} in different cuts '
      '(similarity ${similarity.toStringAsFixed(2)}) — resolving by duration.',
    );
    final expected = expectedSecsFor(pick, episodes, medianSecs);
    final roles = classifyVersions(
      durationsSecs: [durations[dupIdx], durations[i]],
      expectedSecs: expected,
    );

    // Builds the pick for a non-primary role, registering its stem.
    EpisodePick? assignSecondary(int fileIdx, VersionRole role) {
      if (role == VersionRole.leaveUnnamed) {
        log(
          '   Version: ${items[fileIdx].file.path} runs '
          '${((durations[fileIdx] ?? 0) / 60).toStringAsFixed(1)} min — '
          'episode-plus-extras cut, leaving unnamed.',
          isError: true,
        );
        return null;
      }
      final stem = uniqueExtendedStem(pick.stem, usedStems);
      log(
        '   Version: ${items[fileIdx].file.path} → "$stem" (longer cut).',
      );
      return EpisodePick(
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
      log('   Version: ${items[i].file.path} keeps ${pick.stem}.');
      return pick;
    }
    // Earlier claimant stays primary; place the new file.
    return assignSecondary(i, roles[1]);
  }
}
