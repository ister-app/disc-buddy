import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Computes the MusicBrainz disc ID from a list of track start times (in seconds).
///
/// Falls back to floating-point conversion; use [computeDiscIdFromOffsets]
/// when exact LBA sector addresses are available (more accurate).
String computeDiscId(List<double> startTimes, double leadOutTime) {
  // Convert seconds to CDDA frames (75 frames/second) + 150 offset
  final offsets = startTimes
      .map((t) => (t * 75).round() + 150)
      .toList();
  final leadOut = (leadOutTime * 75).round() + 150;
  return computeDiscIdFromOffsets(offsets, leadOut);
}

/// Computes the MusicBrainz disc ID directly from absolute LBA sector addresses.
///
/// [lbaOffsets] : one LBA per track (index 0 = track 1), including 150-sector pre-gap.
/// [leadOutLba] : absolute LBA of the lead-out, including 150-sector pre-gap.
///
/// Produces a more accurate ID than [computeDiscId] because no floating-point
/// rounding occurs.
String computeDiscIdFromOffsets(List<int> lbaOffsets, int leadOutLba) {
  final n   = lbaOffsets.length;
  final buf = StringBuffer();

  buf.write('01');                                               // first track
  buf.write(n.toRadixString(16).padLeft(2, '0').toUpperCase()); // last track
  buf.write(leadOutLba.toRadixString(16).padLeft(8, '0').toUpperCase());

  for (var i = 0; i < 99; i++) {
    final off = i < n ? lbaOffsets[i] : 0;
    buf.write(off.toRadixString(16).padLeft(8, '0').toUpperCase());
  }

  final hash = sha1.convert(utf8.encode(buf.toString())).bytes;
  return base64.encode(hash)
      .replaceAll('+', '.')
      .replaceAll('/', '_')
      .replaceAll('=', '-');
}
