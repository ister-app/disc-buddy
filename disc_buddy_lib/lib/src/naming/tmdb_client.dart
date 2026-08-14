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
  int?   runtime,    // minutes, null when TMDB has none
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

  // TMDB accepts two credential types: v4 read access tokens (long JWTs, which
  // contain '.') sent as a Bearer header, and v3 API keys (32-char hex) sent
  // as an `api_key` query param. Send ONLY the matching mechanism — passing a
  // v4 JWT as `api_key=` (or vice-versa) is malformed and also leaks the token
  // into request URLs/logs.
  bool get _isV4Token => token.contains('.');

  Map<String, String> get _headers =>
      _isV4Token ? {'Authorization': 'Bearer $token'} : const {};

  Map<String, String> _params(Map<String, String> extra) =>
      _isV4Token ? extra : {'api_key': token, ...extra};

  /// GETs [path] (relative to [_base]) with [params], retrying once on HTTP 429
  /// (honouring `Retry-After`). Returns the decoded JSON object, or null on
  /// error / non-200 — non-200s are logged with their status code instead of
  /// being silently treated as "no results".
  Future<Map<String, dynamic>?> _get(
    String path,
    Map<String, String> params,
  ) async {
    final uri =
        Uri.parse('$_base$path').replace(queryParameters: _params(params));
    for (var attempt = 0; attempt < 2; attempt++) {
      final response =
          await _http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        return decoded is Map<String, dynamic> ? decoded : null;
      }
      if (response.statusCode == 429 && attempt == 0) {
        final retryAfter =
            (int.tryParse(response.headers['retry-after'] ?? '') ?? 1).clamp(1, 10);
        _log('   TMDB rate-limited (429); retrying in ${retryAfter}s…',
            isError: true);
        await Future<void>.delayed(Duration(seconds: retryAfter));
        continue;
      }
      _log('   TMDB request failed (${response.statusCode}) for $path',
          isError: true);
      return null;
    }
    return null;
  }

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
      final body = await _get('/search/movie', {
        'query': query,
        if (year != null) 'year': '$year',
      });
      if (body == null) return [];
      final results = (body['results'] as List?) ?? [];
      return results
          .map((r) => r as Map<String, dynamic>)
          .where((m) => m['id'] is num)
          .take(limit)
          .map<MovieCandidate>((m) {
        final y = int.tryParse(
            (m['release_date'] as String? ?? '').split('-').first);
        return (
          id:       (m['id'] as num).toInt(),
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
      final body = await _get('/search/tv', {'query': query});
      if (body == null) return [];
      final results = (body['results'] as List?) ?? [];
      return results
          .map((r) => r as Map<String, dynamic>)
          .where((m) => m['id'] is num)
          .take(limit)
          .map<TvCandidate>((m) {
        final y = int.tryParse(
            (m['first_air_date'] as String? ?? '').split('-').first);
        return (
          id:           (m['id'] as num).toInt(),
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
      final body = await _get('/tv/$seriesId', {});
      if (body == null) return null;
      final n = (body['number_of_seasons'] as num?)?.toInt();
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
    // separately. The v2 suffix invalidates pre-runtime caches.
    final cacheFile = 'tmdb_${seriesId}_s${season}_${language}_v2.json';
    final cached = await _readCache(cacheFile);
    if (cached != null) {
      final eps = (cached['episodes'] as List?) ?? [];
      return eps
          .where((e) => e['number'] is num)
          .map((e) => (
                number:     (e['number']    as num).toInt(),
                title:      e['title']      as String? ?? '',
                overview:   e['overview']   as String? ?? '',
                guestStars: e['guestStars'] as String? ?? '',
                airDate:    e['airDate']    as String? ?? '',
                runtime:    (e['runtime']   as num?)?.toInt(),
              ))
          .toList();
    }

    try {
      final body = await _get('/tv/$seriesId/season/$season', {'language': language});
      if (body == null) return [];
      final rawEps = (body['episodes'] as List?) ?? [];
      final episodes = rawEps
          .where((e) => e['episode_number'] is num)
          .map<EpisodeInfo>((e) {
        final guests = (e['guest_stars'] as List? ?? [])
            .take(6)
            .map((g) => (g['character'] as String? ?? '').trim())
            .where((s) => s.isNotEmpty)
            .join(', ');
        return (
          number:     (e['episode_number'] as num).toInt(),
          title:      e['name']           as String? ?? '',
          overview:   e['overview']       as String? ?? '',
          guestStars: guests,
          airDate:    e['air_date']       as String? ?? '',
          runtime:    (e['runtime']       as num?)?.toInt(),
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
                  'runtime':    e.runtime,
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
