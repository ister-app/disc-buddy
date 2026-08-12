import 'package:disc_buddy/src/naming/auto_namer.dart';
import 'package:disc_buddy/src/naming/tmdb_client.dart';
import 'package:test/test.dart';

({int season, EpisodeInfo ep}) _ep(int number, String overview) => (
      season: 1,
      ep: (
        number: number,
        title: 'Episode $number',
        overview: overview,
        guestStars: '',
        airDate: '',
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
}
