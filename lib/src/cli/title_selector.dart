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
  );
}

/// Selects likely episodes or the main feature from a DVD title list.
///
/// First looks for "coherent multi-angle groups": VTS sections where every
/// angle has a duration within ±3 minutes of the primary angle (pgcIndex 0).
/// When such groups exist they are ranked by stream quality and returned in
/// full (all angles).  If no coherent multi-angle group is found the function
/// falls back to the single-angle (pgcIndex 0) logic used by Blu-ray.
List<DvdTitle> autoSelectDvd(List<DvdTitle> titles) {
  const minDur   = Duration(minutes: 5);
  const angleTol = Duration(minutes: 3);

  // 1. Group all titles by VTS number.
  final byVts = <int, List<DvdTitle>>{};
  for (final t in titles) {
    byVts.putIfAbsent(t.vtsNumber, () => []).add(t);
  }

  // 2. Find coherent multi-angle groups.
  final coherent = <List<DvdTitle>>[];
  for (final group in byVts.values) {
    // Must have more than one angle and a primary (pgcIndex 0) that is long enough.
    if (group.length <= 1) continue;
    final primary = group.firstWhere(
      (t) => t.pgcIndex == 0,
      orElse: () => group.first,
    );
    if (primary.duration < minDur) continue;

    final primarySecs     = primary.duration.inSeconds;
    final primaryChapters = primary.chapters.length;
    final allCoherent = group.every((t) {
      if ((t.duration.inSeconds - primarySecs).abs() > angleTol.inSeconds) {
        return false;
      }
      // Chapter count must match the primary (ignore if either side has no data).
      if (primaryChapters > 0 && t.chapters.isNotEmpty &&
          t.chapters.length != primaryChapters) {
        return false;
      }
      return true;
    });
    if (!allCoherent) continue;

    coherent.add(group..sort((a, b) => a.pgcIndex.compareTo(b.pgcIndex)));
  }

  if (coherent.isNotEmpty) {
    int groupScore(List<DvdTitle> g) {
      final p = g.firstWhere((t) => t.pgcIndex == 0, orElse: () => g.first);
      return p.audioTracks.length + p.subtitleTracks.length;
    }
    Duration groupDur(List<DvdTitle> g) =>
        g.firstWhere((t) => t.pgcIndex == 0, orElse: () => g.first).duration;

    // 3a. Series detection across coherent groups.
    if (coherent.length >= 3) {
      final secs   = coherent.map((g) => groupDur(g).inSeconds).toList()..sort();
      final median = secs[secs.length ~/ 2];
      final episodeGroups = coherent
          .where((g) => (groupDur(g).inSeconds - median).abs() <= median * 0.3)
          .toList();
      if (episodeGroups.length >= 3) {
        return episodeGroups.expand((g) => g).toList();
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

  // 4. Fallback: single-angle logic, with chapter count as a scoring bonus.
  //
  // Compute the most common chapter count among long single-angle candidates.
  // Titles that share this count are more likely to be "real" episodes and get
  // a bonus in the stream-quality score used for deduplication and selection.
  final angle1 = titles
      .where((t) => t.pgcIndex == 0 && t.duration >= minDur)
      .toList();
  final chapterMode = _mode(angle1.map((t) => t.chapters.length));

  return _autoSelect(
    titles:            titles.where((t) => t.pgcIndex == 0).toList(),
    duration:          (t) => t.duration,
    score:             (t) =>
        t.audioTracks.length +
        t.subtitleTracks.length +
        (chapterMode != null && t.chapters.length == chapterMode ? 3 : 0),
    chapterTimestamps: (t) => t.chapters,
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns the most frequent value in [values], or null if [values] is empty.
T? _mode<T>(Iterable<T> values) {
  final counts = <T, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
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

  // Two titles are duplicates if their duration matches within dupTol, OR
  // their chapter timestamps all match within chapTol (stronger signal).
  bool areDuplicates(T a, T b) {
    if ((duration(a) - duration(b)).abs() <= dupTol) return true;
    if (chapterTimestamps != null) {
      final ach = chapterTimestamps(a);
      final bch = chapterTimestamps(b);
      if (ach.length >= 2 && ach.length == bch.length) {
        return ach.indexed.every(
          (e) => (e.$2 - bch[e.$1]).abs() <= chapTol,
        );
      }
    }
    return false;
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

  // 3. Series detection: ≥ 3 unique tracks within ±30 % of the median duration.
  if (unique.length >= 3) {
    final secs   = unique.map((t) => duration(t).inSeconds).toList()..sort();
    final median = secs[secs.length ~/ 2];
    final epCount = secs.where((s) => (s - median).abs() <= median * 0.3).length;
    if (epCount >= 3) return unique;
  }

  // 4. Feature film: return only the longest unique track.
  return [unique.reduce((a, b) => duration(a) >= duration(b) ? a : b)];
}
