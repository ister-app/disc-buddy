import 'dart:typed_data';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy/src/utils/udev.dart';
import 'package:test/test.dart';

Uint8List _pvdSector({String volId = '', String created = ''}) {
  final sector = Uint8List(2048);
  sector[0] = 1; // type: PVD
  sector.setRange(1, 6, 'CD001'.codeUnits);
  final volBytes = volId.padRight(32).codeUnits;
  sector.setRange(40, 72, volBytes);
  final createdBytes = created.padRight(17, '\x00').codeUnits;
  sector.setRange(813, 830, createdBytes);
  return sector;
}

Uint8List _udfDescriptor(int tagId) {
  final sector = Uint8List(2048);
  ByteData.sublistView(sector).setUint16(0, tagId, Endian.little);
  return sector;
}

void main() {
  group('pvdFingerprintFromSector', () {
    test('extracts volume id and creation timestamp', () {
      final fp = pvdFingerprintFromSector(
          _pvdSector(volId: 'DVD_VVE4698_2', created: '2024120204393900'));
      expect(fp, 'pvd:DVD_VVE4698_2|2024120204393900');
    });

    test('trims trailing padding of the volume id', () {
      final fp = pvdFingerprintFromSector(
          _pvdSector(volId: 'MOVIE', created: '2020010100000000'));
      expect(fp, 'pvd:MOVIE|2020010100000000');
    });

    test('rejects wrong magic', () {
      final sector = _pvdSector(volId: 'MOVIE');
      sector[3] = 0x58; // corrupt "CD001"
      expect(pvdFingerprintFromSector(sector), isNull);
    });

    test('rejects wrong descriptor type', () {
      final sector = _pvdSector(volId: 'MOVIE');
      sector[0] = 2; // supplementary descriptor
      expect(pvdFingerprintFromSector(sector), isNull);
    });

    test('still fingerprints on blank volume id when timestamp is set', () {
      final fp = pvdFingerprintFromSector(_pvdSector(created: '2024120205192900'));
      expect(fp, 'pvd:|2024120205192900');
    });

    test('returns null when both fields are blank', () {
      expect(pvdFingerprintFromSector(_pvdSector()), isNull);
    });

    test('returns null on short input', () {
      expect(pvdFingerprintFromSector(Uint8List(100)), isNull);
    });
  });

  group('udfAvdpExtent', () {
    test('parses the main volume descriptor sequence extent', () {
      final sector = _udfDescriptor(2);
      final bd = ByteData.sublistView(sector);
      bd.setUint32(16, 32768, Endian.little); // length
      bd.setUint32(20, 257, Endian.little);   // location
      expect(udfAvdpExtent(sector), (loc: 257, len: 32768));
    });

    test('rejects a non-AVDP tag id', () {
      final sector = _udfDescriptor(1);
      ByteData.sublistView(sector).setUint32(16, 32768, Endian.little);
      expect(udfAvdpExtent(sector), isNull);
    });

    test('rejects a zero-length extent', () {
      final sector = _udfDescriptor(2);
      ByteData.sublistView(sector).setUint32(20, 257, Endian.little);
      expect(udfAvdpExtent(sector), isNull);
    });
  });

  group('udfPvdFingerprint', () {
    Uint8List pvd({String volId = '', List<int>? recorded}) {
      final sector = _udfDescriptor(1);
      if (volId.isNotEmpty) {
        sector[24] = 8; // compression id (uncompressed 8-bit)
        sector.setRange(25, 25 + volId.length, volId.codeUnits);
        sector[24 + 31] = 1 + volId.length; // dstring length byte
      }
      if (recorded != null) sector.setRange(376, 376 + recorded.length, recorded);
      return sector;
    }

    test('extracts volume id and recording timestamp', () {
      final fp = udfPvdFingerprint(
          pvd(volId: 'BLURAY_DISC', recorded: [0x21, 0x07, 0xE8]));
      expect(fp, 'udf:BLURAY_DISC|2107e8000000000000000000');
    });

    test('rejects a non-PVD tag id', () {
      final sector = _udfDescriptor(2);
      expect(udfPvdFingerprint(sector), isNull);
    });

    test('returns null when both fields are absent', () {
      expect(udfPvdFingerprint(_udfDescriptor(1)), isNull);
    });
  });

  group('udevFingerprintFromProps', () {
    test('combines label and uuid', () {
      expect(
        udevFingerprintFromProps(
            {'ID_FS_LABEL': 'MOVIE', 'ID_FS_UUID': '2024-12-02-05-19-29-00'}),
        'udev:MOVIE|2024-12-02-05-19-29-00',
      );
    });

    test('works with only a label', () {
      expect(udevFingerprintFromProps({'ID_FS_LABEL': 'MOVIE'}), 'udev:MOVIE|');
    });

    test('works with only a uuid', () {
      expect(udevFingerprintFromProps({'ID_FS_UUID': 'abc'}), 'udev:|abc');
    });

    test('returns null when both are absent', () {
      expect(udevFingerprintFromProps({'OTHER': 'x'}), isNull);
    });
  });

  group('DiscChangedException', () {
    test('describes both fingerprints', () {
      const e = DiscChangedException(expected: 'pvd:A|1', actual: 'pvd:B|2');
      expect(e.toString(), contains('pvd:A|1'));
      expect(e.toString(), contains('pvd:B|2'));
    });

    test('describes an unreadable current disc', () {
      const e = DiscChangedException(expected: 'pvd:A|1');
      expect(e.toString(), contains('none/unreadable'));
    });
  });

  group('mediaIdFromProps', () {
    test('empty when no medium', () {
      expect(mediaIdFromProps({}), '');
      expect(mediaIdFromProps({'ID_CDROM_MEDIA': '0'}), '');
    });

    test('audio CD identity from track count and session offset', () {
      expect(
        mediaIdFromProps({
          'ID_CDROM_MEDIA': '1',
          'ID_CDROM_MEDIA_TRACK_COUNT_AUDIO': '12',
          'ID_CDROM_MEDIA_SESSION_LAST_OFFSET': '123456789',
        }),
        'audio:12|123456789',
      );
    });

    test('data disc identity from label and uuid', () {
      expect(
        mediaIdFromProps({
          'ID_CDROM_MEDIA': '1',
          'ID_FS_LABEL': 'DVD_VVE4698_4_SAMANDCAT_D4',
          'ID_FS_UUID': '2024-12-02-05-19-29-00',
        }),
        'data:DVD_VVE4698_4_SAMANDCAT_D4|2024-12-02-05-19-29-00',
      );
    });

    test('discs differing only in uuid get different ids', () {
      final a = mediaIdFromProps({
        'ID_CDROM_MEDIA': '1',
        'ID_FS_LABEL': 'SAME',
        'ID_FS_UUID': 'uuid-a',
      });
      final b = mediaIdFromProps({
        'ID_CDROM_MEDIA': '1',
        'ID_FS_LABEL': 'SAME',
        'ID_FS_UUID': 'uuid-b',
      });
      expect(a, isNot(b));
    });

    test('data disc without probe results still reports presence', () {
      expect(mediaIdFromProps({'ID_CDROM_MEDIA': '1'}), 'data:');
    });
  });
}
