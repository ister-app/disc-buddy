import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/disc_metadata.dart';

/// CDDB/GnuDB lookup service — fallback when MusicBrainz finds nothing.
///
/// Disc ID algorithm (FreeDB standard):
///   checksum = sum of the digits of floor(lba / 75) for each track
///   disc_len = floor(lead_out_lba / 75) − floor(track1_lba / 75)
///   id = ((checksum % 255) << 24) | (disc_len << 8) | num_tracks
class Cddb {
  static const _baseUrl   = 'https://gnudb.gnudb.org/~cddb/cddb.cgi';
  static const _hello     = 'user+localhost+DiscBuddy+1.0';
  static const _userAgent = 'DiscBuddy/1.0 (disc-buddy)';
  static const _timeout   = Duration(seconds: 15);

  // ---------------------------------------------------------------------------
  // Disc ID calculation
  // ---------------------------------------------------------------------------

  /// Computes the CDDB disc ID from LBA sector addresses.
  ///
  /// [lbaOffsets] : absolute LBA per track (index 0 = track 1, incl. 150-sector pre-gap).
  /// [leadOutLba] : absolute lead-out LBA.
  static String computeId(List<int> lbaOffsets, int leadOutLba) {
    int checksum = 0;
    for (final lba in lbaOffsets) {
      var t = lba ~/ 75;
      while (t > 0) { checksum += t % 10; t ~/= 10; }
    }
    final discLen = leadOutLba ~/ 75 - lbaOffsets.first ~/ 75;
    final id = ((checksum % 255) << 24) | (discLen << 8) | lbaOffsets.length;
    return id.toRadixString(16).padLeft(8, '0');
  }

  // ---------------------------------------------------------------------------
  // Lookup
  // ---------------------------------------------------------------------------

  /// Looks up metadata via GnuDB.
  ///
  /// [startTimes]  : track start times in seconds (from ffprobe).
  /// [leadOutTime] : lead-out time in seconds.
  static Future<DiscMetadata?> lookup(
    List<double> startTimes,
    double leadOutTime,
  ) async {
    // Compute LBA offsets (same as MusicBrainz lookup)
    final lbaOffsets = startTimes.map((t) => (t * 75).round() + 150).toList();
    final leadOutLba = (leadOutTime * 75).round() + 150;

    final discId  = computeId(lbaOffsets, leadOutLba);
    final n       = startTimes.length;
    final offsets = lbaOffsets.join('+');
    final nsecs   = leadOutLba ~/ 75 - lbaOffsets.first ~/ 75;

    stderr.writeln('CDDB: looking up disc ID $discId...');

    final queryUri = Uri.parse(
      '$_baseUrl?cmd=cddb+query+$discId+$n+$offsets+$nsecs'
      '&hello=$_hello&proto=6',
    );

    try {
      final resp = await http
          .get(queryUri, headers: {'User-Agent': _userAgent})
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        stderr.writeln('CDDB: error ${resp.statusCode}.');
        return null;
      }

      final lines = resp.body.split('\n');
      if (lines.isEmpty) return null;

      final code = int.tryParse(lines[0].length >= 3 ? lines[0].substring(0, 3) : '') ?? 0;

      if (code == 202) {
        stderr.writeln('CDDB: disc not found.');
        return null;
      }

      // 200: exact match       → genre id title  (on line 0 after the code)
      // 211: multiple exact matches → list after line 0
      // 210: multiple close matches
      String? genre, cddbId;
      if (code == 200) {
        final parts = lines[0].substring(4).trim().split(' ');
        if (parts.length >= 2) { genre = parts[0]; cddbId = parts[1]; }
      } else if (code == 211 || code == 210) {
        if (lines.length > 1) {
          final parts = lines[1].trim().split(' ');
          if (parts.length >= 2) { genre = parts[0]; cddbId = parts[1]; }
        }
      }

      if (genre == null || cddbId == null) return null;

      return _readEntry(genre, cddbId, startTimes, leadOutTime);
    } on TimeoutException {
      stderr.writeln('CDDB: timeout (>${_timeout.inSeconds}s).');
      return null;
    } catch (e) {
      stderr.writeln('CDDB: fetch error — $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Entry reading and parsing
  // ---------------------------------------------------------------------------

  static Future<DiscMetadata?> _readEntry(
    String genre,
    String cddbId,
    List<double> startTimes,
    double leadOutTime,
  ) async {
    final readUri = Uri.parse(
      '$_baseUrl?cmd=cddb+read+$genre+$cddbId'
      '&hello=$_hello&proto=6',
    );

    try {
      final resp = await http
          .get(readUri, headers: {'User-Agent': _userAgent})
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;

      final lines = resp.body.split('\n');
      final code  = int.tryParse(lines[0].length >= 3 ? lines[0].substring(0, 3) : '') ?? 0;
      if (code != 210) return null;

      // Parse key-value pairs (multi-line values are concatenated)
      final kv     = <String, String>{};
      final titles = <int, String>{};

      for (final line in lines.skip(1)) {
        final trimmed = line.trim();
        if (trimmed.startsWith('#') || trimmed == '.') continue;
        final eq = trimmed.indexOf('=');
        if (eq < 0) continue;
        final key = trimmed.substring(0, eq).trim();
        final val = trimmed.substring(eq + 1);

        if (key.startsWith('TTITLE')) {
          final idx = int.tryParse(key.substring(6)) ?? -1;
          if (idx >= 0) titles[idx] = (titles[idx] ?? '') + val;
        } else {
          kv[key] = (kv[key] ?? '') + val;
        }
      }

      // DTITLE = "Artist / Album" (or just album if no slash)
      final dtitle   = kv['DTITLE'] ?? '';
      final slashIdx = dtitle.indexOf(' / ');
      final artist   = slashIdx >= 0 ? dtitle.substring(0, slashIdx).trim() : '';
      final album    = slashIdx >= 0 ? dtitle.substring(slashIdx + 3).trim() : dtitle.trim();
      final year     = kv['DYEAR'] ?? '';

      final n      = startTimes.length;
      final tracks = List.generate(n, (i) {
        final raw   = titles[i] ?? '';
        final slash = raw.indexOf(' / ');
        final trackArtist = slash >= 0 ? raw.substring(0, slash).trim() : '';
        final trackTitle  = slash >= 0 ? raw.substring(slash + 3).trim() : raw.trim();
        final endTime     = i + 1 < n ? startTimes[i + 1] : leadOutTime;

        return TrackInfo(
          number:        i + 1,
          title:         trackTitle.isNotEmpty
              ? trackTitle
              : 'track_${(i + 1).toString().padLeft(2, '0')}',
          artist:        trackArtist,
          artistMbid:    '',
          recordingMbid: '',
          startTime:     startTimes[i],
          endTime:       endTime,
        );
      });

      if (tracks.isEmpty) return null;

      stderr.writeln('CDDB: found — $artist / $album');

      return DiscMetadata(
        album:  album.isNotEmpty ? album : 'Unknown album',
        artist: artist,
        date:   year,
        tracks: tracks,
      );
    } on TimeoutException {
      stderr.writeln('CDDB: timeout reading entry.');
      return null;
    } catch (e) {
      stderr.writeln('CDDB: read error — $e');
      return null;
    }
  }
}
