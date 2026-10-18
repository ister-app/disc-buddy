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

class FakeProbe extends DurationProbe {
  FakeProbe(this.secs) : super(ffprobe: 'ffprobe');
  final Map<String, double> secs;
  @override
  Future<double?> secondsOf(File mediaFile) async => secs[mediaFile.path];
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
];

({
  EpisodeMatcher matcher,
  FakeLlm llm,
  List<String> logs,
  List<NamingItem> items,
  Map<int, SubtitleText> subs,
  Map<int, Fingerprint> fps,
})
setup(int count, {Map<String, double>? durations}) {
  final llm = FakeLlm();
  final logs = <String>[];
  final items = <NamingItem>[
    for (var i = 0; i < count; i++)
      (file: File('/v/title_0${i + 1}.mkv'), discName: 'D1', srts: <File>[]),
  ];
  final matcher = EpisodeMatcher(
    tmdb: TmdbClient(
      token: 't',
      httpClient: MockClient((_) async => http.Response('{}', 404)),
    ),
    llm: llm,
    prompter: const NonInteractivePrompter(),
    probe: FakeProbe(durations ?? {for (final it in items) it.file.path: 1320}),
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
    EpisodeMatcher matcher,
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

void main() {
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
