import 'dart:io';
import 'dart:typed_data';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy/src/utils/file_utils.dart' show confirmOverwrite;
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

  group('DVDRipper._scanPgcCells stinger-cell filter', () {
    // Bouwt een synthetisch PGC-blok: header + PGMAP + C_PBIT.
    // [cells] is een lijst (secs, first, last); elk programma wijst naar
    // de gelijknamige cell (pgmap = [1, 2, ...]).
    (Uint8List, ByteData) pgcWith(List<(int, int, int)> cells) {
      const pgmapRel = 0x100;
      final cpbitRel = pgmapRel + cells.length;
      final data = Uint8List(cpbitRel + cells.length * 24);
      final bd = ByteData.sublistView(data);
      data[2] = cells.length; // nrPrograms
      data[3] = cells.length; // nrCells
      bd.setUint16(0xE6, pgmapRel);
      bd.setUint16(0xE8, cpbitRel);
      int bcd(int v) => ((v ~/ 10) << 4) | (v % 10);
      for (var i = 0; i < cells.length; i++) {
        data[pgmapRel + i] = i + 1;
        final (secs, first, last) = cells[i];
        final o = cpbitRel + i * 24;
        data[o + 4] = bcd(secs ~/ 3600);
        data[o + 5] = bcd((secs % 3600) ~/ 60);
        data[o + 6] = bcd(secs % 60);
        data[o + 7] = bcd(15); // frames (sub-seconde), fps-bits genegeerd
        bd.setUint32(o + 8, first);
        bd.setUint32(o + 20, last);
      }
      return (data, bd);
    }

    test('niet-aansluitende 0s-eindcell wordt gedropt (iCarly-stinger)', () {
      final (data, bd) = pgcWith([(1415, 0, 432874), (0, 2597592, 2597595)]);
      final r = DVDRipper.scanPgcCellsForTest(data, bd, 0, 1415);
      expect(r.cells, [(first: 0, last: 432874)]);
      expect(r.chapters, [Duration.zero]); // hoofdstuk 2 vervalt mee
    });

    test('meerdere trailing stingers worden allemaal gedropt', () {
      final (data, bd) = pgcWith([
        (1415, 0, 432874),
        (0, 2597592, 2597595),
        (0, 2600000, 2600003),
      ]);
      final r = DVDRipper.scanPgcCellsForTest(data, bd, 0, 1415);
      expect(r.cells, [(first: 0, last: 432874)]);
    });

    test('aansluitende 0s-eindcell blijft behouden', () {
      final (data, bd) = pgcWith([(1415, 0, 432874), (0, 432875, 432878)]);
      final r = DVDRipper.scanPgcCellsForTest(data, bd, 0, 1415);
      expect(r.cells,
          [(first: 0, last: 432874), (first: 432875, last: 432878)]);
    });

    test('niet-aansluitende eindcell met echte speelduur blijft behouden', () {
      final (data, bd) = pgcWith([(1400, 0, 432874), (15, 2597592, 2601000)]);
      final r = DVDRipper.scanPgcCellsForTest(data, bd, 0, 1415);
      expect(r.cells,
          [(first: 0, last: 432874), (first: 2597592, last: 2601000)]);
    });

    test('enkele cell wordt nooit gedropt', () {
      final (data, bd) = pgcWith([(0, 100, 103)]);
      final r = DVDRipper.scanPgcCellsForTest(data, bd, 0, 0);
      expect(r.cells, [(first: 100, last: 103)]);
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

  group('audioTrackOutputPath', () {
    const track = TrackInfo(
      number: 2,
      title: 'all-american bitch?',
      artist: '',
      artistMbid: '',
      recordingMbid: '',
      startTime: 0,
      endTime: 60,
    );

    test('pad met gesanitizede onderdelen, rauwe titel blijft in tags', () {
      final meta = DiscMetadata(
        album: 'GUTS',
        artist: 'Olivia Rodrigo',
        date: '2023',
        tracks: [track],
      );
      expect(
        audioTrackOutputPath('/music', meta, track),
        equals('/music/Olivia Rodrigo/GUTS (2023)/02-all-american bitch_.flac'),
      );
    });

    test('multi-disc krijgt discnummer-prefix', () {
      final meta = DiscMetadata(
        album: 'Box',
        artist: 'Artist',
        discNumber: 2,
        totalDiscs: 3,
        tracks: [track],
      );
      expect(
        audioTrackOutputPath('/music', meta, track),
        equals('/music/Artist/Box/02-02-all-american bitch_.flac'),
      );
    });
  });

  group('videoTitleOutputPath', () {
    const title = BlurayTitle(
      index: 0,
      playlist: '00001',
      duration: Duration(minutes: 90),
      audioCount: 1,
      subtitleCount: 0,
      audioLangs: [],
      subtitleLangs: [],
    );

    test('outputDir/disc/disc-filename met gesanitizede disctitel', () {
      expect(
        videoTitleOutputPath('/videos', 'DISC: TITLE?', title),
        equals('/videos/DISC_ TITLE_/DISC_ TITLE_-title_00001.mkv'),
      );
    });
  });

  group('confirmOverwrite met overwrite-set', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('overwrite_test');
    });
    tearDown(() async => tmp.delete(recursive: true));

    void log(String msg, {bool isError = false}) {}

    test('bestand niet aanwezig → true, set irrelevant', () async {
      final f = File('${tmp.path}/nieuw.mkv');
      expect(
        await confirmOverwrite(f, force: false, onLog: log, overwrite: {}),
        isTrue,
      );
    });

    test('bestaand bestand in set → verwijderd en true', () async {
      final f = File('${tmp.path}/a.mkv')..writeAsStringSync('x');
      expect(
        await confirmOverwrite(f,
            force: false, onLog: log, overwrite: {f.path}),
        isTrue,
      );
      expect(f.existsSync(), isFalse);
    });

    test('bestaand bestand niet in set → false, bestand blijft', () async {
      final f = File('${tmp.path}/b.mkv')..writeAsStringSync('x');
      expect(
        await confirmOverwrite(f, force: false, onLog: log, overwrite: {}),
        isFalse,
      );
      expect(f.existsSync(), isTrue);
    });

    test('force verwijdert ook buiten de set', () async {
      final f = File('${tmp.path}/c.mkv')..writeAsStringSync('x');
      expect(
        await confirmOverwrite(f, force: true, onLog: log, overwrite: {}),
        isTrue,
      );
      expect(f.existsSync(), isFalse);
    });
  });
}
