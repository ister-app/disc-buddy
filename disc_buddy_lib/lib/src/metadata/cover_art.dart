import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CoverArt {
  static const _userAgent = 'DiscBuddy/1.0 (disc-buddy)';
  static const _timeout = Duration(seconds: 15);

  /// Fetches the front cover art from the Cover Art Archive.
  /// Returns null if not found or on error.
  static Future<Uint8List?> fetchFront(String releaseMbid) async {
    final uri = Uri.parse(
        'https://coverartarchive.org/release/$releaseMbid/front');
    try {
      final resp = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(_timeout);
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        return resp.bodyBytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
