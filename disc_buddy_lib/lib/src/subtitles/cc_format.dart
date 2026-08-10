import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Layout of a CC payload inside an MPEG-2 user_data packet.
///
/// All offsets are relative to the start of the payload (the byte after the
/// `00 00 01 B2` start code). [scteStyle] selects the cc_count encoding:
/// `(byte >> 1) & 0x1F` (SCTE-20/A53 packed byte) vs `byte & 0x7F` (plain).
typedef CcPayloadLayout = ({
  int countOffset,
  bool scteStyle,
  int tripleStart,
  int ccCount,
});

/// Upper bound on a CC user_data payload in bytes. Real packets carry at most
/// 31 triples plus a small header (~100 bytes); the cap bounds forward scans.
const int maxCcPayloadLen = 200;

/// Detects the cc-triple run in an MPEG-2 user_data payload.
///
/// [start]..[end] (exclusive) delimit the payload within [data] — the bytes
/// AFTER the `00 00 01 B2` start code. Returns null when the payload does not
/// contain EIA-608/A53 cc_data.
///
/// Recognition is two-tier:
///  1. Known signatures ("CC" DVS-053/SCTE-20 and "GA94" ATSC A/53) are parsed
///     exactly, preserving historic behavior.
///  2. A structural fallback accepts signature-less variants (some SD-DVD
///     encoders emit `00 00 00 00` + count + triples): a count byte followed by
///     exactly that many 3-byte triples whose type bytes are all 0xFC–0xFF and
///     whose EIA-608 data bytes carry odd parity. This avoids needing a new
///     hard-coded signature for every disc.
CcPayloadLayout? detectCcPayload(List<int> data, int start, int end) {
  final payloadLen = end - start;
  if (payloadLen < 4) return null;

  // -- Tier 1: known signatures ---------------------------------------------
  int? countOffset;
  bool scteStyle = false;
  if (data[start] == 0x43 && data[start + 1] == 0x43) {
    // "CC" prefix (DVS 053 type 0x01, SCTE-20 type 0x03, and variants).
    final type = data[start + 2];
    if (type == 0x01) {
      countOffset = 4; scteStyle = false; // flags byte at +3, cc_count at +4
    } else {
      countOffset = 3; scteStyle = true;  // packed byte at +3
    }
  } else if (payloadLen >= 7 &&
      data[start] == 0x47 && data[start + 1] == 0x41 &&
      data[start + 2] == 0x39 && data[start + 3] == 0x34 &&
      data[start + 4] == 0x03) {
    // ATSC A/53 "GA94".
    countOffset = 5; scteStyle = true;
  }
  if (countOffset != null) {
    if (countOffset >= payloadLen) return null;
    final countByte = data[start + countOffset];
    final ccCount   = scteStyle ? (countByte >> 1) & 0x1F : countByte & 0x7F;
    if (ccCount == 0) return null;
    final tripleStart = countOffset + 1;
    if (tripleStart + ccCount * 3 > payloadLen) return null; // truncated
    return (
      countOffset: countOffset,
      scteStyle:   scteStyle,
      tripleStart: tripleStart,
      ccCount:     ccCount,
    );
  }

  // -- Tier 2: structural fallback ------------------------------------------
  CcPayloadLayout? best;
  for (var o = 0; o <= math.min(8, payloadLen - 1); o++) {
    final countByte = data[start + o];
    for (final scte in [false, true]) {
      final count = scte ? (countByte >> 1) & 0x1F : countByte & 0x7F;
      if (count < 2) continue;
      final tripleStart = o + 1;
      final consumed    = tripleStart + count * 3;
      if (consumed > payloadLen) continue;
      if (payloadLen - consumed > 3) continue; // too much trailing slack

      var valid = true;
      var pairBytes = 0, oddParity = 0;
      for (var i = 0; i < count && valid; i++) {
        final t = start + tripleStart + i * 3;
        final type = data[t];
        if (type < 0xFC) { valid = false; break; }
        if (type != 0xFE) {
          // EIA-608 data bytes (FC/FD/FF triples) must carry odd parity.
          for (final b in [data[t + 1], data[t + 2]]) {
            pairBytes++;
            var bits = b, ones = 0;
            while (bits != 0) { ones += bits & 1; bits >>= 1; }
            if (ones.isOdd) oddParity++;
          }
        }
      }
      if (!valid) continue;
      if (pairBytes > 0 && oddParity < pairBytes * 0.9) continue;

      if (best == null || count * 3 > best.ccCount * 3) {
        best = (
          countOffset: o,
          scteStyle:   scte,
          tripleStart: tripleStart,
          ccCount:     count,
        );
      }
    }
  }
  return best;
}

/// Neutralizes EIA-608 CC user_data in the MPEG-2 video stream stored within
/// [mkvFile], in-place, so players don't show empty "Closed Captions 1-4"
/// tracks. For signature formats (GA94 / "CC") the 4-byte identifier is zeroed
/// (historic behavior); for all detected formats the cc_count byte is zeroed
/// as well, which makes decoders read zero triples — this also covers
/// signature-less variants whose identifier is already zero.
///
/// [chunkSize] is injectable for tests.
Future<void> stripMkvCcUserData(File mkvFile,
    {int chunkSize = 4 * 1024 * 1024}) async {
  // Must cover a start code plus a full CC payload so packets straddling a
  // window boundary are seen in whole by the next window.
  final overlap = 4 + maxCcPayloadLen;

  final raf      = await mkvFile.open(mode: FileMode.append);
  final fileSize = await raf.length();
  try {
    var scanPos = 0;
    while (scanPos < fileSize) {
      final readStart = math.max(0, scanPos - overlap);
      final readEnd   = math.min(scanPos + chunkSize, fileSize);
      final toRead    = (readEnd - readStart).toInt();

      await raf.setPosition(readStart);
      final buf = await raf.read(toRead);

      final limit = buf.length - 4;
      for (var i = 0; i < limit; i++) {
        if (buf[i]   != 0x00 || buf[i+1] != 0x00 ||
            buf[i+2] != 0x01 || buf[i+3] != 0xB2) {
          continue;
        }
        final payloadStart = i + 4;
        // Payload ends at the next start code, capped at maxCcPayloadLen.
        var payloadEnd = math.min(payloadStart + maxCcPayloadLen, buf.length);
        for (var j = payloadStart; j + 2 < payloadEnd; j++) {
          if (buf[j] == 0x00 && buf[j+1] == 0x00 && buf[j+2] == 0x01) {
            payloadEnd = j;
            break;
          }
        }
        // If the payload may extend past this buffer, defer to the next
        // window (which re-reads it in full via the overlap).
        if (payloadEnd == buf.length && readEnd < fileSize) continue;

        final layout = detectCcPayload(buf, payloadStart, payloadEnd);
        if (layout == null) continue;

        if ((buf[payloadStart] == 0x47 && buf[payloadStart + 1] == 0x41) ||
            (buf[payloadStart] == 0x43 && buf[payloadStart + 1] == 0x43)) {
          await raf.setPosition(readStart + payloadStart);
          await raf.writeFrom(Uint8List(4)); // zero the identifier
        }
        await raf.setPosition(readStart + payloadStart + layout.countOffset);
        await raf.writeFrom(Uint8List(1)); // zero cc_count → 0 triples
      }

      scanPos += chunkSize;
    }
  } finally {
    await raf.close();
  }
}
