import 'dart:typed_data';

import 'package:disc_buddy/src/rippers/dvd_stream_map.dart';
import 'package:test/test.dart';

/// One 2048-byte DVD pack: pack header + a single PES packet filling the rest.
Uint8List _pack(int streamId, List<int> pesBody) {
  final pack = Uint8List(2048);
  pack.setAll(0, [0x00, 0x00, 0x01, 0xBA, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xC3, 0xF8]);
  final pesLen = 2048 - 14 - 6;
  pack.setAll(14, [0x00, 0x00, 0x01, streamId, pesLen >> 8, pesLen & 0xFF]);
  pack.setAll(20, pesBody);
  return pack;
}

/// Private-stream-1 pack carrying sub-stream [sid].
Uint8List _private(int sid) => _pack(0xBD, [0x81, 0x80, 0x05, 0x21, 0, 1, 0, 1, sid]);

/// Video pack whose payload holds [payload] at [at] (offset within the pack).
Uint8List _video({List<int> payload = const [], int at = 40}) {
  final pack = _pack(0xE0, [0x81, 0x80, 0x05, 0x21, 0, 1, 0, 1]);
  pack.setAll(at, payload);
  return pack;
}

/// A private-stream-1 header lookalike announcing sub-stream [sid].
List<int> _fake(int sid) => [0x00, 0x00, 0x01, 0xBD, 0x5F, 0xB0, 0x0E, 0x10, 0x00, sid];

Stream<List<int>> _chunks(List<Uint8List> packs, int chunkSize) async* {
  final all = Uint8List.fromList([for (final p in packs) ...p]);
  for (var o = 0; o < all.length; o += chunkSize) {
    yield Uint8List.sublistView(
        all, o, o + chunkSize > all.length ? all.length : o + chunkSize);
  }
}

void main() {
  group('scanVobSids', () {
    test('reports sub-streams in order of first appearance', () async {
      final packs = [_video(), _private(0x80), _video(), _private(0x21),
                     _private(0x80), _private(0x20)];
      final scan = await scanVobSids(_chunks(packs, 4096), {0x80, 0x20, 0x21});
      expect(scan.sidOrder, [0x80, 0x21, 0x20]);
      expect(scan.lastSidByteOffset, 5 * 2048 + 14 + 9 + 5);
    });

    test('ignores a private-stream start code inside a video packet', () async {
      // Mad Men S1 disc 3: 00 00 01 BD inside video data read as subtitle
      // sub-stream 0x34, which pushed the real 0x20 to index 1.
      final packs = [_private(0x80), _video(payload: _fake(0x34)),
                     _video(payload: _fake(0x2A), at: 21), _private(0x20)];
      for (final chunkSize in [2048, 4096, 1000, 2069, 37]) {
        final scan = await scanVobSids(_chunks(packs, chunkSize), {0x80, 0x20});
        expect(scan.sidOrder, [0x80, 0x20], reason: 'chunk size $chunkSize');
      }
    });

    test('finds a header split across chunks', () async {
      final packs = [_video(), _private(0x80), _private(0x20)];
      for (var chunkSize = 1; chunkSize < 60; chunkSize++) {
        final scan = await scanVobSids(_chunks(packs, chunkSize), {0x80, 0x20});
        expect(scan.sidOrder, [0x80, 0x20], reason: 'chunk size $chunkSize');
        expect(scan.lastSidByteOffset, 2 * 2048 + 14 + 9 + 5,
            reason: 'chunk size $chunkSize');
      }
    });

    test('resynchronises after zero-filled sectors', () async {
      final packs = [_private(0x80), Uint8List(2048), Uint8List(2048), _private(0x20)];
      final scan = await scanVobSids(_chunks(packs, 3000), {0x80, 0x20});
      expect(scan.sidOrder, [0x80, 0x20]);
    });
  });
}
