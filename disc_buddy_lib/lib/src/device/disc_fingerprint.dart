import 'dart:io';
import 'dart:typed_data';

import '../metadata/disc_id.dart';
import '../utils/udev.dart';
import 'cdrom_toc.dart';
import 'disc_type_detector.dart';

/// Thrown when the disc in the drive is not the disc that was scanned.
class DiscChangedException implements Exception {
  final String? expected;
  final String? actual;
  const DiscChangedException({this.expected, this.actual});

  @override
  String toString() => 'Disc changed since scan '
      '(scanned: ${expected ?? "?"}, now: ${actual ?? "none/unreadable"})';
}

/// Identity of the disc currently in [device], or null if unreadable.
///
/// Data discs: ISO9660 Primary Volume Descriptor (volume id + creation
/// timestamp) read directly from the block device at byte 32768; falls back
/// to the UDF primary volume descriptor (BD discs without an ISO bridge),
/// then to udev's `ID_FS_LABEL`/`ID_FS_UUID`. Audio CDs: MusicBrainz disc ID
/// computed from the SG_IO TOC.
///
/// Reads the device directly (not the udev cache), so the result reflects
/// the disc that is physically present even if udevd has not re-probed yet.
Future<String?> readDiscFingerprint(String device, {DiscType? discType}) async {
  if (discType == DiscType.audioCD) return _tocFingerprint(device);

  final data = await _dataDiscFingerprint(device);
  if (data != null) return data;

  // Type unknown and no readable data-disc descriptors — could still be an
  // audio CD (raw reads of the data area fail there).
  if (discType == null) return _tocFingerprint(device);
  return null;
}

/// Reads the current fingerprint of [device] and throws
/// [DiscChangedException] when it differs from [expected] or is unreadable.
/// No-op when [expected] is null (the scanned disc had no fingerprint).
Future<void> verifyDiscUnchanged(String device, String? expected,
    {DiscType? discType}) async {
  if (expected == null) return;
  final actual = await readDiscFingerprint(device, discType: discType);
  if (actual != expected) {
    throw DiscChangedException(expected: expected, actual: actual);
  }
}

// ---------------------------------------------------------------------------
// Data discs
// ---------------------------------------------------------------------------

Future<String?> _dataDiscFingerprint(String device) async {
  // ISO9660 PVD at sector 16.
  final pvdSector = await _readAt(device, 16 * 2048, 2048);
  if (pvdSector != null) {
    final fp = pvdFingerprintFromSector(pvdSector);
    if (fp != null) return fp;
  }

  // UDF: anchor at LBA 256 points at the volume descriptor sequence.
  final anchor = await _readAt(device, 256 * 2048, 2048);
  if (anchor != null) {
    final extent = udfAvdpExtent(anchor);
    if (extent != null) {
      final len = extent.len.clamp(0, 16 * 2048);
      final mvds = await _readAt(device, extent.loc * 2048, len);
      if (mvds != null) {
        for (var off = 0; off + 2048 <= mvds.length; off += 2048) {
          final fp = udfPvdFingerprint(
              Uint8List.sublistView(mvds, off, off + 2048));
          if (fp != null) return fp;
        }
      }
    }
  }

  // Last resort: udev's cached filesystem probe.
  try {
    final result = await Process.run(
        'udevadm', ['info', '--query=property', '--name=$device']);
    return udevFingerprintFromProps(parseUdevProps(result.stdout as String));
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _readAt(String device, int offset, int length) async {
  // dart:io cannot open block special files (openRead throws
  // PathNotFoundException on /dev/srX), so read via dd. Offsets and lengths
  // are always multiples of 2048 here.
  try {
    final result = await Process.run(
      'dd',
      [
        'if=$device', 'bs=2048',
        'skip=${offset ~/ 2048}', 'count=${length ~/ 2048}',
        'status=none',
      ],
      stdoutEncoding: null,
    ).timeout(const Duration(seconds: 30));
    final data = Uint8List.fromList(result.stdout as List<int>);
    return data.length == length ? data : null;
  } catch (_) {
    return null;
  }
}

/// Fingerprint from a 2048-byte ISO9660 Primary Volume Descriptor sector,
/// or null when the sector is not a PVD or carries no identity.
String? pvdFingerprintFromSector(Uint8List sector) {
  if (sector.length < 830) return null;
  // Type 1 (PVD), magic "CD001" at offset 1.
  if (sector[0] != 1) return null;
  if (String.fromCharCodes(sector.sublist(1, 6)) != 'CD001') return null;
  final volId   = _ascii(sector, 40, 32);
  final created = _ascii(sector, 813, 17);
  if (volId.isEmpty && created.isEmpty) return null;
  return 'pvd:$volId|$created';
}

/// Location and length (bytes) of the main volume descriptor sequence from a
/// UDF Anchor Volume Descriptor Pointer sector (tag id 2), or null.
({int loc, int len})? udfAvdpExtent(Uint8List sector) {
  if (sector.length < 32) return null;
  final bd = ByteData.sublistView(sector);
  if (bd.getUint16(0, Endian.little) != 2) return null; // AVDP tag id
  final len = bd.getUint32(16, Endian.little);
  final loc = bd.getUint32(20, Endian.little);
  if (len == 0) return null;
  return (loc: loc, len: len);
}

/// Fingerprint from a UDF Primary Volume Descriptor (tag id 1), or null.
String? udfPvdFingerprint(Uint8List sector) {
  if (sector.length < 388) return null;
  final bd = ByteData.sublistView(sector);
  if (bd.getUint16(0, Endian.little) != 1) return null; // PVD tag id
  final volId    = _udfDstring(sector, 24, 32);
  final recorded = _hex(sector, 376, 12); // recording timestamp, raw bytes
  if (volId.isEmpty && recorded.isEmpty) return null;
  return 'udf:$volId|$recorded';
}

/// Fingerprint from udev filesystem-probe properties, or null when absent.
String? udevFingerprintFromProps(Map<String, String> props) {
  final label = (props['ID_FS_LABEL'] ?? '').trim();
  final uuid  = (props['ID_FS_UUID'] ?? '').trim();
  if (label.isEmpty && uuid.isEmpty) return null;
  return 'udev:$label|$uuid';
}

String _ascii(Uint8List data, int offset, int length) {
  final bytes = data.sublist(offset, offset + length)
      .where((b) => b >= 0x20 && b < 0x7F)
      .toList();
  return String.fromCharCodes(bytes).trim();
}

/// UDF dstring: last byte is the length, first byte the compression id.
String _udfDstring(Uint8List data, int offset, int fieldLen) {
  final len = data[offset + fieldLen - 1];
  if (len < 2 || len > fieldLen - 1) return '';
  return _ascii(data, offset + 1, len - 1);
}

String _hex(Uint8List data, int offset, int length) {
  final bytes = data.sublist(offset, offset + length);
  if (bytes.every((b) => b == 0)) return '';
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ---------------------------------------------------------------------------
// Audio CDs
// ---------------------------------------------------------------------------

Future<String?> _tocFingerprint(String device) async {
  try {
    final toc = await readToc(device);
    if (toc == null) return null;
    return 'toc:${computeDiscIdFromOffsets(toc.offsets, toc.leadOut)}';
  } catch (_) {
    return null;
  }
}
