import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/disc_metadata.dart';
import '../utils/sanitize.dart';

class MusicBrainz {
  static const _userAgent = 'DiscBuddy/1.0 (disc-buddy)';
  static const _timeout = Duration(seconds: 10);

  /// Looks up release metadata by disc ID.
  /// Returns null if nothing is found or on network error.
  static Future<DiscMetadata?> lookup(
    String discId,
    List<double> startTimes,
    double leadOutTime,
  ) async {
    stderr.writeln('MusicBrainz: looking up disc ID $discId...');
    final uri = Uri.parse(
      'https://musicbrainz.org/ws/2/discid/$discId'
      '?fmt=json&inc=recordings+artist-credits+labels',
    );
    try {
      final resp = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(_timeout);
      if (resp.statusCode == 404) {
        stderr.writeln('MusicBrainz: disc not found (404).');
        return null;
      }
      if (resp.statusCode != 200) {
        stderr.writeln('MusicBrainz: error ${resp.statusCode}.');
        return null;
      }
      final Map<String, dynamic> data;
      try {
        data = jsonDecode(resp.body) as Map<String, dynamic>;
      } on FormatException {
        final snippet = resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body;
        stderr.writeln('MusicBrainz: invalid JSON — $snippet');
        return null;
      }
      final result = _parseResponse(data, discId, startTimes.length);
      if (result == null) {
        stderr.writeln('MusicBrainz: no usable release found.');
      }
      return result;
    } on TimeoutException {
      stderr.writeln('MusicBrainz: timeout (>${_timeout.inSeconds}s).');
      return null;
    } catch (e) {
      stderr.writeln('MusicBrainz: fetch error — $e');
      return null;
    }
  }

  static DiscMetadata? _parseResponse(
    Map<String, dynamic> data,
    String discId,
    int trackCount,
  ) {
    var releases = data['releases'] as List? ?? [];
    if (releases.isEmpty && data.containsKey('title')) {
      releases = [data];
    }
    if (releases.isEmpty) return null;

    // Pick the release + medium whose medium matching this disc ID has the
    // correct track count. First exact match wins; otherwise first disc match.
    Map<String, dynamic> rel = releases.first as Map<String, dynamic>;
    Map<String, dynamic>? matchedMed;

    outer:
    for (final r in releases.cast<Map<String, dynamic>>()) {
      final media = r['media'] as List? ?? [];
      for (final m in media.cast<Map<String, dynamic>>()) {
        final discs = m['discs'] as List? ?? [];
        if (!discs.any((d) => (d as Map)['id'] == discId)) continue;
        final nTracks = (m['tracks'] as List? ?? []).length;
        if (matchedMed == null) { rel = r; matchedMed = m; }
        if (nTracks == trackCount) { rel = r; matchedMed = m; break outer; }
      }
    }

    final mbid  = rel['id'] as String? ?? '';
    final album = sanitizeFilename(rel['title'] as String? ?? '');
    final date  = ((rel['date'] ?? rel['first-release-date']) as String? ?? '').take(4);

    final credits    = rel['artist-credit'] as List? ?? [];
    final artist     = _creditsToString(credits);
    final artistMbid = credits
        .whereType<Map>()
        .map((c) => (c['artist'] as Map?)?['id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .join(';');

    final labelInfo  = rel['label-info'] as List? ?? [];
    final firstLabel = labelInfo.isNotEmpty ? labelInfo.first as Map<String, dynamic> : null;
    final label      = sanitizeFilename((firstLabel?['label'] as Map?)?['name'] as String? ?? '');
    final catalogNr  = sanitizeFilename(firstLabel?['catalog-number'] as String? ?? '');

    final media      = rel['media'] as List? ?? [];
    final totalDiscs = media.length;

    int discNumber = 0;
    final tracks   = <TrackInfo>[];

    // Use the matched medium, or search all media if no match was found.
    final medsToSearch = matchedMed != null ? [matchedMed] : media.cast<Map<String, dynamic>>();
    for (final med in medsToSearch) {
      discNumber = (med['position'] as int?) ?? 0;
      final medTracks = med['tracks'] as List? ?? [];
      for (final (i, tr) in medTracks.cast<Map<String, dynamic>>().indexed) {
        final rec          = tr['recording'] as Map<String, dynamic>? ?? {};
        final title        = sanitizeFilename((tr['title'] ?? rec['title'] as String? ?? '') as String);
        final trCredits    = (tr['artist-credit'] ?? rec['artist-credit'] as List? ?? []) as List;
        final trArtist     = _creditsToString(trCredits);
        final trArtistMbid = trCredits
            .whereType<Map>()
            .map((c) => (c['artist'] as Map?)?['id'] as String? ?? '')
            .where((id) => id.isNotEmpty)
            .join(';');
        tracks.add(TrackInfo(
          number: i + 1,
          title: title.isNotEmpty ? title : 'track_${(i + 1).toString().padLeft(2, '0')}',
          artist: trArtist,
          artistMbid: trArtistMbid,
          recordingMbid: rec['id'] as String? ?? '',
          startTime: 0,
          endTime: 0,
        ));
      }
      if (matchedMed != null) break; // only one medium needed
    }

    if (tracks.isEmpty) return null;

    return DiscMetadata(
      album: album.isNotEmpty ? album : 'Unknown album',
      artist: artist,
      artistMbid: artistMbid,
      date: date,
      releaseMbid: mbid,
      label: label,
      catalogNumber: catalogNr,
      discNumber: discNumber,
      totalDiscs: totalDiscs,
      tracks: tracks,
    );
  }

  static String _creditsToString(List credits) {
    return sanitizeFilename(credits.whereType<Map>().map((c) {
      final name = (c['name'] ?? (c['artist'] as Map?)?['name'] ?? '') as String;
      final join = (c['joinphrase'] ?? '') as String;
      return name + join;
    }).join());
  }
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
