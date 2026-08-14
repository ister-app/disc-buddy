import 'package:disc_buddy/src/naming/auto_namer.dart';
import 'package:disc_buddy/src/naming/tmdb_client.dart';
import 'package:test/test.dart';

({int season, EpisodeInfo ep}) _ep(
  int number,
  String overview, {
  int season = 1,
  String? title,
  int? runtime,
}) => (
      season: season,
      ep: (
        number: number,
        title: title ?? 'Episode $number',
        overview: overview,
        guestStars: '',
        airDate: '',
        runtime: runtime,
      ),
    );

void main() {
  group('AutoNamer.filterEpisodesBySimilarity', () {
    final episodes = [
      _ep(1, 'Sam moves in with Cat and they start a babysitting business.'),
      _ep(2, 'Cat becomes obsessed with her favorite television show.'),
      _ep(3, 'Two British sisters trick Sam and Cat out of their money.'),
      _ep(4, 'Dice buys a goat and the girls have to babysit it.'),
      _ep(5, 'Sam enters a texting competition against a speed champion.'),
    ];

    test('returns list unchanged when within maxEpisodes', () {
      final result = AutoNamer.filterEpisodesBySimilarity(
        episodes,
        ['a goat eats everything in the apartment'],
        maxEpisodes: 5,
      );
      expect(result, same(episodes));
    });

    test('returns list unchanged when summaries are empty', () {
      final result = AutoNamer.filterEpisodesBySimilarity(
        episodes,
        [],
        maxEpisodes: 2,
      );
      expect(result, same(episodes));
    });

    test('keeps the best-matching episodes when over the cap', () {
      final result = AutoNamer.filterEpisodesBySimilarity(
        episodes,
        ['Dice buys a goat and the girls babysit the goat'],
        maxEpisodes: 2,
      );
      expect(result, hasLength(2));
      expect(result.map((e) => e.ep.number), contains(4));
    });

    test('maxEpisodes above list length keeps every episode', () {
      // Regression: 35 files used to be filtered down to 25 candidates.
      final many = [
        for (var i = 1; i <= 35; i++) _ep(i, 'Plot of episode number $i.'),
      ];
      final result = AutoNamer.filterEpisodesBySimilarity(
        many,
        ['plot of an episode'],
        maxEpisodes: 45,
      );
      expect(result, hasLength(35));
    });
  });

  group('AutoNamer.baseEpisodeTitle', () {
    test('strips bracketed part numbers', () {
      expect(AutoNamer.baseEpisodeTitle('iPsycho (1)'), 'iPsycho');
      expect(AutoNamer.baseEpisodeTitle('iPsycho (2)'), 'iPsycho');
      expect(AutoNamer.baseEpisodeTitle('iGo to Japan [3]'), 'iGo to Japan');
    });

    test('strips "Part N" suffixes', () {
      expect(AutoNamer.baseEpisodeTitle('The End, Part 2'), 'The End');
      expect(AutoNamer.baseEpisodeTitle('The End - Part Two'), 'The End');
    });

    test('keeps titles that merely end in a number or numbered name', () {
      expect(
        AutoNamer.baseEpisodeTitle('iMust Have Locker 239'),
        'iMust Have Locker 239',
      );
      expect(
        AutoNamer.baseEpisodeTitle('iBloop 2: Electric Bloopaloo'),
        'iBloop 2: Electric Bloopaloo',
      );
    });
  });

  group('AutoNamer.partGroup', () {
    final episodes = [
      _ep(4, 'a', title: 'iLike Jake'),
      _ep(5, 'b', title: 'iGo to Japan (1)'),
      _ep(6, 'c', title: 'iGo to Japan (2)'),
      _ep(7, 'd', title: 'iGo to Japan (3)'),
      _ep(8, 'e', title: 'iPie'),
    ];

    test('finds the full consecutive group from any part', () {
      expect(AutoNamer.partGroup(episodes, 1, 6), (start: 5, end: 7));
      expect(AutoNamer.partGroup(episodes, 1, 5), (start: 5, end: 7));
      expect(AutoNamer.partGroup(episodes, 1, 7), (start: 5, end: 7));
    });

    test('returns null for standalone episodes', () {
      expect(AutoNamer.partGroup(episodes, 1, 4), isNull);
      expect(AutoNamer.partGroup(episodes, 1, 8), isNull);
    });
  });

  group('AutoNamer.refineWithDuration', () {
    final episodes = [
      _ep(17, 'a', title: 'iDont Want to Fight', runtime: 24),
      _ep(18, 'b', title: 'iDate a Bad Boy (1)', runtime: 24),
      _ep(19, 'c', title: 'iDate a Bad Boy (2)', runtime: 24),
      _ep(20, 'd', title: 'iReunite With Missy', runtime: 24),
      _ep(7, 'e', title: 'iShock America', runtime: 44, season: 6),
      _ep(8, 'f', title: 'iGet Banned', runtime: 24, season: 6),
    ];

    test('double-length file over a part group becomes a range', () {
      final r = AutoNamer.refineWithDuration(
        episodes: episodes,
        season: 1,
        epNumber: 19, // LLM picked part (2)
        durationSecs: 2769,
        medianSecs: 1418,
      );
      expect(r, (epStart: 18, epEnd: 19, playAll: false));
    });

    test('normal-length file keeps its single episode', () {
      final r = AutoNamer.refineWithDuration(
        episodes: episodes,
        season: 1,
        epNumber: 17,
        durationSecs: 1418,
        medianSecs: 1418,
      );
      expect(r, (epStart: 17, epEnd: 17, playAll: false));
    });

    test('long single episode with matching TMDB runtime stays single', () {
      // iShock America: 44-minute runtime, ~1.9x the batch median — must
      // NOT be turned into a range or flagged as play-all.
      final r = AutoNamer.refineWithDuration(
        episodes: episodes,
        season: 6,
        epNumber: 7,
        durationSecs: 2620,
        medianSecs: 1413,
      );
      expect(r, (epStart: 7, epEnd: 7, playAll: false));
    });

    test('whole-disc play-all title is flagged', () {
      final r = AutoNamer.refineWithDuration(
        episodes: episodes,
        season: 1,
        epNumber: 20,
        durationSecs: 9840,
        medianSecs: 1418,
      );
      expect(r.playAll, isTrue);
    });

    test('missing duration leaves the pick untouched', () {
      final r = AutoNamer.refineWithDuration(
        episodes: episodes,
        season: 1,
        epNumber: 18,
        durationSecs: null,
        medianSecs: 1418,
      );
      expect(r, (epStart: 18, epEnd: 18, playAll: false));
    });
  });

  group('AutoNamer.episodeStem', () {
    test('formats singles and ranges', () {
      expect(AutoNamer.episodeStem(2, 5), 's02e05');
      expect(AutoNamer.episodeStem(2, 5, 5), 's02e05');
      expect(AutoNamer.episodeStem(2, 5, 7), 's02e05-e07');
      expect(AutoNamer.episodeStem(11, 9, 10), 's11e09-e10');
    });

    test('season 0 (specials) formats as s00eXX', () {
      expect(AutoNamer.episodeStem(0, 1), 's00e01');
    });
  });

  group('AutoNamer.classifyVersions', () {
    test('Victorious Prom Wrecker cuts: broadcast/extended/bonus', () {
      // Broadcast 23.6 min, extended 28.1 min, episode-plus-extras 42.2 min;
      // TMDB runtime 24 min.
      final roles = AutoNamer.classifyVersions(
        durationsSecs: [1419, 1687, 2530],
        expectedSecs: 24 * 60,
      );
      expect(roles, [
        VersionRole.primary,
        VersionRole.extended,
        VersionRole.leaveUnnamed,
      ]);
    });

    test('order independence: primary is closest to expected', () {
      final roles = AutoNamer.classifyVersions(
        durationsSecs: [2530, 1687, 1419],
        expectedSecs: 24 * 60,
      );
      expect(roles, [
        VersionRole.leaveUnnamed,
        VersionRole.extended,
        VersionRole.primary,
      ]);
    });

    test('equal durations: first file wins', () {
      final roles = AutoNamer.classifyVersions(
        durationsSecs: [1419, 1419],
        expectedSecs: 24 * 60,
      );
      expect(roles, [VersionRole.primary, VersionRole.extended]);
    });

    test('no expected duration: first primary, rest extended (never skip '
        'without evidence)', () {
      final roles = AutoNamer.classifyVersions(
        durationsSecs: [null, null],
        expectedSecs: null,
      );
      expect(roles, [VersionRole.primary, VersionRole.extended]);
    });

    test('unknown duration never becomes leaveUnnamed', () {
      final roles = AutoNamer.classifyVersions(
        durationsSecs: [1419, null],
        expectedSecs: 24 * 60,
      );
      expect(roles, [VersionRole.primary, VersionRole.extended]);
    });
  });

  group('AutoNamer.textSimilarity', () {
    test('extended cut scores high against its broadcast version', () {
      final broadcast = 'Tori plans the first prom at Hollywood Arts while '
              'Jade schemes to ruin the event with pranks and shrimp. ' *
          20;
      final extended = '$broadcast Extra scene: Sinjin rigs the lights and '
          'Robbie interviews students about the prome. ' 'More extra lines. ';
      expect(
        AutoNamer.textSimilarity(broadcast, extended),
        greaterThanOrEqualTo(0.5),
      );
    });

    test('different episodes score low', () {
      final a = 'Tori plans the first prom at Hollywood Arts with balloons '
              'streamers a band and a shrimp catapult built by Sinjin. ' *
          10;
      final b = 'Trina gets her wisdom teeth pulled while Cat and Jade sing '
              'karaoke at a club and get banned by the owner tonight. ' *
          10;
      expect(AutoNamer.textSimilarity(a, b), lessThan(0.5));
    });
  });

  group('AutoNamer.isNearDuplicateText', () {
    test('same text with case/punctuation differences is a duplicate', () {
      final a = 'Today was clown day at school. ' * 60;
      final b = 'today was Clown Day at school. ' * 60;
      expect(AutoNamer.isNearDuplicateText(a, b), isTrue);
    });

    test('different episodes of the same show are not duplicates', () {
      final a = 'Carly and Sam hatch chicks for a science project '
              'and lose them in the apartment while Spencer builds art. ' * 30;
      final b = 'Carly gets detention with Sam and Freddie so the fiftieth '
              'webshow can be filmed from school detention hall tonight. ' * 30;
      expect(AutoNamer.isNearDuplicateText(a, b), isFalse);
    });

    test('very different lengths are never duplicates', () {
      final a = 'Some dialogue here. ' * 200;
      final b = 'Some dialogue here. ' * 40;
      expect(AutoNamer.isNearDuplicateText(a, b), isFalse);
    });
  });

  group('AutoNamer.entityDenseExcerpt', () {
    test('keeps sentences with recurring proper nouns', () {
      final text = 'Nora is here. Nora loves the show. We saw Nora today. '
          'It is raining. The weather is bad. Nothing happens here. '
          'Maybe tomorrow. Or later.';
      final out = AutoNamer.entityDenseExcerpt(text);
      expect(out, contains('Nora'));
      expect(out, isNot(contains('raining')));
    });

    test('falls back to plain excerpt when no recurring names', () {
      final text = 'Just some words without names repeated at all here.';
      expect(AutoNamer.entityDenseExcerpt(text), isNotEmpty);
    });
  });
}
