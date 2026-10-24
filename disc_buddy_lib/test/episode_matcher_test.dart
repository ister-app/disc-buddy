import 'dart:io';

import 'package:disc_buddy/src/naming/duration_probe.dart';
import 'package:disc_buddy/src/naming/episode_matcher.dart';
import 'package:disc_buddy/src/naming/episode_math.dart';
import 'package:disc_buddy/src/naming/llm_client.dart';
import 'package:disc_buddy/src/naming/naming_types.dart';
import 'package:disc_buddy/src/naming/tmdb_client.dart';
import 'package:disc_buddy/src/utils/prompter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Scripted LLM: answers are queued per question kind, recognised by the
/// system prompt. Records every user message so tests can inspect the
/// candidate list a call was given.
class FakeLlm extends LlmClient {
  FakeLlm() : super(baseUrl: 'http://fake', apiKey: 'x', model: 'fake');

  final match = <String>[];
  final verify = <String>[];
  final conflict = <String>[];
  final matchPrompts = <String>[];
  final systemPrompts = <String>[];

  @override
  Future<String?> chat(
    List<Map<String, String>> messages, {
    Duration timeout = const Duration(minutes: 5),
    int? maxTokens,
    List<String>? stop,
    double temperature = 0.1,
    bool jsonMode = false,
  }) async {
    final system = messages.first['content']!;
    final user = messages.last['content']!;
    if (system.startsWith('You identify which TV episode a subtitle')) {
      matchPrompts.add(user);
      systemPrompts.add(system);
      return match.isEmpty ? '{"pick":0}' : match.removeAt(0);
    }
    if (system.startsWith('You identify which TV episode a plot summary')) {
      return verify.isEmpty ? '{"pick":0}' : verify.removeAt(0);
    }
    if (system.startsWith('Two subtitle summaries')) {
      return conflict.isEmpty ? null : conflict.removeAt(0);
    }
    throw StateError('unexpected prompt: $system');
  }
}

/// Matcher whose season-0 list is scripted, so no HTTP or on-disk TMDB
/// cache is touched; records how often specials were requested.
class TestMatcher extends EpisodeMatcher {
  TestMatcher({
    required super.tmdb,
    required super.llm,
    required super.prompter,
    required super.probe,
    required super.log,
    this.specials = const [],
  });
  final List<SeasonEpisode> specials;
  int specialsRequests = 0;
  @override
  Future<List<SeasonEpisode>> fetchSpecials(int seriesId, String subLang) async {
    specialsRequests++;
    return specials;
  }
}

class FakeProbe extends DurationProbe {
  FakeProbe(this.secs, {this.audio = const {}}) : super(ffprobe: 'ffprobe');
  final Map<String, double> secs;
  final Map<String, List<String>> audio;
  @override
  Future<MediaInfo> infoOf(File mediaFile) async => (
    seconds: secs[mediaFile.path],
    audioLanguages: audio[mediaFile.path] ?? const [],
  );
}

SeasonEpisode ep(int n, String title, {int season = 7, int? runtime}) => (
  season: season,
  ep: (
    number: n,
    title: title,
    overview: 'Overview of $title',
    guestStars: '',
    airDate: '',
    runtime: runtime,
  ),
);

final episodes = [
  ep(1, 'Die Verlobung'),
  ep(2, 'Die Verschiebung'),
  ep(3, 'Der Maestro'),
  ep(4, 'Das Zwinkern'),
];

/// Distinct subtitle texts (no two are near-duplicates or ≥ 0.5 similar).
const texts = [
  'George proposes to Susan after a lunch with Jerry about commitment pacts.',
  'Elaine argues with a rabbi while Kramer paints lines on a parking garage.',
  'Bob Cobb insists on being called Maestro; Jerry doubts Tuscany has no villas.',
  'Jerry winks because of grapefruit juice and ruins a Yankees birthday card.',
  'Kramer, Newman and Jerry answer fan questions at a reunion on a sound stage.',
];

final special = ep(5, 'Reunion Special', season: 0);

({
  TestMatcher matcher,
  FakeLlm llm,
  List<String> logs,
  List<NamingItem> items,
  Map<int, SubtitleText> subs,
  Map<int, Fingerprint> fps,
})
setup(
  int count, {
  Map<String, double>? durations,
  Map<String, List<String>> audio = const {},
  List<SeasonEpisode> specials = const [],
}) {
  final llm = FakeLlm();
  final logs = <String>[];
  final items = <NamingItem>[
    for (var i = 0; i < count; i++)
      (file: File('/v/title_0${i + 1}.mkv'), discName: 'D1', srts: <File>[]),
  ];
  final matcher = TestMatcher(
    specials: specials,
    tmdb: TmdbClient(
      token: 't',
      httpClient: MockClient((_) async => http.Response('{}', 404)),
    ),
    llm: llm,
    prompter: const NonInteractivePrompter(),
    probe: FakeProbe(
      durations ?? {for (final it in items) it.file.path: 1320},
      audio: audio,
    ),
    log: (m, {bool isError = false}) => logs.add(m),
  );
  return (
    matcher: matcher,
    llm: llm,
    logs: logs,
    items: items,
    subs: {for (var i = 0; i < count; i++) i: (text: texts[i], language: 'de')},
    fps: {
      for (var i = 0; i < count; i++)
        i: Fingerprint(
          summary: 'Summary ${i + 1}: ${texts[i]}',
          titleGuess: 'Seinfeld',
        ),
    },
  );
}

Future<Map<int, String?>> run(
  ({
    TestMatcher matcher,
    FakeLlm llm,
    List<String> logs,
    List<NamingItem> items,
    Map<int, SubtitleText> subs,
    Map<int, Fingerprint> fps,
  })
  s,
) async {
  final picks = await s.matcher.matchEpisodesPerFile(
    episodes: episodes,
    items: s.items,
    subs: s.subs,
    fps: s.fps,
    seriesId: 1400,
    subLang: 'de',
  );
  return {for (final e in picks.entries) e.key: e.value?.stem};
}

const tagged = ['eng', 'fre', 'ger'];

void main() {
  group('matchEpisodesPerFile bonus material and specials', () {
    test('a single-track file skips matching and is not gap filled',
        () async {
      final s = setup(4, audio: {
        '/v/title_01.mkv': tagged,
        '/v/title_02.mkv': const ['eng'],
        '/v/title_03.mkv': tagged,
        '/v/title_04.mkv': tagged,
      });
      s.llm.match.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}']);
      s.llm.verify.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}']);

      expect(await run(s), {0: 's07e01', 1: null, 2: 's07e03', 3: 's07e04'});
      expect(s.llm.matchPrompts, hasLength(3));
      expect(
        s.logs,
        anyElement(contains(
          '/v/title_02.mkv: audio layout 1 track (eng) differs from the '
          'other files (3 tracks (eng, fre, ger)) — likely bonus material',
        )),
      );
      // Flagged as bonus, so season 0 was consulted (and found empty).
      expect(s.matcher.specialsRequests, 1);
    });

    test('a bonus-layout file is named from season 0 when a special fits',
        () async {
      final s = setup(4, audio: {
        '/v/title_01.mkv': tagged,
        '/v/title_02.mkv': const ['eng'],
        '/v/title_03.mkv': tagged,
        '/v/title_04.mkv': tagged,
      }, specials: [special]);
      s.llm.match.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);
      s.llm.verify.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);

      expect(await run(s), {0: 's07e01', 1: 's00e05', 2: 's07e03', 3: 's07e04'});
      expect(s.llm.matchPrompts.last, contains('s00e05'));
      expect(s.llm.matchPrompts.last, isNot(contains('s07e01')));
      expect(s.llm.systemPrompts.last, contains('DVD bonus features'));
    });

    test('specials that mention the season are offered before the rest',
        () async {
      final s = setup(4, audio: {
        '/v/title_01.mkv': tagged,
        '/v/title_02.mkv': const ['eng'],
        '/v/title_03.mkv': tagged,
        '/v/title_04.mkv': tagged,
      }, specials: [special, ep(6, 'Bloopers (Season 7)', season: 0)]);
      s.llm.match.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);
      s.llm.verify.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);

      expect(await run(s), {0: 's07e01', 1: 's00e06', 2: 's07e03', 3: 's07e04'});
      expect(s.llm.matchPrompts.last, contains('s00e06'));
      expect(s.llm.matchPrompts.last, isNot(contains('s00e05')));
      expect(s.logs, anyElement(contains('1 of 2 refer to season 7')));
    });

    test('a file whose verification contradicted its match is re-matched '
        'among the open episodes at the end', () async {
      final s = setup(4);
      // File 1 is matched to e04 but the blind check says e01; the other
      // three files take e02–e04. The post-pass then offers file 1 only
      // e01, which it accepts and the blind check confirms.
      s.llm.match.addAll(
          ['{"pick":4}', '{"pick":2}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);
      s.llm.verify.addAll(
          ['{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);

      expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03', 3: 's07e04'});
      expect(s.llm.matchPrompts.last, contains('1. s07e01'));
      expect(s.llm.matchPrompts.last, isNot(contains('s07e02')));
    });

    test('a special needs positive confirmation, not just no contradiction',
        () async {
      final s = setup(4, audio: {
        '/v/title_01.mkv': tagged,
        '/v/title_02.mkv': const ['eng'],
        '/v/title_03.mkv': tagged,
        '/v/title_04.mkv': tagged,
      }, specials: [special]);
      s.llm.match.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);
      // Verification of the special is inconclusive (pick 0).
      s.llm.verify.addAll(['{"pick":1}', '{"pick":3}', '{"pick":4}', '{"pick":0}']);

      expect(await run(s), {0: 's07e01', 1: null, 2: 's07e03', 3: 's07e04'});
      expect(
        s.logs,
        anyElement(contains('could not confirm s00e05 "Reunion Special"')),
      );
    });

    test('an unmatched file that fits the season is re-matched among the '
        'unclaimed episodes instead of trying specials', () async {
      final s = setup(4, specials: [special]);
      // File 4 declines twice (plain + name-dense retry), then accepts the
      // only open episode when offered just that.
      s.llm.match.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":0}', '{"pick":0}',
        '{"pick":1}',
      ]);
      s.llm.verify.addAll(['{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":4}']);

      expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03', 3: 's07e04'});
      expect(s.matcher.specialsRequests, 0);
      expect(
        s.logs,
        anyElement(contains(
            '/v/title_04.mkv fits the season by length and audio layout')),
      );
      final rematch = s.llm.matchPrompts.last;
      expect(rematch, contains('1. s07e04'));
      expect(rematch, isNot(contains('s07e01')));
    });

    test('after a declined re-match the last open episode is claimed by '
        'elimination when the blind summary match agrees', () async {
      final s = setup(4, specials: [special]);
      s.llm.match.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":0}', '{"pick":0}',
        '{"pick":0}', '{"pick":0}',
      ]);
      // Three regular verifications, then the blind check names e04.
      s.llm.verify.addAll(
          ['{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":4}']);

      expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03', 3: 's07e04'});
      expect(s.matcher.specialsRequests, 0);
      expect(
        s.logs,
        anyElement(contains('/v/title_04.mkv → s07e04 "Das Zwinkern" by '
            'elimination')),
      );
    });

    test('elimination is refused when the blind summary match disagrees',
        () async {
      final s = setup(4, specials: [special]);
      s.llm.match.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":0}', '{"pick":0}',
        '{"pick":0}', '{"pick":0}',
      ]);
      s.llm.verify.addAll(
          ['{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":2}']);

      expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03', 3: null});
    });

    test('elimination hands the single open episode to one file only',
        () async {
      // Five files, four episodes; files 4 and 5 both decline every match.
      // File 4 takes the last open episode by elimination, file 5 then
      // finds nothing open and stays unnamed.
      final s = setup(5, specials: [special]);
      s.llm.match.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}',
        '{"pick":0}', '{"pick":0}', // file 4 declines
        '{"pick":0}', '{"pick":0}', // file 5 declines
        '{"pick":0}', '{"pick":0}', // file 4 re-match declines
        '{"pick":0}', '{"pick":0}', // file 5 re-match declines
      ]);
      s.llm.verify.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}',
        '{"pick":4}', // blind check for file 4 → e04
      ]);

      expect(await run(s), {
        0: 's07e01', 1: 's07e02', 2: 's07e03', 3: 's07e04', 4: null,
      });
    });

    test('an unmatched file far from the median length does try specials',
        () async {
      final s = setup(
        4,
        durations: {
          '/v/title_01.mkv': 1320,
          '/v/title_02.mkv': 1320,
          '/v/title_03.mkv': 1320,
          '/v/title_04.mkv': 3000,
        },
        specials: [special],
      );
      s.llm.match.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":0}', '{"pick":0}',
        '{"pick":1}',
      ]);
      s.llm.verify.addAll(['{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":1}']);

      expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03', 3: 's00e05'});
      expect(s.matcher.specialsRequests, 1);
    });

    test('once every regular episode is claimed, the leftover tries specials',
        () async {
      final s = setup(5, specials: [special]);
      s.llm.match.addAll([
        '{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":4}',
        '{"pick":0}', '{"pick":0}', '{"pick":1}',
      ]);
      s.llm.verify.addAll(
          ['{"pick":1}', '{"pick":2}', '{"pick":3}', '{"pick":4}', '{"pick":1}']);

      expect(await run(s), {
        0: 's07e01', 1: 's07e02', 2: 's07e03', 3: 's07e04', 4: 's00e05',
      });
    });
  });

  group('matchEpisodesPerFile conflicts', () {
    test(
      'unplaceable second file is re-matched among unclaimed episodes',
      () async {
        final s = setup(2);
        s.llm.match.addAll(['{"pick":1}', '{"pick":1}', '{"pick":1}']);
        s.llm.verify.addAll(['{"pick":1}', '{"pick":2}']);
        s.llm.conflict.add('{"first":1,"second":0}');

        expect(await run(s), {0: 's07e01', 1: 's07e02'});
        // The re-match offered only the open episodes: no s07e01 in the list.
        final rematch = s.llm.matchPrompts.last;
        expect(rematch, isNot(contains('s07e01')));
        expect(rematch, contains('1. s07e02'));
        expect(
          s.logs,
          anyElement(contains('Re-match: /v/title_02.mkv → s07e02')),
        );
      },
    );

    test(
      'failed disambiguation (no answer) also falls back to a re-match',
      () async {
        final s = setup(2);
        s.llm.match.addAll(['{"pick":1}', '{"pick":1}', '{"pick":2}']);
        s.llm.verify.addAll(['{"pick":1}', '{"pick":0}']);
        // conflict queue empty → resolveStemConflict returns null
        expect(await run(s), {0: 's07e01', 1: 's07e03'});
      },
    );

    test(
      'a single gap between named neighbours is filled by elimination',
      () async {
        final s = setup(3);
        // File 1 collides with file 0 on e01, the disambiguation keeps file 0
        // and cannot place file 1, and the re-match declines twice.
        s.llm.match.addAll([
          '{"pick":1}', // file 0 → e01
          '{"pick":1}', // file 1 → e01 (conflict)
          '{"pick":0}', '{"pick":0}', // re-match declines twice
          '{"pick":3}', // file 2 → e03
        ]);
        s.llm.verify.addAll(['{"pick":1}', '{"pick":3}']);
        s.llm.conflict.add('{"first":1,"second":0}');

        expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03'});
        expect(
          s.logs,
          anyElement(contains('by elimination (neighbours s07e01 and s07e03)')),
        );
      },
    );

    test('gap filling skips a file far longer than a single episode', () async {
      final s = setup(
        3,
        durations: {
          '/v/title_01.mkv': 1320,
          '/v/title_02.mkv': 3000, // > 1.5× median
          '/v/title_03.mkv': 1320,
        },
      );
      // The LLM declines file 1 outright (twice); specials are empty and the
      // non-interactive prompter picks nothing, so only gap filling could
      // name it — and must not, given its length.
      s.llm.match.addAll([
        '{"pick":1}',
        '{"pick":0}',
        '{"pick":0}',
        '{"pick":3}',
      ]);
      s.llm.verify.addAll(['{"pick":1}', '{"pick":3}']);

      expect(await run(s), {0: 's07e01', 1: null, 2: 's07e03'});
    });

    test(
      'earlier claimant is not moved onto a stem another file holds',
      () async {
        final s = setup(3);
        s.llm.match.addAll(['{"pick":1}', '{"pick":2}', '{"pick":1}']);
        s.llm.verify.addAll(['{"pick":1}', '{"pick":2}', '{"pick":3}']);
        // LLM wants file 0 → e02 (held by file 1) and file 2 → e03.
        s.llm.conflict.add('{"first":2,"second":3}');

        expect(await run(s), {0: 's07e01', 1: 's07e02', 2: 's07e03'});
        expect(
          s.logs,
          anyElement(contains('s07e02 already belongs to /v/title_02.mkv')),
        );
      },
    );

    test(
      'verification contradiction naming a claimed episode is accepted',
      () async {
        final s = setup(2);
        s.llm.match.addAll(['{"pick":1}', '{"pick":2}']);
        s.llm.verify.addAll(['{"pick":1}', '{"pick":1}']); // 2nd says e01 again
        expect(await run(s), {0: 's07e01', 1: 's07e02'});
        expect(
          s.logs,
          anyElement(
            contains('already taken by another file — accepting s07e02'),
          ),
        );
      },
    );
  });

  group('fillSingleGaps', () {
    EpisodePick pk(int n, [int? end]) => EpisodePick(
      stem: episodeStem(7, n, end),
      title: 't',
      season: 7,
      ep: n,
      epEnd: end,
    );

    test('fills only when the neighbours are exactly two apart', () {
      final fills = fillSingleGaps(
        count: 5,
        picks: {0: pk(1), 1: null, 2: pk(3), 3: null, 4: pk(4)},
        eligible: {1, 3},
        episodes: episodes,
        durations: const {},
        medianSecs: null,
      );
      expect(fills.keys, [1]);
      expect(fills[1]!.stem, 's07e02');
    });

    test('respects ranges, claimed episodes and eligibility', () {
      // Range s07e01-e02 before, s07e04 after → gap is e03.
      expect(
        fillSingleGaps(
          count: 3,
          picks: {0: pk(1, 2), 1: null, 2: pk(4)},
          eligible: {1},
          episodes: episodes,
          durations: const {},
          medianSecs: null,
        )[1]!.stem,
        's07e03',
      );
      // Gap episode already claimed elsewhere → nothing.
      expect(
        fillSingleGaps(
          count: 4,
          picks: {0: pk(1), 1: null, 2: pk(3), 3: pk(2)},
          eligible: {1},
          episodes: episodes,
          durations: const {},
          medianSecs: null,
        ),
        isEmpty,
      );
      // Not eligible (duplicate copy) → nothing.
      expect(
        fillSingleGaps(
          count: 3,
          picks: {0: pk(1), 1: null, 2: pk(3)},
          eligible: const {},
          episodes: episodes,
          durations: const {},
          medianSecs: null,
        ),
        isEmpty,
      );
    });
  });

  test('42-minute file over a two-part group becomes a range (Cadillac)', () {
    final s7 = [
      ep(13, 'Das Fahrrad'),
      ep(14, 'Der Cadillac (1)'),
      ep(15, 'Der Cadillac (2)'),
      ep(16, 'Der Duschkopf'),
    ];
    expect(
      refineWithDuration(
        episodes: s7,
        season: 7,
        epNumber: 14,
        durationSecs: 2537,
        medianSecs: 1316,
      ),
      (epStart: 14, epEnd: 15, playAll: false),
    );
    // And the 22-minute "Das Fahrrad" stays single.
    expect(
      refineWithDuration(
        episodes: s7,
        season: 7,
        epNumber: 13,
        durationSecs: 1316,
        medianSecs: 1316,
      ),
      (epStart: 13, epEnd: 13, playAll: false),
    );
  });
}
