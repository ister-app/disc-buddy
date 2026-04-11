import 'package:disc_buddy/disc_buddy.dart';
import 'package:test/test.dart';

void main() {
  group('computeDiscId', () {
    test('geeft een niet-lege string terug', () {
      // 3 tracks, lead-out op 1000 seconden
      final id = computeDiscId([0.0, 200.0, 500.0], 1000.0);
      expect(id, isNotEmpty);
      expect(id, isNot(contains('+')));
      expect(id, isNot(contains('/')));
      expect(id, isNot(contains('=')));
    });

    test('transliteratie: +/= → ._-', () {
      // Deterministische invoer
      final id = computeDiscId([0.0], 500.0);
      expect(id, matches(RegExp(r'^[A-Za-z0-9._\-]+$')));
    });
  });

  group('DVDRipper._pgcSubId subtitle SID detectie', () {
    test('byte 0 actief (4:3-only disc) → SID uit byte 0', () {
      // active_4:3=1, stream_nr=2 → 0x20+2 = 0x22
      expect(DVDRipper.pgcSubIdForTest(0x82000000), equals(0x22));
    });

    test('byte 1 actief, byte 0 inactief (widescreen PAL) → SID uit byte 1', () {
      // active_4:3=0, active_widescreen=1, stream_nr=1 → 0x20+1 = 0x21
      expect(DVDRipper.pgcSubIdForTest(0x00810000), equals(0x21));
    });

    test('byte 0 én byte 1 actief → byte 0 (4:3) wint', () {
      // byte0: stream=2, byte1: stream=1 → 4:3 wint → 0x22
      expect(DVDRipper.pgcSubIdForTest(0x82810000), equals(0x22));
    });

    test('alleen byte 0 actief (4:3-only disc) → SID uit byte 0', () {
      // Geen wide aanwezig → valt terug op 4:3 → 0x22
      expect(DVDRipper.pgcSubIdForTest(0x82000000), equals(0x22));
    });

    test('byte 2 actief (letterbox), rest inactief → SID uit byte 2', () {
      // active_letterbox=1, stream_nr=3 → 0x20+3 = 0x23
      expect(DVDRipper.pgcSubIdForTest(0x00008300), equals(0x23));
    });

    test('byte 3 actief (pan-scan), rest inactief → SID uit byte 3', () {
      // active_pan_scan=1, stream_nr=0 → 0x20
      expect(DVDRipper.pgcSubIdForTest(0x00000080), equals(0x20));
    });

    test('geen byte actief → null', () {
      expect(DVDRipper.pgcSubIdForTest(0x00000000), isNull);
    });
  });

  group('DiscMetadata', () {
    test('albumDir bevat jaar als aanwezig', () {
      final meta = DiscMetadata(
        album: 'Grootste hits',
        artist: 'Nick & Simon',
        date: '2017',
        tracks: [],
      );
      expect(meta.albumDir, equals('Grootste hits (2017)'));
    });

    test('albumDir zonder jaar', () {
      final meta = DiscMetadata(
        album: 'Grootste hits',
        artist: 'Nick & Simon',
        tracks: [],
      );
      expect(meta.albumDir, equals('Grootste hits'));
    });

    test('albumArtist valt terug op Various Artists', () {
      final meta = DiscMetadata(album: 'Mix', artist: '', tracks: []);
      expect(meta.albumArtist, equals('Various Artists'));
    });
  });
}
