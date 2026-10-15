import 'dart:io';

import 'tmdb_client.dart';

/// LLM-extracted summary used for title resolution and episode matching.
class Fingerprint {
  final String summary;
  final String titleGuess; // probable show / movie name (for TMDB search)

  const Fingerprint({required this.summary, required this.titleGuess});

  static const Fingerprint empty = Fingerprint(summary: '', titleGuess: '');

  bool get isEmpty => summary.isEmpty && titleGuess.isEmpty;
}

/// Role of one file among several cuts of the same episode.
/// See `classifyVersions` in episode_math.dart.
enum VersionRole { primary, extended, leaveUnnamed }

/// One TMDB episode together with its season number.
typedef SeasonEpisode = ({int season, EpisodeInfo ep});

/// One file to be named, with the disc it came from and any sidecar SRTs.
typedef NamingItem = ({File file, String discName, List<File> srts});

/// Subtitle (or transcript) text plus its ISO 639-1 language.
typedef SubtitleText = ({String text, String language});

/// Log sink shared by the naming collaborators.
typedef NamingLog = void Function(String msg, {bool isError});

class TitleCandidate {
  final int id;
  final String title;
  final int? year;
  final String overview;
  final String type;

  TitleCandidate({
    required this.id,
    required this.title,
    required this.year,
    required this.overview,
    required this.type,
  });

  factory TitleCandidate.movie(MovieCandidate m) => TitleCandidate(
    id: m.id,
    title: m.title,
    year: m.year,
    overview: m.overview,
    type: 'movie',
  );

  factory TitleCandidate.tv(TvCandidate t) => TitleCandidate(
    id: t.id,
    title: t.name,
    year: t.firstAirYear,
    overview: t.overview,
    type: 'series',
  );
}

class TitlePick {
  final String type;
  final int id;
  final String label;
  final int? year;

  TitlePick({
    required this.type,
    required this.id,
    required this.label,
    this.year,
  });
}

class EpisodePick {
  final String stem;
  final String title;
  final int season;
  final int ep;
  /// Last episode covered by this file; equals [ep] for single episodes.
  final int epEnd;

  EpisodePick({
    required this.stem,
    required this.title,
    required this.season,
    required this.ep,
    int? epEnd,
  }) : epEnd = epEnd ?? ep;
}

class ScoredCandidate {
  final int id;
  final String type;
  final String label;
  final double score;
  final String reason;

  ScoredCandidate({
    required this.id,
    required this.type,
    required this.label,
    required this.score,
    required this.reason,
  });
}
