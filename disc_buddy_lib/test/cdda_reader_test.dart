import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:disc_buddy/src/device/cdda_reader.dart';

void main() {
  group('buildReadCdCdb', () {
    test('basis-layout', () {
      final cdb = buildReadCdCdb(0, 27);
      expect(cdb, equals([0xBE, 0x04, 0, 0, 0, 0, 0, 0, 27, 0x10, 0, 0]));
    });

    test('LBA big-endian', () {
      final cdb = buildReadCdCdb(0x01020304, 1);
      expect(cdb.sublist(2, 6), equals([0x01, 0x02, 0x03, 0x04]));
    });

    test('sector count 24-bit big-endian', () {
      final cdb = buildReadCdCdb(0, 0x010203);
      expect(cdb.sublist(6, 9), equals([0x01, 0x02, 0x03]));
    });
  });

  group('trackSectorRange', () {
    const offsets = [150, 20000, 45000];
    const leadOut = 60000;

    test('middelste track eindigt bij volgende offset', () {
      final r = trackSectorRange(offsets: offsets, leadOut: leadOut, trackIndex: 1);
      expect(r.startLba, equals(20000 - 150));
      expect(r.sectorCount, equals(45000 - 20000));
    });

    test('laatste track eindigt bij lead-out', () {
      final r = trackSectorRange(offsets: offsets, leadOut: leadOut, trackIndex: 2);
      expect(r.startLba, equals(45000 - 150));
      expect(r.sectorCount, equals(60000 - 45000));
    });

    test('eerste track: pre-gap van 150 sectoren afgetrokken', () {
      final r = trackSectorRange(offsets: offsets, leadOut: leadOut, trackIndex: 0);
      expect(r.startLba, equals(0));
      expect(r.sectorCount, equals(20000 - 150));
    });

    test('single-track disc', () {
      final r = trackSectorRange(offsets: const [150], leadOut: 1000, trackIndex: 0);
      expect(r.startLba, equals(0));
      expect(r.sectorCount, equals(850));
    });
  });

  group('cddaSectorStream', () {
    Uint8List sectorData(int lba, int count) {
      // Deterministic per-sector payload so LBA ordering is verifiable.
      final data = Uint8List(count * kCddaSectorSize);
      for (var s = 0; s < count; s++) {
        data[s * kCddaSectorSize] = (lba + s) & 0xFF;
      }
      return data;
    }

    test('happy path: juiste totalen, batches en LBA-volgorde', () async {
      final reads = <(int, int)>[];
      final bytesSeen = <int>[];
      final chunks = await cddaSectorStream(
        startLba: 100,
        sectorCount: 60, // 27 + 27 + 6
        read: (lba, count) async {
          reads.add((lba, count));
          return sectorData(lba, count);
        },
        onBytes: bytesSeen.add,
      ).toList();

      expect(reads, equals([(100, 27), (127, 27), (154, 6)]));
      final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
      expect(total, equals(60 * kCddaSectorSize));
      expect(bytesSeen.last, equals(total));
      expect(bytesSeen, orderedEquals(List.of(bytesSeen)..sort()));
      // First byte of each chunk encodes its start LBA.
      expect(chunks[0][0], equals(100));
      expect(chunks[1][0], equals(127));
      expect(chunks[2][0], equals(154));
    });

    test('batch faalt tweemaal en slaagt dan (geen degradatie)', () async {
      var failures = 0;
      var singleReads = 0;
      final chunks = await cddaSectorStream(
        startLba: 0,
        sectorCount: 27,
        read: (lba, count) async {
          if (count == 1) singleReads++;
          if (failures < 2) {
            failures++;
            return null;
          }
          return sectorData(lba, count);
        },
      ).toList();

      expect(failures, equals(2));
      expect(singleReads, equals(0));
      expect(chunks.single.length, equals(27 * kCddaSectorSize));
    });

    test('batch blijft falen → degradatie naar single-sector reads', () async {
      final singleLbas = <int>[];
      final chunks = await cddaSectorStream(
        startLba: 10,
        sectorCount: 5,
        batchSectors: 5,
        read: (lba, count) async {
          if (count > 1) return null; // batch always fails
          singleLbas.add(lba);
          return sectorData(lba, count);
        },
      ).toList();

      expect(singleLbas, equals([10, 11, 12, 13, 14]));
      expect(chunks.single.length, equals(5 * kCddaSectorSize));
    });

    test('onleesbare sector → CddaReadException met juiste LBA', () async {
      var lastBytes = 0;
      final stream = cddaSectorStream(
        startLba: 0,
        sectorCount: 10,
        batchSectors: 5,
        read: (lba, count) async {
          if (lba <= 7 && lba + count > 7) return null; // sector 7 unreadable
          return sectorData(lba, count);
        },
        onBytes: (b) => lastBytes = b,
      );

      await expectLater(
        stream.toList(),
        throwsA(isA<CddaReadException>()
            .having((e) => e.lba, 'lba', equals(7))),
      );
      // Only the first full batch (sectors 0-4) was delivered.
      expect(lastBytes, equals(5 * kCddaSectorSize));
    });

    test('te korte read telt als mislukt', () async {
      var attempts = 0;
      final chunks = await cddaSectorStream(
        startLba: 0,
        sectorCount: 2,
        batchSectors: 2,
        read: (lba, count) async {
          attempts++;
          if (attempts == 1) return Uint8List(10); // short read
          return sectorData(lba, count);
        },
      ).toList();

      expect(chunks.single.length, equals(2 * kCddaSectorSize));
    });
  });
}
