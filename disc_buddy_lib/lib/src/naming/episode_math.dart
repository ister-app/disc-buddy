import 'naming_types.dart';
import 'subtitle_text.dart';

/// Pure episode arithmetic: stems, multi-part groups, duration-based
/// refinement and version classification. No I/O, no LLM.

/// Builds an `s01e02` stem, or `s01e02-e04` when [epEnd] > [epStart].
String episodeStem(int season, int epStart, [int? epEnd]) {
  final s = season.toString().padLeft(2, '0');
  final e1 = epStart.toString().padLeft(2, '0');
  if (epEnd == null || epEnd == epStart) return 's${s}e$e1';
  return 's${s}e$e1-e${epEnd.toString().padLeft(2, "0")}';
}

/// Strips a trailing part marker — "(2)", "[2]", "Part 3", "- Part One" —
/// so multi-part episodes ("iPsycho (1)"/"iPsycho (2)") share a base title.
String baseEpisodeTitle(String title) => title
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
({int start, int end})? partGroup(
  List<SeasonEpisode> episodes,
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
({int epStart, int epEnd, bool playAll}) refineWithDuration({
  required List<SeasonEpisode> episodes,
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

/// Assigns a [VersionRole] to each of several files that carry the same
/// episode in different cuts. The file whose duration sits closest to
/// [expectedSecs] becomes [VersionRole.primary]; the rest become
/// [VersionRole.extended] up to 1.5× the expected duration and
/// [VersionRole.leaveUnnamed] beyond that (episode-plus-extras cuts).
/// With no expected duration or no known durations the first file wins and
/// the rest are extended — skipping without evidence is too aggressive.
List<VersionRole> classifyVersions({
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

/// Filters [episodes] to the top [maxEpisodes] most similar to any of
/// [summaries], using Jaccard word similarity on lowercased text.
/// Returns the original list unchanged when there are no summaries or the
/// list is already within the limit.
List<SeasonEpisode> filterEpisodesBySimilarity(
  List<SeasonEpisode> episodes,
  List<String> summaries, {
  int maxEpisodes = 25,
}) {
  if (summaries.isEmpty || episodes.length <= maxEpisodes) return episodes;

  final scored = episodes.map((e) {
    final overviewLower = e.ep.overview.toLowerCase();
    var best = 0.0;
    for (final summary in summaries) {
      final s = wordSetSimilarity(summary.toLowerCase(), overviewLower);
      if (s > best) best = s;
    }
    return (entry: e, score: best);
  }).toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  return scored.take(maxEpisodes).map((s) => s.entry).toList();
}

/// Median of [values]; null with fewer than three samples.
double? median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  if (sorted.length < 3) return null;
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// `"<base> (extended)"`, numbered when that stem is already taken.
String uniqueExtendedStem(String base, Map<String, int> usedStems) {
  var stem = '$base (extended)';
  for (var n = 2; usedStems.containsKey(stem); n++) {
    stem = '$base (extended $n)';
  }
  return stem;
}

/// Expected duration in seconds of the episode(s) covered by [pick]:
/// summed TMDB runtimes, with [medianSecs] filling in per missing part.
double? expectedSecsFor(
  EpisodePick pick,
  List<SeasonEpisode> episodes,
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

/// [EpisodePick] for the 1-based [oneBased] entry of [episodes].
EpisodePick pickFromEpisodeIndex(List<SeasonEpisode> episodes, int oneBased) {
  final c = episodes[oneBased - 1];
  return EpisodePick(
    stem: episodeStem(c.season, c.ep.number),
    title: c.ep.title,
    season: c.season,
    ep: c.ep.number,
  );
}
