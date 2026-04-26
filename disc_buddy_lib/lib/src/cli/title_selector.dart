import '../models/bluray_title.dart';
import '../models/dvd_title.dart';

/// Selects likely episodes or the main feature from a Blu-ray title list.
///
/// - Filters out tracks shorter than 5 minutes (menus, trailers).
/// - Deduplicates tracks with equal duration (±5 s): keeps the track with
///   the most audio and subtitle streams.
/// - Detects a series if ≥ 3 unique tracks are within ±30 % of the median duration.
/// - Falls back to the longest unique track as the main feature.
///
/// Returns an empty list if no suitable titles are found.
List<BlurayTitle> autoSelectBluray(List<BlurayTitle> titles) {
  return _autoSelect(
    titles:            titles,
    duration:          (t) => t.duration,
    score:             (t) => t.audioCount + t.subtitleCount,
    chapterTimestamps: (t) => t.chapters,
  )..sort((a, b) => a.index.compareTo(b.index));
}

/// Selects likely episodes or the main feature from a DVD title list.
///
/// First deduplicates cross-VTS groups that represent the same episode
/// (DVD navigation artifacts where identical content is referenced by multiple
/// VTS sections). Then looks for "coherent multi-angle groups": VTS sections
/// where every angle has a duration within ±3 minutes of the primary angle
/// (pgcIndex 0). When such groups exist they are ranked by stream quality and
/// returned in full (all angles). If no coherent multi-angle group is found the
/// function falls back to the single-angle (pgcIndex 0) logic used by Blu-ray,
/// augmented with stream-count consistency filtering and angle expansion.
List<DvdTitle> autoSelectDvd(List<DvdTitle> titles) {
  // Collapse cross-VTS duplicates first.
  final dedupedTitles = deduplicateDvdTitles(titles);

  const minDur   = Duration(minutes: 5);
  const angleTol = Duration(minutes: 3);

  // 1. Group all titles by VTS number.
  final byVts = <int, List<DvdTitle>>{};
  for (final t in dedupedTitles) {
    byVts.putIfAbsent(t.vtsNumber, () => []).add(t);
  }

  // 2. Find coherent multi-angle groups.
  //
  // A group is coherent if every angle is within ±3 min of the primary angle.
  // Chapter counts are intentionally NOT compared here: DVDs sometimes store
  // multiple episodes (or episode variants) in "angle" slots, where each slot
  // naturally has a different chapter structure.
  final coherent = <List<DvdTitle>>[];
  for (final group in byVts.values) {
    // Must have more than one angle and a primary (pgcIndex 0) that is long enough.
    if (group.length <= 1) continue;
    final primary = group.firstWhere(
      (t) => t.pgcIndex == 0,
      orElse: () => group.first,
    );
    if (primary.duration < minDur) continue;

    final primarySecs = primary.duration.inSeconds;
    final allCoherent = group.every(
      (t) => (t.duration.inSeconds - primarySecs).abs() <= angleTol.inSeconds,
    );
    if (!allCoherent) continue;

    coherent.add(group..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex)));
  }

  // 2b. Compilation detection within a single VTS group.
  //
  // Some DVDs store a full-disc compilation as pgcIndex 0 and individual
  // episodes as subsequent angles (pgcIndex 1, 2, …).  These groups fail the
  // ±3-min coherent test because the compilation is much longer than each
  // episode.  Detect the pattern when:
  //   • ≥ 2 non-primary angles are present and form a coherent series
  //     (each within ±30 % of their mutual median duration), and
  //   • the primary (pgcIndex 0) is ≥ 1.5× that median (i.e. clearly longer).
  // Return the individual episodes only; the compilation is discarded.
  final compilationEps = <DvdTitle>[];
  for (final group in byVts.values) {
    final others = group
        .where((t) => t.pgcIndex != 0 && t.duration >= minDur)
        .toList();
    if (others.length < 2) continue;

    final primary = group.firstWhere(
      (t) => t.pgcIndex == 0,
      orElse: () => group.first,
    );
    if (primary.duration < minDur) continue;

    final otherSecs = others.map((t) => t.duration.inSeconds).toList()..sort();
    final median    = otherSecs[(otherSecs.length - 1) ~/ 2];
    if (median == 0) continue;

    // Non-primary angles must be coherent amongst themselves.
    // Double-episode PGCs (≈ 2× median) are tolerated: some discs pack one
    // two-episode entry alongside single episodes in the same VTS.
    final seriesLike = others.every((t) {
      final diff  = (t.duration.inSeconds - median).abs();
      if (diff <= median * 0.3) return true;
      final diff2 = (t.duration.inSeconds - 2 * median).abs();
      return diff2 <= 2 * median * 0.3;
    });
    if (!seriesLike) continue;

    // Primary must be notably longer (compilation threshold).
    if (primary.duration.inSeconds < median * 1.5) continue;

    compilationEps.addAll(
      others..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex)),
    );
  }
  if (compilationEps.isNotEmpty) {
    // Also pick up standalone episodes from other VTS groups that have a
    // similar duration and at least as many streams.  Some discs store most
    // episodes as angles inside a single VTS (caught above) but keep one or
    // more episodes in separate VTS sections — sometimes with an extra audio
    // track (e.g. a commentary) that breaks the strict stream-count filter
    // used in the fallback path.
    final epSecs     = compilationEps.map((t) => t.duration.inSeconds).toList()..sort();
    final epMedian   = epSecs[(epSecs.length - 1) ~/ 2];
    final epMinAudio = compilationEps.map((t) => t.audioTracks.length).reduce((a, b) => a < b ? a : b);
    final epMinSub   = compilationEps.map((t) => t.subtitleTracks.length).reduce((a, b) => a < b ? a : b);
    final compVts    = compilationEps.first.vtsNumber;

    // Average sector count of the detected compilation episodes. Copy-
    // protection schemes sometimes place low-bitrate decoy PGCs with inflated
    // IFO durations alongside the real content; the real episodes have a much
    // higher sector count for the same declared duration.  Search every other
    // VTS for a higher-density set (including non-primary PGCs, since discs
    // that use the angle mechanism store individual episodes at pgcIndex > 0
    // with a long play-all at pgcIndex 0).
    final compDensity = compilationEps
        .map((t) => t.totalSectors)
        .reduce((a, b) => a + b) / compilationEps.length;

    // Density in sectors/second — used to reject low-bitrate decoy PGCs from
    // other VTSes in the "add standalone episodes" pass below.
    final compTotalDurSecs = compilationEps.fold<int>(0, (s, t) => s + t.duration.inSeconds);
    final compTotalSectors  = compilationEps.fold<int>(0, (s, t) => s + t.totalSectors);
    final compDensityPerSec = compTotalDurSecs > 0
        ? compTotalSectors / compTotalDurSecs
        : 0.0;

    var bestCandidates = <DvdTitle>[];
    var bestDensity    = compDensity;

    for (final entry in byVts.entries) {
      if (entry.key == compVts) continue;

      final candidates = entry.value
          .where((t) =>
              t.duration >= minDur &&
              (t.duration.inSeconds - epMedian).abs() <= epMedian * 0.3 &&
              t.audioTracks.length >= epMinAudio &&
              t.subtitleTracks.length >= epMinSub)
          .toList();
      if (candidates.isEmpty) continue;

      final candDensity = candidates
          .map((t) => t.totalSectors)
          .reduce((a, b) => a + b) / candidates.length;

      if (candDensity > compDensity * 1.5 &&
          candDensity > bestDensity &&
          candidates.length >= compilationEps.length) {
        bestCandidates = candidates..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex));
        bestDensity    = candDensity;
      }
    }

    if (bestCandidates.isNotEmpty) {
      // Include double-episode PGCs from the winning VTS.
      final bestVts = bestCandidates.first.vtsNumber;
      final doubles = (byVts[bestVts] ?? []).where((t) =>
          t.duration >= minDur &&
          (t.duration.inSeconds - 2 * epMedian).abs() <= 2 * epMedian * 0.3).toList();
      return ([...bestCandidates, ...doubles]..sort((a, b) {
        final vts = a.vtsNumber.compareTo(b.vtsNumber);
        return vts != 0 ? vts : a.pgcIndex.compareTo(b.pgcIndex);
      }));
    }

    // No higher-density set found: apply original single-angle primary logic.
    for (final entry in byVts.entries) {
      if (entry.key == compVts) continue;
      final primary = entry.value.firstWhere(
        (t) => t.pgcIndex == 0,
        orElse: () => entry.value.first,
      );
      if (primary.duration < minDur) continue;
      if ((primary.duration.inSeconds - epMedian).abs() > epMedian * 0.3) continue;
      if (primary.audioTracks.length < epMinAudio) continue;
      if (primary.subtitleTracks.length < epMinSub) continue;
      // Reject copy-protection decoys: their sector count per second is
      // typically < 70 % of the compilation episodes' density.
      if (compDensityPerSec > 0 && primary.duration.inSeconds > 0) {
        final primDensityPerSec = primary.totalSectors / primary.duration.inSeconds;
        if (primDensityPerSec < compDensityPerSec * 0.7) continue;
      }
      compilationEps.add(primary);
    }

    return compilationEps..sort((a, b) {
      final vts = a.vtsNumber.compareTo(b.vtsNumber);
      return vts != 0 ? vts : a.pgcIndex.compareTo(b.pgcIndex);
    });
  }

  if (coherent.isNotEmpty) {
    int groupScore(List<DvdTitle> g) {
      final p = g.firstWhere((t) => t.pgcIndex == 0, orElse: () => g.first);
      return p.audioTracks.length + p.subtitleTracks.length;
    }
    Duration groupDur(List<DvdTitle> g) =>
        g.firstWhere((t) => t.pgcIndex == 0, orElse: () => g.first).duration;

    // 3a. Series detection across coherent groups.
    if (coherent.length >= 2) {
      final secs   = coherent.map((g) => groupDur(g).inSeconds).toList()..sort();
      final median = secs[(secs.length - 1) ~/ 2];
      final episodeGroups = coherent
          .where((g) => (groupDur(g).inSeconds - median).abs() <= median * 0.3)
          .toList();
      // Also include "double episodes" (≈ 2× median duration).
      final doubleGroups = coherent.where((g) {
        final s = groupDur(g).inSeconds;
        return !episodeGroups.contains(g) &&
               (s - 2 * median).abs() <= 2 * median * 0.3;
      }).toList();
      // Count double-episode groups as 2 towards the series threshold.
      final effective = episodeGroups.length + doubleGroups.length * 2;
      if (effective >= 3 && episodeGroups.isNotEmpty) {
        return ([...episodeGroups, ...doubleGroups].expand((g) => g).toList()
          ..sort((a, b) {
            final vts = a.vtsNumber.compareTo(b.vtsNumber);
            return vts != 0 ? vts : a.pgcIndex.compareTo(b.pgcIndex);
          }));
      }
    }

    // 3b. Feature film: pick the best coherent group.
    coherent.sort((a, b) {
      final sd = groupScore(b).compareTo(groupScore(a));
      if (sd != 0) return sd;
      return groupDur(b).compareTo(groupDur(a));
    });
    return coherent.first;
  }

  // 4. Fallback: single-angle logic.
  //
  // Filter to the most common (ties resolved by highest) audio + subtitle
  // count combination, then run the shared _autoSelect core.  This prevents
  // "extra" tracks with stripped-down audio/sub from polluting series detection.
  final angle1 = dedupedTitles
      .where((t) => t.pgcIndex == 0 && t.duration >= minDur)
      .toList();

  final chapterMode = _modeFrequency(angle1.map((t) => t.chapters.length));

  // Sequential weighted filter: audio first, then subtitle within that set.
  // Uses count × value scoring so a richer-stream group wins over a numerically
  // larger but stripped-down group (e.g. 3 titles with 4 audio beat 4 with 1).
  final targetAudio = _modeWeighted(angle1.map((t) => t.audioTracks.length));
  final byAudio     = targetAudio != null
      ? angle1.where((t) => t.audioTracks.length == targetAudio).toList()
      : angle1;
  final targetSub   = _modeWeighted(byAudio.map((t) => t.subtitleTracks.length));
  final filtered    = targetSub != null
      ? byAudio.where((t) => t.subtitleTracks.length == targetSub).toList()
      : byAudio;

  final selected = _autoSelect(
    titles:            filtered,
    duration:          (t) => t.duration,
    score:             (t) =>
        t.audioTracks.length +
        t.subtitleTracks.length +
        (chapterMode != null && t.chapters.length == chapterMode ? 3 : 0),
    chapterTimestamps: (t) => t.chapters,
  );

  if (selected.isEmpty) return [];

  // Expand each selected primary-angle title to include all angles of the same
  // VTS that share its stream counts and meet the minimum duration.  This
  // surfaces the other "slots" on discs that use the angle mechanism to store
  // multiple episodes or variants rather than true camera-angle alternatives.
  final seenTitles = <DvdTitle>{};
  final expanded   = <DvdTitle>[];
  for (final t in selected) {
    final siblings = dedupedTitles
        .where((other) =>
            other.vtsNumber == t.vtsNumber &&
            other.duration >= minDur &&
            other.audioTracks.length >= t.audioTracks.length &&
            other.subtitleTracks.length >= t.subtitleTracks.length)
        .toList()
      ..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex));
    for (final s in siblings) {
      if (seenTitles.add(s)) expanded.add(s);
    }
  }
  return expanded..sort((a, b) {
    final vts = a.vtsNumber.compareTo(b.vtsNumber);
    return vts != 0 ? vts : a.pgcIndex.compareTo(b.pgcIndex);
  });
}

/// Returns a deduplicated list of [titles] where cross-VTS groups that
/// represent the same episode (DVD navigation artifact) are collapsed to their
/// first occurrence.
///
/// Two VTS groups are considered the same episode when their primary angles
/// (pgcIndex 0) share the same duration (within 1 s) and audio/subtitle track
/// counts.  Matching chapter timestamps confirm the match; mismatching
/// timestamps do not override the structural match because different IFO
/// entries for the same physical VOB content can carry differing timing
/// metadata.
List<DvdTitle> deduplicateDvdTitles(List<DvdTitle> titles) {
  const chapTol = Duration(seconds: 2);

  // Build VTS groups ordered by vtsNumber.
  final byVts = <int, List<DvdTitle>>{};
  for (final t in titles) {
    byVts.putIfAbsent(t.vtsNumber, () => []).add(t);
  }
  final groups = byVts.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  // Returns true if group [b] is structurally identical to the already-seen
  // group [a] (i.e., it is a navigation duplicate pointing to the same content).
  bool isDuplicate(List<DvdTitle> a, List<DvdTitle> b) {
    final pa = a.firstWhere((t) => t.pgcIndex == 0, orElse: () => a.first);
    final pb = b.firstWhere((t) => t.pgcIndex == 0, orElse: () => b.first);

    // Structural check: duration and stream counts must match.
    if ((pa.duration.inSeconds - pb.duration.inSeconds).abs() > 1) return false;
    if (pa.audioTracks.length != pb.audioTracks.length) return false;
    if (pa.subtitleTracks.length != pb.subtitleTracks.length) return false;

    // Chapter timestamps are the authoritative signal when both titles have
    // ≥ 2 chapters of the same count.  A match confirms identical content;
    // a mismatch actively refutes it — different episodes that happen to share
    // the same duration will have chapters at clearly different positions
    // (easily > 2 s apart), while navigation duplicates pointing to the same
    // physical VOB content will have near-identical positions.
    final ach = pa.chapters;
    final bch = pb.chapters;
    if (ach.length >= 2 && ach.length == bch.length) {
      return ach.indexed.every((e) => (e.$2 - bch[e.$1]).abs() <= chapTol);
    }

    // No chapter data available → structural match is sufficient.
    return true;
  }

  final seen = <List<DvdTitle>>[];
  for (final entry in groups) {
    final group = entry.value;
    if (!seen.any((s) => isDuplicate(s, group))) seen.add(group);
  }

  return seen
      .expand((g) => g..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex)))
      .toList();
}

// ---------------------------------------------------------------------------
// Display filter
// ---------------------------------------------------------------------------

/// Restricts the title list shown to the user to only those VTS groups that
/// appear in [suggestion].
///
/// When a series is detected (≥ 2 suggested titles), VTS groups that contain
/// none of the suggested titles are hidden — they are typically copy-protection
/// noise or unrelated content.  For feature films (0–1 suggested title), the
/// full list is returned unchanged so the user can still pick an alternative.
List<DvdTitle> filterDisplayDvdTitles(
    List<DvdTitle> all, List<DvdTitle> suggestion) {
  if (suggestion.length < 2) return all;
  final relevantVts = suggestion.map((t) => t.vtsNumber).toSet();
  return all.where((t) => relevantVts.contains(t.vtsNumber)).toList();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns the most frequent integer in [values], or null if [values] is empty.
/// On ties the first-encountered value wins (stable, unlike [_modeWeighted]).
/// Preferred over [_modeWeighted] when raw frequency matters more than value
/// magnitude — e.g. chapter-count detection where "most common" is canonical.
int? _modeFrequency(Iterable<int> values) {
  final counts = <int, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

/// Returns the integer value from [values] with the highest `count × value`
/// score. This ensures that a richer group (e.g. 3 titles with 4 audio tracks)
/// wins over a numerically larger but lower-value group (e.g. 4 titles with 1
/// audio track), because 3×4=12 > 4×1=4. Ties are broken by the larger value.
/// Returns null if [values] is empty.
int? _modeWeighted(Iterable<int> values) {
  final counts = <int, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) {
    final sa = a.value * a.key;
    final sb = b.value * b.key;
    if (sa != sb) return sa > sb ? a : b;
    return a.key > b.key ? a : b;
  }).key;
}

// ---------------------------------------------------------------------------
// Shared core logic
// ---------------------------------------------------------------------------

List<T> _autoSelect<T>({
  required List<T> titles,
  required Duration Function(T) duration,
  required int Function(T) score,
  List<Duration> Function(T)? chapterTimestamps,
}) {
  const minDur  = Duration(minutes: 5);
  const dupTol  = Duration(seconds: 5);
  const chapTol = Duration(seconds: 2);

  // 1. Filter tracks that are too short to be real content.
  final content = titles.where((t) => duration(t) >= minDur).toList();
  if (content.isEmpty) return [];

  // Two titles are duplicates if their chapter timestamps all match within
  // chapTol (strongest signal), or — when no chapter data is available — their
  // duration matches within dupTol.
  bool areDuplicates(T a, T b) {
    if (chapterTimestamps != null) {
      final ach = chapterTimestamps(a);
      final bch = chapterTimestamps(b);
      if (ach.length >= 2 && ach.length == bch.length) {
        return ach.indexed.every((e) => (e.$2 - bch[e.$1]).abs() <= chapTol);
      }
    }
    return (duration(a) - duration(b)).abs() <= dupTol;
  }

  // 2. Group duplicates; keep the highest-scoring title per group.
  final groups = <List<T>>[];
  for (final t in content) {
    List<T>? match;
    for (final g in groups) {
      if (areDuplicates(g.first, t)) { match = g; break; }
    }
    if (match != null) {
      match.add(t);
    } else {
      groups.add([t]);
    }
  }

  final unique = <T>[
    for (final g in groups)
      (g..sort((a, b) => score(b).compareTo(score(a)))).first,
  ];

  // 3. Series detection.
  //
  // A disc is a series when the sum of "effective episodes" is ≥ 3, where a
  // single episode counts as 1 and a double episode (≈ 2× median) counts as 2.
  // This catches 2-episode discs where only a double-episode compilation is
  // also present (effective = 2+2 = 4).
  if (unique.length >= 3) {
    final secs   = unique.map((t) => duration(t).inSeconds).toList()..sort();
    final median = secs[(secs.length - 1) ~/ 2];
    final episodes = unique
        .where((t) => (duration(t).inSeconds - median).abs() <= median * 0.3)
        .toList();
    final doubleEps = unique.where((t) {
      final s = duration(t).inSeconds;
      return (s - median).abs() > median * 0.3 &&
             (s - 2 * median).abs() <= 2 * median * 0.3;
    }).toList();
    final effective = episodes.length + doubleEps.length * 2;
    if (effective >= 3 && episodes.isNotEmpty) {
      return [...episodes, ...doubleEps];
    }
  }

  // 4. Feature film: return only the longest unique track.
  return [unique.reduce((a, b) => duration(a) >= duration(b) ? a : b)];
}
