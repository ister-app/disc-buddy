import 'dart:typed_data';

import 'package:disc_buddy/src/device/resilient_read.dart';
import 'package:test/test.dart';

/// Deterministic per-block payload: byte 0 = block number & 0xFF, byte 1 = 0xAA.
Uint8List blockData(int offset, int count) {
  final data = Uint8List(count * kDvdBlockLen);
  for (var i = 0; i < count; i++) {
    data[i * kDvdBlockLen] = (offset + i) & 0xFF;
    data[i * kDvdBlockLen + 1] = 0xAA;
  }
  return data;
}

/// Fake disc: blocks in [bad] fail; any multi-block read touching one fails
/// as a whole (like DVDReadBlocks). Counts calls per block.
class FakeDisc {
  FakeDisc({this.bad = const {}, this.flakyOnce = const {}});
  final Set<int> bad;
  /// Blocks that fail the first time only.
  final Set<int> flakyOnce;
  final Set<int> _seenFlaky = {};
  int calls = 0;
  final log = <(int, int)>[];

  Uint8List? read(int offset, int count) {
    calls++;
    log.add((offset, count));
    for (var b = offset; b < offset + count; b++) {
      if (bad.contains(b)) return null;
      if (flakyOnce.contains(b) && _seenFlaky.add(b)) return null;
    }
    return blockData(offset, count);
  }
}

int blockAt(Uint8List bytes, int i) => bytes[i * kDvdBlockLen];
bool isZeroBlock(Uint8List bytes, int i) =>
    bytes.sublist(i * kDvdBlockLen, (i + 1) * kDvdBlockLen).every((b) => b == 0);

void main() {
  group('salvageBlocks', () {
    test('alles leesbaar → één read, geen bisectie, badBlocks 0', () {
      final disc = FakeDisc();
      final stats = ReadStats();
      final out = salvageBlocks(disc.read, 100, 50, stats: stats);
      expect(out.length, 50 * kDvdBlockLen);
      expect(disc.calls, 1);
      expect(stats.badBlocks, 0);
      expect(stats.blocksRead, 50);
      expect(blockAt(out, 0), 100);
      expect(blockAt(out, 49), 149);
    });

    test('één slechte sector → 2048 nullen op juiste positie, badRange (s,s)', () {
      final disc = FakeDisc(bad: {107});
      final stats = ReadStats();
      final ranges = <(int, int)>[];
      final out = salvageBlocks(disc.read, 100, 20,
          bisectSizes: const [8, 1], stats: stats,
          onBadRange: (f, l) => ranges.add((f, l)));
      expect(out.length, 20 * kDvdBlockLen);
      expect(isZeroBlock(out, 7), isTrue);
      expect(blockAt(out, 6), 106);
      expect(blockAt(out, 8), 108);
      expect(stats.badBlocks, 1);
      expect(stats.badRanges, [(first: 107, last: 107)]);
      expect(ranges, [(107, 107)]);
      expect(stats.blocksRead, 19);
    });

    test('aaneengesloten slechte sectoren worden één badRange', () {
      final disc = FakeDisc(bad: {10, 11, 12});
      final stats = ReadStats();
      final out = salvageBlocks(disc.read, 0, 16, bisectSizes: const [4, 1], stats: stats);
      expect(stats.badBlocks, 3);
      expect(stats.badRanges, [(first: 10, last: 12)]);
      for (final i in [10, 11, 12]) {
        expect(isZeroBlock(out, i), isTrue);
      }
      expect(blockAt(out, 13), 13);
    });

    test('slechte sectoren in twee sub-chunks → twee badRanges', () {
      final disc = FakeDisc(bad: {3, 13});
      final stats = ReadStats();
      salvageBlocks(disc.read, 0, 16, bisectSizes: const [8, 1], stats: stats);
      expect(stats.badRanges, [(first: 3, last: 3), (first: 13, last: 13)]);
      expect(stats.badBlocks, 2);
    });

    test('retries worden geteld en een flaky blok herstelt zonder nullen', () {
      final disc = FakeDisc(flakyOnce: {5});
      final stats = ReadStats();
      final out = salvageBlocks(disc.read, 0, 8,
          bisectSizes: const [1], chunkRetries: 1, blockRetries: 2, stats: stats);
      expect(stats.badBlocks, 0);
      expect(stats.retries, greaterThanOrEqualTo(1));
      expect(blockAt(out, 5), 5);
    });

    test('cap overschreden → DvdReadException met badBlocks en offset', () {
      final disc = FakeDisc(bad: {1, 2, 3, 4});
      final stats = ReadStats();
      expect(
        () => salvageBlocks(disc.read, 0, 8,
            bisectSizes: const [1], maxBadBlocks: 2, stats: stats),
        throwsA(isA<DvdReadException>()
            .having((e) => e.cap, 'cap', 2)
            .having((e) => e.offset, 'offset', 3)),
      );
    });

    test('resultaat is altijd count*2048 bytes', () {
      for (final count in [1, 7, 64, 513]) {
        final out = salvageBlocks(FakeDisc(bad: {5}).read, 0, count,
            stats: ReadStats());
        expect(out.length, count * kDvdBlockLen);
      }
    });

    test('summary noemt aantal sectoren en ranges', () {
      final stats = ReadStats()..addBad(4, 5)..addBad(9, 9);
      expect(stats.summary(), contains('3 unreadable sectors'));
      expect(stats.summary(), contains('2 ranges'));
      expect(ReadStats().summary(), contains('cleanly'));
    });
  });

  group('resilientBlockStream', () {
    Future<List<Uint8List>> collect(Stream<Uint8List> s) => s.toList();

    test('happy path: chunks van chunkBlocks, laatste korter, offsets kloppen', () async {
      final disc = FakeDisc();
      final chunks = await collect(resilientBlockStream(
          ranges: [(first: 0, last: 24)], read: disc.read, chunkBlocks: 10));
      expect(chunks.map((c) => c.length ~/ kDvdBlockLen), [10, 10, 5]);
      expect(disc.log, [(0, 10), (10, 10), (20, 5)]);
      expect(blockAt(chunks[2], 4), 24);
    });

    test('celgrenzen gerespecteerd: geen lezen buiten first..last', () async {
      final disc = FakeDisc();
      await collect(resilientBlockStream(
          ranges: [(first: 100, last: 104), (first: 200, last: 201)],
          read: disc.read, chunkBlocks: 3));
      expect(disc.log, [(100, 3), (103, 2), (200, 2)]);
    });

    test('short read → doorgaan vanaf offset+n', () async {
      var first = true;
      Uint8List? read(int offset, int count) {
        if (first) {
          first = false;
          return blockData(offset, 3); // only 3 of the requested blocks
        }
        return blockData(offset, count);
      }
      final chunks = await collect(resilientBlockStream(
          ranges: [(first: 0, last: 9)], read: read, chunkBlocks: 10));
      expect(chunks.map((c) => c.length ~/ kDvdBlockLen), [3, 7]);
      expect(blockAt(chunks[1], 0), 3);
    });

    test('chunk faalt eenmaal en slaagt na retry (geen bisectie)', () async {
      final disc = FakeDisc(flakyOnce: {4});
      final stats = ReadStats();
      final chunks = await collect(resilientBlockStream(
          ranges: [(first: 0, last: 9)], read: disc.read, chunkBlocks: 10,
          chunkRetries: 1, stats: stats));
      expect(chunks, hasLength(1));
      expect(disc.calls, 2);
      expect(stats.retries, 1);
      expect(stats.badBlocks, 0);
    });

    test('blijvend falen → bisectie, stream levert toch alle bytes', () async {
      final disc = FakeDisc(bad: {4});
      final stats = ReadStats();
      final ranges = <(int, int)>[];
      final chunks = await collect(resilientBlockStream(
          ranges: [(first: 0, last: 9)], read: disc.read, chunkBlocks: 10,
          bisectSizes: const [4, 1], stats: stats,
          onBadRange: (f, l) => ranges.add((f, l))));
      final all = Uint8List.fromList(chunks.expand((c) => c).toList());
      expect(all.length, 10 * kDvdBlockLen);
      expect(isZeroBlock(all, 4), isTrue);
      expect(blockAt(all, 3), 3);
      expect(blockAt(all, 5), 5);
      expect(ranges, [(4, 4)]);
      expect(stats.badBlocks, 1);
      expect(stats.blocksRead, 9);
    });

    test('totaal bytes = blocks*2048 ook met slechte sectoren over celgrenzen', () async {
      final disc = FakeDisc(bad: {2, 11, 12});
      final chunks = await collect(resilientBlockStream(
          ranges: [(first: 0, last: 7), (first: 8, last: 15)],
          read: disc.read, chunkBlocks: 5, bisectSizes: const [2, 1]));
      final total = chunks.fold<int>(0, (n, c) => n + c.length);
      expect(total, 16 * kDvdBlockLen);
    });

    test('cap → DvdReadException uit de stream', () {
      final disc = FakeDisc(bad: {1, 2, 3});
      expect(
        collect(resilientBlockStream(
            ranges: [(first: 0, last: 7)], read: disc.read, chunkBlocks: 8,
            bisectSizes: const [1], maxBadBlocks: 1)),
        throwsA(isA<DvdReadException>()),
      );
    });
  });
}
