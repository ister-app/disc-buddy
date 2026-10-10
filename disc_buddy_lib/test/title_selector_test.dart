import 'package:disc_buddy/disc_buddy.dart';
import 'package:test/test.dart';

/// Builds a DvdTitle fixture with [audio]/[subs] synthetic stream tracks.
DvdTitle t({
  int vts = 1,
  required int pgc,
  int pgcs = 1,
  required Duration dur,
  List<Duration> chapters = const [],
  List<({int first, int last})> cells = const [],
  int audio = 1,
  int subs = 1,
}) =>
    DvdTitle(
      vtsNumber:   vts,
      pgcIndex:    pgc,
      pgcCount:    pgcs,
      duration:    dur,
      audioTracks: [
        for (var i = 0; i < audio; i++)
          AudioTrack(
              index: i, streamId: 0x80 + i, language: 'en',
              codec: 'ac3', channels: 2),
      ],
      subtitleTracks: [
        for (var i = 0; i < subs; i++)
          SubtitleTrack(index: i, streamId: 0x20 + i, language: 'en'),
      ],
      cells:    cells,
      chapters: chapters,
    );

Duration d(int min, int sec) => Duration(minutes: min, seconds: sec);

List<Duration> ch(List<(int, int)> ms) => [for (final e in ms) d(e.$1, e.$2)];

void main() {
  _fm20d3Tests();
  group('deduplicateDvdTitles — cell overlap authoritative', () {
    // Real data from DVD_VVE4698_2_SAMANDCAT_D2: 7 episodes stored as 7 PGCs
    // in one VTS, chapters authored at fixed ~5-minute intervals so that four
    // episodes' chapter timestamps all fall within 2 s of episode 1's.
    // Cells are disjoint cumulative ranges built from the real sector counts.
    final samAndCatD2 = [
      t(pgc: 0, pgcs: 7, dur: d(22, 36),
        chapters: ch([(0, 0), (4, 59), (9, 59), (14, 58), (19, 58), (22, 2), (22, 33)]),
        cells: [(first: 0, last: 462553)], subs: 0),
      t(pgc: 1, pgcs: 7, dur: d(22, 36),
        chapters: ch([(0, 0), (5, 0), (10, 0), (14, 59), (19, 59), (22, 3), (22, 33)]),
        cells: [(first: 462554, last: 923421)], subs: 0),
      t(pgc: 2, pgcs: 7, dur: d(22, 36),
        chapters: ch([(0, 0), (4, 59), (9, 59), (14, 59), (19, 58), (22, 3), (22, 35)]),
        cells: [(first: 923422, last: 1385105)], subs: 0),
      t(pgc: 3, pgcs: 7, dur: d(22, 41),
        chapters: ch([(0, 0), (4, 59), (9, 59), (14, 58), (19, 58), (22, 8), (22, 38)]),
        cells: [(first: 1385106, last: 1847854)], subs: 0),
      t(pgc: 4, pgcs: 7, dur: d(22, 37),
        chapters: ch([(0, 0), (5, 0), (9, 59), (14, 58), (19, 59), (22, 3), (22, 34)]),
        cells: [(first: 1847855, last: 2313550)], subs: 0),
      t(pgc: 5, pgcs: 7, dur: d(22, 36),
        chapters: ch([(0, 0), (5, 0), (9, 59), (14, 58), (19, 59), (22, 2), (22, 33)]),
        cells: [(first: 2313551, last: 2774512)], subs: 0),
      t(pgc: 6, pgcs: 7, dur: d(22, 26),
        chapters: ch([(0, 0), (4, 59), (9, 59), (14, 59), (19, 59), (21, 38), (22, 24)]),
        cells: [(first: 2774513, last: 3236173)], subs: 0),
    ];

    test('regression: episodes-as-PGCs with fixed-interval chapters keep all 7', () {
      expect(deduplicateDvdTitles(samAndCatD2).length, 7);
    });

    test('regression: autoSelectDvd offers all 7 episodes', () {
      final sel = autoSelectDvd(samAndCatD2);
      expect(sel.length, 7);
      expect(sel.map((x) => x.pgcIndex), [0, 1, 2, 3, 4, 5, 6]);
    });

    test('identical cells + matching chapters → non-primary removed', () {
      final chap = ch([(0, 0), (10, 0), (20, 0)]);
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 0, last: 500000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 0, last: 500000)]),
      ]);
      expect(result.length, 1);
      expect(result.single.pgcIndex, 0);
    });

    test('heavy overlap (interleaved angle blocks) → removed', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0),
          cells: [(first: 100, last: 100000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0),
          cells: [(first: 150, last: 100050)]),
      ]);
      expect(result.length, 1);
      expect(result.single.pgcIndex, 0);
    });

    test('cells override chapters: high overlap but chapters >2s apart → removed', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0),
          chapters: ch([(0, 0), (10, 0), (20, 0)]),
          cells: [(first: 0, last: 100000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0),
          chapters: ch([(0, 0), (12, 30), (24, 0)]),
          cells: [(first: 0, last: 100000)]),
      ]);
      expect(result.length, 1);
    });

    test('cells override chapters: disjoint cells but identical chapters → kept', () {
      final chap = ch([(0, 0), (10, 0), (20, 0)]);
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 0, last: 100000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 100001, last: 200000)]),
      ]);
      expect(result.length, 2);
    });

    test('play-all PGC not merged with episodes (asymmetric overlap)', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 4, dur: d(75, 0), cells: [(first: 0, last: 300000)]),
        t(pgc: 1, pgcs: 4, dur: d(25, 0), cells: [(first: 0, last: 99999)]),
        t(pgc: 2, pgcs: 4, dur: d(25, 0), cells: [(first: 100000, last: 199999)]),
        t(pgc: 3, pgcs: 4, dur: d(25, 0), cells: [(first: 200000, last: 300000)]),
      ]);
      expect(result.length, 4);
    });

    test('pgcIndex 0 always survives even as duplicate of another PGC', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0), cells: [(first: 0, last: 100000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0), cells: [(first: 0, last: 100000)]),
      ]);
      expect(result.map((x) => x.pgcIndex), contains(0));
    });
  });

  group('deduplicateDvdTitles — fallback without cell data (pinned behavior)', () {
    test('chapters match within 2s, no cells → removed', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0),
          chapters: ch([(0, 0), (10, 0), (20, 0)])),
        t(pgc: 1, pgcs: 2, dur: d(30, 5),
          chapters: ch([(0, 0), (10, 1), (20, 1)])),
      ]);
      expect(result.length, 1);
    });

    test('no chapters, no cells, duration within 1s → removed', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0)),
        t(pgc: 1, pgcs: 2, dur: d(30, 1)),
      ]);
      expect(result.length, 1);
    });

    test('no chapters, no cells, duration 3s apart → kept', () {
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0)),
        t(pgc: 1, pgcs: 2, dur: d(30, 3)),
      ]);
      expect(result.length, 2);
    });

    test('partial cell data (one side empty) → falls back to chapters', () {
      final chap = ch([(0, 0), (10, 0), (20, 0)]);
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 0, last: 100000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0), chapters: chap),
      ]);
      expect(result.length, 1);
    });

    test('degenerate cells (last < first) treated as missing → falls back', () {
      final chap = ch([(0, 0), (10, 0), (20, 0)]);
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 100, last: 50)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0), chapters: chap,
          cells: [(first: 200, last: 60)]),
      ]);
      expect(result.length, 1);
    });

    test('duplicated cell entries are union-counted, not summed', () {
      // The second PGC lists the same range twice; if sizes were summed its
      // union would appear 2× as large and the 80% both-sides test would fail.
      final result = deduplicateDvdTitles([
        t(pgc: 0, pgcs: 2, dur: d(30, 0), cells: [(first: 0, last: 100000)]),
        t(pgc: 1, pgcs: 2, dur: d(30, 0),
          cells: [(first: 0, last: 100000), (first: 0, last: 100000)]),
      ]);
      expect(result.length, 1);
    });
  });

  group('deduplicateDvdTitles — cross-VTS (cell logic must not apply)', () {
    test('matching chapters across VTS collapse despite disjoint cell numbers', () {
      final chap = ch([(0, 0), (10, 0), (20, 0)]);
      final result = deduplicateDvdTitles([
        t(vts: 1, pgc: 0, dur: d(30, 0), chapters: chap,
          cells: [(first: 0, last: 100000)]),
        t(vts: 2, pgc: 0, dur: d(30, 0), chapters: chap,
          cells: [(first: 500000, last: 600000)]),
      ]);
      expect(result.length, 1);
      expect(result.single.vtsNumber, 1);
    });

    test('clearly different chapters across VTS → both kept', () {
      final result = deduplicateDvdTitles([
        t(vts: 1, pgc: 0, dur: d(30, 0),
          chapters: ch([(0, 0), (10, 0), (20, 0)])),
        t(vts: 2, pgc: 0, dur: d(30, 0),
          chapters: ch([(0, 0), (13, 0), (24, 0)])),
      ]);
      expect(result.length, 2);
    });
  });

  group('extras stay in the list', () {
    // Real layout of ICARLY_S1_V1_D2: VTS 1 holds 6 episodes + a play-all PGC,
    // VTS 2 holds 12 bonus clips, VTS 4 a 35 s stinger.  These used to be
    // hidden by the (now removed) per-VTS display filter, which dropped every
    // VTS that contributed no title to the suggestion.
    const epSectors = [432875, 432969, 432996, 432946, 432511, 433295];
    final epCells = <({int first, int last})>[];
    for (var i = 0, start = 0; i < epSectors.length; i++) {
      epCells.add((first: start, last: start + epSectors[i] - 1));
      start += epSectors[i];
    }

    const extraSpecs = [
      (168, 53894), (399, 128370), (116, 37112), (75, 24171),
      (101, 32499), (102, 32852), (104, 33396), (102, 32920),
      (102, 32873), (96, 30705), (106, 34028), (101, 32493),
    ];
    final extras = <DvdTitle>[];
    for (var i = 0, start = 0; i < extraSpecs.length; i++) {
      final (secs, sectors) = extraSpecs[i];
      extras.add(t(
        vts: 2, pgc: i, pgcs: extraSpecs.length,
        dur: Duration(seconds: secs), subs: 0,
        cells: [(first: start, last: start + sectors - 1)],
      ));
      start += sectors;
    }

    final icarlyD2 = [
      for (var i = 0; i < epSectors.length; i++)
        t(pgc: i, pgcs: 7, dur: d(23, 35), subs: 0, cells: [epCells[i]]),
      t(pgc: 6, pgcs: 7, dur: d(141, 30), subs: 0, cells: epCells),
      ...extras,
      t(vts: 4, pgc: 0, dur: d(0, 35), subs: 0,
        cells: [(first: 0, last: 11477)]),
    ];

    test('bonus VTS groups survive deduplication', () {
      final result = deduplicateDvdTitles(icarlyD2);
      expect(result.length, 20);
      expect(result.where((x) => x.vtsNumber == 1).length, 7);
      expect(result.where((x) => x.vtsNumber == 2).length, 12);
      expect(result.where((x) => x.vtsNumber == 4).length, 1);
    });

    test('autoSelectDvd still suggests only the 6 episodes', () {
      final sel = autoSelectDvd(icarlyD2);
      expect(sel.map((x) => x.displayKey),
          ['1.1', '1.2', '1.3', '1.4', '1.5', '1.6']);
    });

    test('minorTitleKeys leaves the same 9 titles MakeMKV lists', () {
      final deduped = deduplicateDvdTitles(icarlyD2);
      final minor = minorTitleKeys(deduped, autoSelectDvd(deduped));
      final listed = deduped
          .where((x) => !minor.contains(x.displayKey))
          .map((x) => x.displayKey);
      expect(listed, [
        '1.1', '1.2', '1.3', '1.4', '1.5', '1.6', '1.7', // episodes + play-all
        '2.1', '2.2',                                    // 2:48 and 6:39 extras
      ]);
    });

    test('minorTitleKeys never hides a suggested title', () {
      final shorts = [
        t(pgc: 0, pgcs: 3, dur: d(1, 30), cells: [(first: 0, last: 1000)]),
        t(pgc: 1, pgcs: 3, dur: d(1, 30), cells: [(first: 2000, last: 3000)]),
        t(pgc: 2, pgcs: 3, dur: d(1, 30), cells: [(first: 4000, last: 5000)]),
      ];
      expect(minorTitleKeys(shorts, shorts), isEmpty);
      expect(minorTitleKeys(shorts, const []),
          {'1.1', '1.2', '1.3'});
    });
  });

  group('deduplicateDvdTitles — edge cases', () {
    test('empty input → empty output', () {
      expect(deduplicateDvdTitles([]), isEmpty);
    });

    test('single title passes through', () {
      final result = deduplicateDvdTitles([t(pgc: 0, dur: d(90, 0))]);
      expect(result.length, 1);
    });
  });
}

void _fm20d3Tests() {
  group('episode without subtitle track still counts as an episode', () {
    // Real layout of FM20_DVD3: three episodes in separate VTS sections, the
    // first of which carries no subtitle stream.  The stream-count filter used
    // to drop it, leaving two titles — below the series threshold — so only
    // the longest episode was suggested.
    final fm20d3 = [
      t(vts: 1, pgc: 0, dur: d(0, 14), subs: 0, cells: [(first: 0, last: 1543)]),
      t(vts: 2, pgc: 0, dur: d(46, 51), subs: 0,
        chapters: ch([(0, 0), (10, 0), (20, 0), (30, 0), (40, 0)]),
        cells: [(first: 0, last: 982914)]),
      t(vts: 3, pgc: 0, dur: d(47, 53), subs: 1,
        chapters: ch([(0, 0), (9, 0), (19, 0), (29, 0), (39, 0)]),
        cells: [(first: 0, last: 1003945)]),
      t(vts: 4, pgc: 0, dur: d(50, 20), subs: 1,
        chapters: ch([(0, 0), (11, 0), (21, 0), (31, 0), (41, 0)]),
        cells: [(first: 0, last: 1055866)]),
    ];

    test('autoSelectDvd suggests all three episodes', () {
      expect(autoSelectDvd(fm20d3).map((x) => x.displayKey), ['2', '3', '4']);
    });

    test('short stripped-down extras are still kept out', () {
      final withExtras = [
        ...fm20d3,
        t(vts: 5, pgc: 0, dur: d(8, 0), subs: 0, audio: 1,
          cells: [(first: 0, last: 100000)]),
        t(vts: 6, pgc: 0, dur: d(12, 0), subs: 0, audio: 1,
          cells: [(first: 0, last: 150000)]),
      ];
      expect(autoSelectDvd(withExtras).map((x) => x.displayKey), ['2', '3', '4']);
    });
  });
}
