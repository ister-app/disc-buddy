import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../utils/xdg.dart';

/// Per-episode metadata returned by [TmdbClient.getSeasonEpisodes].
typedef EpisodeInfo = ({
  int    number,
  String title,
  String overview,
  String guestStars, // comma-separated character names, may be empty
  String airDate,    // "YYYY-MM-DD" or empty
});

/// A candidate returned by [TmdbClient.searchMovieCandidates].
typedef MovieCandidate = ({
  int    id,
  String title,
  int?   year,
  String overview,
});

/// A candidate returned by [TmdbClient.searchTvCandidates].
typedef TvCandidate = ({
  int    id,
  String name,
  int?   firstAirYear,
  String overview,
});

class TmdbClient {
  static const _base = 'https://api.themoviedb.org/3';
  static const _cacheTtl = Duration(days: 7);

  final String token;
  final http.Client _http;
  final void Function(String, {bool isError})? onLog;

  TmdbClient({required this.token, http.Client? httpClient, this.onLog})
      : _http = httpClient ?? http.Client();

  void close() => _http.close();

  void _log(String msg, {bool isError = false}) {
    if (onLog != null) {
      onLog!(msg, isError: isError);
    } else {
      stderr.writeln(msg);
    }
  }

  // Bearer header for v4 read access tokens; api_key param for v3 API keys.
  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};
  Map<String, String> _params(Map<String, String> extra) =>
      {'api_key': token, ...extra};

  static String get _cacheDir => '${xdgCacheHome()}/disc-buddy';

  bool _isCacheValid(Map<String, dynamic> cached) {
    final cachedAt = DateTime.tryParse(cached['cachedAt'] as String? ?? '');
    if (cachedAt == null) return false;
    return DateTime.now().difference(cachedAt) < _cacheTtl;
  }

  Future<Map<String, dynamic>?> _readCache(String filename) async {
    final file = File('$_cacheDir/$filename');
    if (!await file.exists()) return null;
    try {
      final parsed = jsonDecode(await file.readAsString());
      if (parsed is! Map<String, dynamic>) return null;
      if (!_isCacheValid(parsed)) return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String filename, Map<String, dynamic> data) async {
    try {
      final dir = Directory(_cacheDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final payload = {'cachedAt': DateTime.now().toIso8601String(), ...data};
      await File('$_cacheDir/$filename').writeAsString(jsonEncode(payload));
    } catch (_) {}
  }

  /// Returns up to [limit] movie candidates for [query], ranked by TMDB
  /// relevance. Empty list on error.
  Future<List<MovieCandidate>> searchMovieCandidates(
    String query, {
    int? year,
    int limit = 5,
  }) async {
    try {
      final uri =
          Uri.parse('$_base/search/movie').replace(queryParameters: _params({
        'query': query,
        if (year != null) 'year': '$year',
      }));
      final response = await _http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];
      final results =
          (jsonDecode(response.body)['results'] as List?) ?? [];
      return results.take(limit).map<MovieCandidate>((r) {
        final m = r as Map<String, dynamic>;
        final y = int.tryParse(
            (m['release_date'] as String? ?? '').split('-').first);
        return (
          id:       m['id']       as int,
          title:    m['title']    as String? ?? '',
          year:     y,
          overview: m['overview'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      _log('   TMDB movie search error: $e', isError: true);
      return [];
    }
  }

  /// Returns up to [limit] TV series candidates for [query]. Empty on error.
  Future<List<TvCandidate>> searchTvCandidates(
    String query, {
    int limit = 5,
  }) async {
    try {
      final uri = Uri.parse('$_base/search/tv')
          .replace(queryParameters: _params({'query': query}));
      final response = await _http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];
      final results =
          (jsonDecode(response.body)['results'] as List?) ?? [];
      return results.take(limit).map<TvCandidate>((r) {
        final m = r as Map<String, dynamic>;
        final y = int.tryParse(
            (m['first_air_date'] as String? ?? '').split('-').first);
        return (
          id:           m['id']       as int,
          name:         m['name']     as String? ?? '',
          firstAirYear: y,
          overview:     m['overview'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      _log('   TMDB TV search error: $e', isError: true);
      return [];
    }
  }

  /// Returns (title, releaseYear) for the best-matching movie, or null.
  Future<(String title, int year)?> searchMovie(String query,
      {int? year}) async {
    final candidates = await searchMovieCandidates(query, year: year, limit: 1);
    if (candidates.isEmpty) return null;
    final c = candidates.first;
    return (c.title, c.year ?? 0);
  }

  /// Returns (seriesId, seriesName) for the best-matching TV show, or null.
  Future<(int id, String name)?> searchTv(String query) async {
    final candidates = await searchTvCandidates(query, limit: 1);
    if (candidates.isEmpty) return null;
    final c = candidates.first;
    return (c.id, c.name);
  }

  /// Returns the number of seasons for a TV series, or null on error.
  /// Result is cached for one week.
  Future<int?> getNumberOfSeasons(int seriesId) async {
    final cacheFile = 'tmdb_${seriesId}_details.json';
    final cached = await _readCache(cacheFile);
    if (cached != null) {
      return cached['numberOfSeasons'] as int?;
    }

    try {
      final uri = Uri.parse('$_base/tv/$seriesId')
          .replace(queryParameters: _params({}));
      final response = await _http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final n = body['number_of_seasons'] as int?;
      if (n != null) await _writeCache(cacheFile, {'numberOfSeasons': n});
      return n;
    } catch (e) {
      _log('   TMDB series details error: $e', isError: true);
      return null;
    }
  }

  /// Returns all episodes across all seasons tagged with their season number.
  Future<List<({int season, EpisodeInfo ep})>> getAllEpisodes(
    int seriesId, {
    String language = 'en',
  }) async {
    final numSeasons = await getNumberOfSeasons(seriesId);
    if (numSeasons == null || numSeasons == 0) return [];

    final all = <({int season, EpisodeInfo ep})>[];
    for (var s = 1; s <= numSeasons; s++) {
      final eps = await _getEpisodesCached(seriesId, s, language: language);
      all.addAll(eps.map((e) => (season: s, ep: e)));
    }
    return all;
  }

  /// Returns the episode list for a single season (cached one week).
  /// [language] is an ISO 639-1 code (e.g. `"nl"`, `"en"`); TMDB will return
  /// titles, overviews, and guest-character names in that language where
  /// available, falling back to English.
  Future<List<EpisodeInfo>> getSeasonEpisodes(
    int seriesId,
    int season, {
    String language = 'en',
  }) =>
      _getEpisodesCached(seriesId, season, language: language);

  /// Returns the episode list for the given series and season, using a
  /// one-week cache in the XDG cache directory.
  Future<List<EpisodeInfo>> _getEpisodesCached(
    int seriesId,
    int season, {
    String language = 'en',
  }) async {
    // Language is part of the cache key so Dutch and English results are stored
    // separately.
    final cacheFile = 'tmdb_${seriesId}_s${season}_$language.json';
    final cached = await _readCache(cacheFile);
    if (cached != null) {
      final eps = (cached['episodes'] as List?) ?? [];
      return eps
          .map((e) => (
                number:     e['number']     as int,
                title:      e['title']      as String? ?? '',
                overview:   e['overview']   as String? ?? '',
                guestStars: e['guestStars'] as String? ?? '',
                airDate:    e['airDate']    as String? ?? '',
              ))
          .toList();
    }

    try {
      final uri = Uri.parse('$_base/tv/$seriesId/season/$season')
          .replace(queryParameters: _params({'language': language}));
      final response = await _http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return [];
      final rawEps =
          (jsonDecode(response.body)['episodes'] as List?) ?? [];
      final episodes = rawEps.map<EpisodeInfo>((e) {
        final guests = (e['guest_stars'] as List? ?? [])
            .take(6)
            .map((g) => (g['character'] as String? ?? '').trim())
            .where((s) => s.isNotEmpty)
            .join(', ');
        return (
          number:     e['episode_number'] as int,
          title:      e['name']           as String? ?? '',
          overview:   e['overview']       as String? ?? '',
          guestStars: guests,
          airDate:    e['air_date']       as String? ?? '',
        );
      }).toList();

      await _writeCache(cacheFile, {
        'episodes': episodes
            .map((e) => {
                  'number':     e.number,
                  'title':      e.title,
                  'overview':   e.overview,
                  'guestStars': e.guestStars,
                  'airDate':    e.airDate,
                })
            .toList(),
      });
      return episodes;
    } catch (e) {
      _log('   TMDB episodes error (s$season): $e', isError: true);
      return [];
    }
  }
}
