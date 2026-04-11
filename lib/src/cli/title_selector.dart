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
    titles:   titles,
    duration: (t) => t.duration,
    score:    (t) => t.audioCount + t.subtitleCount,
  );
}

/// Selects likely episodes or the main feature from a DVD title list.
///
/// Only considers angle-1 titles (pgcIndex == 0).
/// See [autoSelectBluray] for the selection rules.
List<DvdTitle> autoSelectDvd(List<DvdTitle> titles) {
  return _autoSelect(
    titles:   titles.where((t) => t.pgcIndex == 0).toList(),
    duration: (t) => t.duration,
    score:    (t) => t.audioTracks.length + t.subtitleTracks.length,
  );
}

// ---------------------------------------------------------------------------
// Shared core logic
// ---------------------------------------------------------------------------

List<T> _autoSelect<T>({
  required List<T> titles,
  required Duration Function(T) duration,
  required int Function(T) score,
}) {
  const minDur = Duration(minutes: 5);
  const dupTol = Duration(seconds: 5);

  // 1. Filter tracks that are too short to be real content.
  final content = titles.where((t) => duration(t) >= minDur).toList();
  if (content.isEmpty) return [];

  // 2. Group by approximately equal duration; keep the best per group.
  final groups = <List<T>>[];
  for (final t in content) {
    final d = duration(t);
    List<T>? match;
    for (final g in groups) {
      if ((duration(g.first) - d).abs() <= dupTol) { match = g; break; }
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
