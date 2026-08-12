import 'dart:io';

import 'package:disc_buddy/src/subtitles/cc_extractor.dart';
import 'package:disc_buddy/src/subtitles/cc_format.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Synthetic MPEG-2 ES builders
// ---------------------------------------------------------------------------

/// Applies EIA-608 odd parity to a 7-bit value.
int parity(int b) {
  var bits = b & 0x7F, ones = 0;
  var v = bits;
  while (v != 0) { ones += v & 1; v >>= 1; }
  return ones.isOdd ? bits : bits | 0x80;
}

/// GOP header: 00 00 01 B8 + packed 32-bit timecode.
List<int> gop({int h = 0, int m = 0, int s = 0, int f = 0, bool drop = true}) {
  final w = ((drop ? 1 : 0) << 31) | (h << 26) | (m << 20) | (1 << 19) |
            (s << 13) | (f << 7);
  return [0x00, 0x00, 0x01, 0xB8,
          (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF];
}

List<int> pic() => [0x00, 0x00, 0x01, 0x00];

/// Builds 3-byte A/53 triples from EIA-608 pairs, applying odd parity.
List<int> triples(List<(int, int)> pairs, {int type = 0xFC}) => [
      for (final (b1, b2) in pairs) ...[type, parity(b1), parity(b2)],
    ];

/// Variant A — DVS 053 "CC" type 0x01: 43 43 01 F8 + count + triples.
List<int> userDataA(List<int> trip) => [
      0x00, 0x00, 0x01, 0xB2, 0x43, 0x43, 0x01, 0xF8,
      trip.length ~/ 3, ...trip,
    ];

/// Variant A packed — SCTE-20 style "CC" type 0x03: 43 43 03 + packed count.
List<int> userDataAPacked(List<int> trip) => [
      0x00, 0x00, 0x01, 0xB2, 0x43, 0x43, 0x03,
      0x80 | ((trip.length ~/ 3) << 1) | 0x01, ...trip,
    ];

/// Variant B — ATSC A/53 "GA94": 47 41 39 34 03 + packed count + triples.
List<int> userDataB(List<int> trip) => [
      0x00, 0x00, 0x01, 0xB2, 0x47, 0x41, 0x39, 0x34, 0x03,
      0x80 | ((trip.length ~/ 3) << 1) | 0x01, ...trip,
    ];

/// Variant C — signature-less (Sam & Cat): 00 00 00 00 + count + triples.
List<int> userDataC(List<int> trip) => [
      0x00, 0x00, 0x01, 0xB2, 0x00, 0x00, 0x00, 0x00,
      trip.length ~/ 3, ...trip,
    ];

/// ASCII user_data (encoder banner) — must never be detected as CC.
List<int> userDataAscii(String text) =>
    [0x00, 0x00, 0x01, 0xB2, ...text.codeUnits];

/// Pop-on "HELLO" load: RCL, PAC, characters, EOC. Control codes doubled as
/// real encoders do (the decoder deduplicates them).
List<(int, int)> popOnHello() => [
      (0x14, 0x20), (0x14, 0x20), // RCL
      (0x14, 0x50),               // PAC row 13
      (0x48, 0x45), (0x4C, 0x4C), (0x4F, 0x20), // "HELLO "
      (0x14, 0x2F), (0x14, 0x2F), // EOC — display
    ];

List<(int, int)> eraseDisplay() => [(0x14, 0x2E), (0x14, 0x2E)]; // EDM

/// One GOP: header + user_data (built by [wrap] from triples) + a picture.
List<int> gopWith(List<int> Function(List<int>) wrap, List<(int, int)> pairs,
        {int sec = 0}) =>
    [...gop(s: sec), ...wrap(triples(pairs)), ...pic()];

void feed(Mpeg2CcScanner sc, List<int> es, {int chunk = 4096}) {
  for (var i = 0; i < es.length; i += chunk) {
    sc.addChunk(es.sublist(i, i + chunk > es.length ? es.length : i + chunk));
  }
}

/// A caption stream in the given variant: HELLO shown at t≈0, erased at t≈4 s.
List<int> helloEs(List<int> Function(List<int>) wrap) => [
      ...gopWith(wrap, popOnHello(), sec: 0),
      ...gopWith(wrap, eraseDisplay(), sec: 4),
    ];

// ---------------------------------------------------------------------------

void main() {
  group('Mpeg2CcScanner extraction per variant', () {
    for (final (name, wrap) in [
      ('A (DVS 053)', userDataA),
      ('A packed (SCTE-20)', userDataAPacked),
      ('B (GA94)', userDataB),
      ('C (signature-less)', userDataC),
    ]) {
      test('variant $name yields HELLO caption', () {
        final sc = Mpeg2CcScanner();
        feed(sc, helloEs(wrap));
        final srt = sc.decoder.buildSrt();
        expect(srt, contains('HELLO'));
        expect(srt, contains('-->'));
        expect(sc.ccPacketsDetected, 2);
        expect(sc.nonNullCcPairs, greaterThan(0));
      });
    }

    test('variant C with interleaved DTVCC null triples yields HELLO', () {
      // Mirror the real disc shape: FE 00 00 null triples between 608 pairs.
      List<int> mixed(List<(int, int)> pairs) => [
            for (final (b1, b2) in pairs) ...[
              0xFE, 0x00, 0x00,
              0xFF, parity(b1), parity(b2),
            ],
          ];
      final es = [
        ...gop(s: 0), ...userDataC(mixed(popOnHello())), ...pic(),
        ...gop(s: 4), ...userDataC(mixed(eraseDisplay())), ...pic(),
      ];
      final sc = Mpeg2CcScanner();
      feed(sc, es);
      expect(sc.decoder.buildSrt(), contains('HELLO'));
    });

    test('empty variant-C channel: detected but no captions', () {
      // 30 triples of pure null padding per GOP, as on the real disc.
      final nulls = [
        for (var i = 0; i < 15; i++) ...[0xFE, 0x00, 0x00, 0xFF, 0x80, 0x80],
      ];
      final es = [
        for (var g = 0; g < 5; g++) ...[...gop(s: g), ...userDataC(nulls), ...pic()],
      ];
      final sc = Mpeg2CcScanner();
      feed(sc, es);
      expect(sc.decoder.buildSrt(), isEmpty);
      expect(sc.userDataPackets, 5);
      expect(sc.ccPacketsDetected, 5);
      expect(sc.nonNullCcPairs, 0);
    });

    test('byte-by-byte feeding matches bulk feeding', () {
      final es = helloEs(userDataC);
      final bulk = Mpeg2CcScanner()..addChunk(es);
      final drip = Mpeg2CcScanner();
      feed(drip, es, chunk: 1);
      expect(drip.decoder.buildSrt(), bulk.decoder.buildSrt());
    });
  });

  group('mid-row codes', () {
    // Pop-on load around [body]: RCL (doubled), PAC row 13, body, EOC (doubled).
    List<(int, int)> popOn(List<(int, int)> body) => [
          (0x14, 0x20), (0x14, 0x20),
          (0x14, 0x50),
          ...body,
          (0x14, 0x2F), (0x14, 0x2F),
        ];

    String srtFor(List<(int, int)> body) {
      final sc = Mpeg2CcScanner();
      feed(sc, [
        ...gopWith(userDataA, popOn(body), sec: 0),
        ...gopWith(userDataA, eraseDisplay(), sec: 4),
      ]);
      return sc.decoder.buildSrt();
    }

    test('renders as a space between words (doubled code → one space)', () {
      final srt = srtFor([
        (0x64, 0x6F),               // "do"
        (0x11, 0x20), (0x11, 0x20), // mid-row white, doubled
        (0x69, 0x74),               // "it"
      ]);
      expect(srt, contains('do it'));
      expect(srt, isNot(contains('do  it')));
    });

    test('italics open and close with spaces outside the tags', () {
      final srt = srtFor([
        (0x48, 0x69),               // "Hi"
        (0x11, 0x2E), (0x11, 0x2E), // mid-row italics
        (0x79, 0x6F),               // "yo"
        (0x11, 0x20), (0x11, 0x20), // mid-row white — resets italics
        (0x6F, 0x6B),               // "ok"
      ]);
      expect(srt, contains('Hi <i>yo</i> ok'));
    });

    test('italics running to end of line is closed at flush', () {
      final srt = srtFor([
        (0x48, 0x69),               // "Hi"
        (0x11, 0x2E), (0x11, 0x2E), // italics
        (0x79, 0x6F),               // "yo"
      ]);
      expect(srt, contains('Hi <i>yo</i>'));
      expect('<i>'.allMatches(srt).length, '</i>'.allMatches(srt).length);
    });

    test('mid-row at line start emits no leading space', () {
      final srt = srtFor([
        (0x11, 0x2E), (0x11, 0x2E), // italics before any text
        (0x79, 0x6F),               // "yo"
      ]);
      expect(srt, contains('\n<i>yo</i>\n'));
    });

    test('field-2 variant (b1 == 0x19) behaves identically', () {
      final srt = srtFor([
        (0x48, 0x69),               // "Hi"
        (0x19, 0x2E), (0x19, 0x2E), // italics, field-2 encoding
        (0x79, 0x6F),               // "yo"
      ]);
      expect(srt, contains('Hi <i>yo</i>'));
    });

    test('bare italics code with no following text leaves no dangling tag', () {
      final srt = srtFor([
        (0x48, 0x69),               // "Hi"
        (0x11, 0x2E), (0x11, 0x2E), // italics, then nothing
      ]);
      expect(srt, contains('Hi'));
      expect(srt, isNot(contains('<i>')));
    });
  });

  group('detectCcPayload', () {
    List<int> payloadOf(List<int> packet) => packet.sublist(4);

    test('fast path A: DVS 053 layout', () {
      final p = payloadOf(userDataA(triples(popOnHello())));
      final l = detectCcPayload(p, 0, p.length);
      expect(l, isNotNull);
      expect((l!.countOffset, l.scteStyle, l.tripleStart), (4, false, 5));
      expect(l.ccCount, popOnHello().length);
    });

    test('fast path B: GA94 layout', () {
      final p = payloadOf(userDataB(triples(popOnHello())));
      final l = detectCcPayload(p, 0, p.length);
      expect(l, isNotNull);
      expect((l!.countOffset, l.scteStyle, l.tripleStart), (5, true, 6));
      expect(l.ccCount, popOnHello().length);
    });

    test('variant C: structural detection at offset 4, plain count', () {
      final nulls = [
        for (var i = 0; i < 15; i++) ...[0xFE, 0x00, 0x00, 0xFF, 0x80, 0x80],
      ];
      final p = payloadOf(userDataC(nulls));
      final l = detectCcPayload(p, 0, p.length);
      expect(l, (countOffset: 4, scteStyle: false, tripleStart: 5, ccCount: 30));
    });

    test('zero count → null (fast path)', () {
      final p = [0x43, 0x43, 0x01, 0xF8, 0x00];
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('truncated triples → null (fast path)', () {
      final full = payloadOf(userDataA(triples(popOnHello())));
      final p = full.sublist(0, full.length - 2);
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('ASCII encoder banner → null', () {
      final p = 'encoded by SuperEncoder v1.0 build 42'.codeUnits;
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('count of 1 → null (generic requires ≥ 2 triples)', () {
      final p = [0x00, 0x01, 0xFC, parity(0x48), parity(0x45)];
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('excess trailing slack → null', () {
      final p = [
        0x00, 0x00, 0x00, 0x00, 0x02,
        0xFC, 0x80, 0x80, 0xFC, 0x80, 0x80,
        0x00, 0x00, 0x00, 0x00, // 4 bytes slack > 3
      ];
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('invalid triple type byte → null', () {
      final p = [
        0x00, 0x00, 0x00, 0x00, 0x02,
        0xFC, 0x80, 0x80, 0xFB, 0x80, 0x80, // 0xFB is not a CC triple type
      ];
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('even-parity data bytes → null (parity gate)', () {
      final p = [
        0x00, 0x00, 0x00, 0x00, 0x03,
        0xFC, 0x03, 0x03, 0xFC, 0x03, 0x03, 0xFC, 0x03, 0x03, // 0x03: even
      ];
      expect(detectCcPayload(p, 0, p.length), isNull);
    });

    test('all-FE payload passes vacuously (no 608 pairs to parity-check)', () {
      final p = [0x00, 0x00, 0x00, 0x00, 0x03,
                 0xFE, 0x11, 0x22, 0xFE, 0x33, 0x44, 0xFE, 0x55, 0x66];
      final l = detectCcPayload(p, 0, p.length);
      expect(l, isNotNull);
      expect(l!.ccCount, 3);
    });

    test('largest-coverage candidate wins', () {
      // Offset 0 (count 2) and offset 1 (count 3) are both viable; the
      // 3-triple reading covers more payload and must win.
      final p = [
        0x02, 0x03,
        0xFC, 0x80, 0x80, 0xFC, 0x80, 0x80, 0xFC, 0x80, 0x80,
      ];
      final l = detectCcPayload(p, 0, p.length);
      expect(l, isNotNull);
      expect((l!.countOffset, l.ccCount), (1, 3));
    });
  });

  group('stripMkvCcUserData', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cc_strip_test');
    });
    tearDown(() async => tmp.delete(recursive: true));

    List<int> filler(int n) => List.filled(n, 0xAB);

    test('neutralizes all variants, leaves ASCII user_data alone', () async {
      final trip = triples(popOnHello());
      final bytes = <int>[
        ...filler(50),
        ...userDataA(trip), ...pic(),
        ...filler(20),
        ...userDataB(trip), ...pic(),
        ...filler(20),
        ...userDataC(trip), ...pic(),
        ...filler(20),
        ...userDataAscii('encoded by SuperEncoder v1.0'), ...pic(),
        ...filler(50),
      ];
      final f = File('${tmp.path}/sample.bin');
      await f.writeAsBytes(bytes);

      await stripMkvCcUserData(f);
      final out = await f.readAsBytes();

      // Every user_data payload must no longer be detectable as CC.
      var found = 0;
      for (var i = 0; i + 4 < out.length; i++) {
        if (out[i] == 0x00 && out[i+1] == 0x00 &&
            out[i+2] == 0x01 && out[i+3] == 0xB2) {
          found++;
          var end = out.length;
          for (var j = i + 4; j + 2 < out.length; j++) {
            if (out[j] == 0x00 && out[j+1] == 0x00 && out[j+2] == 0x01) {
              end = j;
              break;
            }
          }
          expect(detectCcPayload(out, i + 4, end), isNull,
              reason: 'user_data at $i still detectable as CC');
        }
      }
      expect(found, 4);

      // ASCII banner content untouched.
      expect(String.fromCharCodes(out).contains('SuperEncoder'), isTrue);
      // Triple data itself untouched (only identifiers/count bytes patched).
      expect(out.length, bytes.length);
    });

    test('packet straddling a window boundary is neutralized', () async {
      const chunkSize = 64;
      final trip = triples(popOnHello());
      // Place a variant-C packet so its payload crosses the 64-byte boundary.
      final bytes = <int>[
        ...filler(60),
        ...userDataC(trip), ...pic(),
        ...filler(30),
      ];
      final f = File('${tmp.path}/straddle.bin');
      await f.writeAsBytes(bytes);

      await stripMkvCcUserData(f, chunkSize: chunkSize);
      final out = await f.readAsBytes();
      final payloadStart = 60 + 4;
      final payloadEnd   = 60 + userDataC(trip).length;
      expect(detectCcPayload(out, payloadStart, payloadEnd), isNull);
    });

    test('no shifted re-detection after stripping (FF-pair first triple)', () async {
      // Regression: zeroing only the cc_count byte left variant-C packets
      // whose first triple is an FF pair re-detectable at a shifted offset
      // (a triple data byte read as a plausible count). Full-payload zeroing
      // must leave nothing detectable at any offset.
      final trip = triples(
          [(0x14, 0x20), (0x79, 0x6F), (0x75, 0x2E), (0x94, 0x2C), (0x94, 0x2F)],
          type: 0xFF);
      // Interleave DTVCC nulls like the real disc: FF pair, FE 00 00, ...
      final mixed = <int>[];
      for (var i = 0; i < trip.length; i += 3) {
        mixed.addAll(trip.sublist(i, i + 3));
        mixed.addAll([0xFE, 0x00, 0x00]);
      }
      final bytes = <int>[
        ...filler(30),
        ...userDataC(mixed), ...pic(),
        ...filler(30),
      ];
      final f = File('${tmp.path}/shifted.bin');
      await f.writeAsBytes(bytes);

      await stripMkvCcUserData(f);
      final out = await f.readAsBytes();

      // Scan the whole file the way the extractor would: no user_data payload
      // may be detectable as CC, at its true offset or any shifted one.
      for (var i = 0; i + 4 < out.length; i++) {
        if (out[i] == 0x00 && out[i+1] == 0x00 &&
            out[i+2] == 0x01 && out[i+3] == 0xB2) {
          var end = out.length;
          for (var j = i + 4; j + 2 < out.length; j++) {
            if (out[j] == 0x00 && out[j+1] == 0x00 && out[j+2] == 0x01) {
              end = j;
              break;
            }
          }
          expect(detectCcPayload(out, i + 4, end), isNull);
          // The payload itself must be fully zeroed.
          expect(out.sublist(i + 4, end).every((b) => b == 0), isTrue);
        }
      }
      expect(out.length, bytes.length);
    });

    test('idempotent: second run leaves the file unchanged', () async {
      final bytes = <int>[
        ...filler(10),
        ...userDataA(triples(popOnHello())), ...pic(),
        ...userDataC(triples(popOnHello())), ...pic(),
        ...filler(10),
      ];
      final f = File('${tmp.path}/idem.bin');
      await f.writeAsBytes(bytes);

      await stripMkvCcUserData(f);
      final once = await f.readAsBytes();
      await stripMkvCcUserData(f);
      final twice = await f.readAsBytes();
      expect(twice, once);
    });
  });
}
