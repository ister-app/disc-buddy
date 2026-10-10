import '../models/bluray_title.dart';
import '../models/dvd_title.dart';
import '../models/video_title.dart';

/// Median of an already-ascending-sorted, non-empty list of seconds.
/// For an even count, returns the average of the two central values rather than
/// the lower-middle element, so an outlier (e.g. a long "play-all" track mixed
/// in with episodes) doesn't skew the value low.
int _median(List<int> sortedSecs) {
  final n = sortedSecs.length;
  if (n == 0) return 0;
  if (n.isOdd) return sortedSecs[n ~/ 2];
  return (sortedSecs[n ~/ 2 - 1] + sortedSecs[n ~/ 2]) ~/ 2;
}

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
  //
  // Also handles the reverse layout: if the compilation is stored at a
  // non-zero pgcIndex while pgcIndex 0 is itself an episode-length PGC,
  // include pgcIndex 0 among the returned episodes and discard the
  // non-primary compilation angle.
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

    // If pgcIndex 0 is a short menu stub (< minDur) and there are enough
    // episode-like non-primary angles, treat it as the menu-stub variant of
    // the compilation pattern; otherwise require the primary to be real content.
    final primaryIsStub = primary.duration < minDur;

    if (primaryIsStub && others.length < 3) continue;

    final otherSecs = others.map((t) => t.duration.inSeconds).toList()..sort();
    final median    = _median(otherSecs);
    if (median == 0) continue;

    // Non-primary angles must be coherent amongst themselves.
    // Double-episode PGCs (≈ 2× median) are tolerated: some discs pack one
    // two-episode entry alongside single episodes in the same VTS.
    // Split others into episode-like and compilation-like: if a non-primary
    // angle is much longer than the median it may itself be the play-all
    // compilation rather than an individual episode.
    bool isEpLike(DvdTitle t) {
      final diff  = (t.duration.inSeconds - median).abs();
      if (diff <= median * 0.3) return true;
      final diff2 = (t.duration.inSeconds - 2 * median).abs();
      return diff2 <= 2 * median * 0.3;
    }
    final epOthers   = others.where(isEpLike).toList();
    final compOthers = others.where(
        (t) => !isEpLike(t) && t.duration.inSeconds > median * 1.5).toList();
    if (epOthers.length < 2) continue;

    if (primary.duration.inSeconds >= median * 1.5) {
      // Original case: pgcIndex 0 is the compilation.
      compilationEps.addAll(
        epOthers..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex)),
      );
    } else if (compOthers.isNotEmpty && isEpLike(primary)) {
      // A non-primary angle is the compilation; primary is also an episode.
      compilationEps.addAll(
        ([primary, ...epOthers]
          ..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex))),
      );
    } else if (primaryIsStub && compOthers.isNotEmpty && epOthers.length >= 2) {
      // pgcIndex 0 is a menu stub; the compilation is a non-primary angle and
      // the individual episodes are the remaining non-primary angles.
      compilationEps.addAll(
        epOthers..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex)),
      );
    }
  }
  if (compilationEps.isNotEmpty) {
    // Also pick up standalone episodes from other VTS groups that have a
    // similar duration and at least as many streams.  Some discs store most
    // episodes as angles inside a single VTS (caught above) but keep one or
    // more episodes in separate VTS sections — sometimes with an extra audio
    // track (e.g. a commentary) that breaks the strict stream-count filter
    // used in the fallback path.
    final epSecs     = compilationEps.map((t) => t.duration.inSeconds).toList()..sort();
    final epMedian   = _median(epSecs);
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
      final median = _median(secs);
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
  final bySub       = targetSub != null
      ? byAudio.where((t) => t.subtitleTracks.length == targetSub).toList()
      : byAudio;

  // Re-admit titles the stream-count filter dropped when their duration fits
  // the surviving group (±30 % of its median, or a ≈ 2× double episode).  An
  // episode that merely lacks a subtitle track on this disc is still an
  // episode; the filter only has to keep out short, stripped-down extras.
  final filtered = <DvdTitle>[...bySub];
  if (bySub.isNotEmpty) {
    final secs   = bySub.map((t) => t.duration.inSeconds).toList()..sort();
    final median = _median(secs);
    bool fits(DvdTitle t) {
      final s = t.duration.inSeconds;
      return (s - median).abs() <= median * 0.3 ||
             (s - 2 * median).abs() <= 2 * median * 0.3;
    }
    filtered.addAll(angle1.where((t) => !bySub.contains(t) && fits(t)));
  }

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

/// Minimum fraction of BOTH titles' merged cell unions that must be shared
/// before two PGCs are considered the same physical content.  Requiring the
/// overlap on both sides prevents a play-all PGC (which fully contains each
/// episode's sectors but shares only ~1/N of its own) from being merged with
/// an individual episode.
const _cellOverlapThreshold = 0.8;

/// Sorts and merges possibly-overlapping cell ranges into disjoint intervals.
/// Adjacent ranges are treated as contiguous; degenerate entries
/// (last < first) are dropped.
List<({int first, int last})> _mergeCells(List<({int first, int last})> cells) {
  final valid = cells.where((c) => c.last >= c.first).toList()
    ..sort((a, b) => a.first.compareTo(b.first));
  final merged = <({int first, int last})>[];
  for (final c in valid) {
    if (merged.isNotEmpty && c.first <= merged.last.last + 1) {
      final prev = merged.removeLast();
      merged.add((first: prev.first, last: c.last > prev.last ? c.last : prev.last));
    } else {
      merged.add(c);
    }
  }
  return merged;
}

/// Total sector count of a merged (disjoint, sorted) interval list.
int _intervalSize(List<({int first, int last})> merged) =>
    merged.fold(0, (sum, c) => sum + (c.last - c.first + 1));

/// Sectors common to two merged (disjoint, sorted) interval lists.
int _intervalIntersection(
    List<({int first, int last})> a, List<({int first, int last})> b) {
  var overlap = 0;
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final lo = a[i].first > b[j].first ? a[i].first : b[j].first;
    final hi = a[i].last < b[j].last ? a[i].last : b[j].last;
    if (hi >= lo) overlap += hi - lo + 1;
    if (a[i].last < b[j].last) {
      i++;
    } else {
      j++;
    }
  }
  return overlap;
}

/// Tri-state verdict from cell sector data: true = same physical content
/// (overlap ≥ [_cellOverlapThreshold] of BOTH merged unions), false =
/// different content, null = unusable cell data on either side (no cells or
/// zero-size union) — the caller must fall back to chapter/duration logic.
///
/// Only valid within a single VTS: cell sectors are VTS-VOB-relative and not
/// comparable across VTS boundaries.
bool? _cellsShareContent(DvdTitle a, DvdTitle b) {
  final ma = _mergeCells(a.cells);
  final mb = _mergeCells(b.cells);
  final sa = _intervalSize(ma);
  final sb = _intervalSize(mb);
  if (sa == 0 || sb == 0) return null;
  final inter = _intervalIntersection(ma, mb);
  return inter >= sa * _cellOverlapThreshold &&
         inter >= sb * _cellOverlapThreshold;
}

/// Returns a deduplicated list of [titles] where:
///
/// 1. Cross-VTS groups that represent the same episode (DVD navigation
///    artifact) are collapsed to their first occurrence.
/// 2. Within each surviving VTS group, angles that reference the same physical
///    sectors as the primary angle (pgcIndex 0) are removed — they are true
///    camera-angle or navigation duplicates.  Cell sector overlap is the
///    authoritative signal: PGCs with disjoint cells store different episode
///    content in the angle slots and are always kept, even when their chapter
///    layout happens to match (discs authored with fixed-interval chapters).
///    Chapter timestamps (±2 s) and duration (±1 s) are only consulted when
///    cell data is unavailable.
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

  // Returns true if [other] is a true camera-angle duplicate of [primary]:
  // same content recorded from a different angle.  Cell sector overlap is the
  // authoritative signal (both PGCs live in the same VTS, so their sectors are
  // directly comparable); chapter timestamps and duration (within 1 s) are
  // fallbacks when no cell data is available.
  bool isCameraAngleDuplicate(DvdTitle primary, DvdTitle other) {
    final byCells = _cellsShareContent(primary, other);
    if (byCells != null) return byCells;
    final pc = primary.chapters;
    final oc = other.chapters;
    if (pc.length >= 2 && pc.length == oc.length) {
      return pc.indexed.every((e) => (e.$2 - oc[e.$1]).abs() <= chapTol);
    }
    return (primary.duration.inSeconds - other.duration.inSeconds).abs() <= 1;
  }

  final seen = <List<DvdTitle>>[];
  for (final entry in groups) {
    final group = entry.value;
    if (!seen.any((s) => isDuplicate(s, group))) seen.add(group);
  }

  return seen.expand((g) {
    g.sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex));
    final primary = g.firstWhere((t) => t.pgcIndex == 0, orElse: () => g.first);
    return g.where(
      (t) => t.pgcIndex == 0 || !isCameraAngleDuplicate(primary, t),
    );
  }).toList();
}

// ---------------------------------------------------------------------------
// Display filter
// ---------------------------------------------------------------------------

/// Titles shorter than this are treated as minor clips (menu loops, stingers,
/// promo spots) and hidden from the default list.  Matches MakeMKV's
/// `minlength` default, so both tools present the same set out of the box.
const minorTitleDuration = Duration(seconds: 120);

/// Returns the display keys of the titles in [all] that are hidden by default:
/// shorter than [minorTitleDuration] and not part of [suggestion].
///
/// Nothing is removed from the list — the caller decides whether to show these
/// keys, so a hidden title always stays reachable (unlike a hard filter).
Set<String> minorTitleKeys(
    List<VideoTitle> all, List<VideoTitle> suggestion) {
  final suggested = suggestion.map((t) => t.displayKey).toSet();
  return all
      .where((t) =>
          t.duration < minorTitleDuration && !suggested.contains(t.displayKey))
      .map((t) => t.displayKey)
      .toSet();
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
    final median = _median(secs);
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
