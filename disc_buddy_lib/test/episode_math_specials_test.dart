import 'package:disc_buddy/src/naming/episode_math.dart';
import 'package:disc_buddy/src/naming/naming_types.dart';
import 'package:disc_buddy/src/naming/tmdb_client.dart';
import 'package:test/test.dart';

EpisodeInfo _ep(int n, String title, String overview) => (
  number: n,
  title: title,
  overview: overview,
  guestStars: '',
  airDate: '',
  runtime: null,
);

void main() {
  group('bonusLayoutOutliers', () {
    const tagged = ['eng', 'fre', 'ger'];
    const commentary = ['eng', 'fre', 'ger', 'eng'];

    test('flags single-track files among tagged multi-track ones', () {
      // Seinfeld S8: 16 episodes with 3 tagged tracks, 6 with a commentary
      // track on top, 2 bonus clips with one English stereo track.
      final layouts = <int, List<String>>{
        for (var i = 0; i < 16; i++) i: tagged,
        for (var i = 16; i < 22; i++) i: commentary,
        22: ['eng'],
        23: ['eng'],
      };
      expect(bonusLayoutOutliers(layouts), {22, 23});
    });

    test('untagged files with fewer tracks are outliers too', () {
      final layouts = <int, List<String>>{
        0: tagged, 1: tagged, 2: tagged, 3: [''], 4: ['und', 'und'],
      };
      expect(bonusLayoutOutliers(layouts), {3, 4});
    });

    test('a tagged file missing only one track is not an outlier', () {
      final layouts = <int, List<String>>{
        0: tagged, 1: tagged, 2: tagged, 3: ['eng', 'ger'],
      };
      expect(bonusLayoutOutliers(layouts), isEmpty);
    });

    test('a language the common layout lacks is not bonus evidence', () {
      final layouts = <int, List<String>>{
        0: tagged, 1: tagged, 2: tagged, 3: ['jpn'],
      };
      expect(bonusLayoutOutliers(layouts), isEmpty);
    });

    test('a two-track common layout flags only untagged files', () {
      final layouts = <int, List<String>>{
        0: ['eng', 'eng'], 1: ['eng', 'eng'], 2: ['eng', 'eng'],
        3: ['eng'], 4: [''],
      };
      expect(bonusLayoutOutliers(layouts), {4});
    });

    test('needs three files on the common layout', () {
      final layouts = <int, List<String>>{
        0: tagged, 1: tagged, 2: [''], 3: ['eng', 'ger'],
      };
      expect(bonusLayoutOutliers(layouts), isEmpty);
    });

    test('an untagged common layout flags nothing', () {
      final layouts = <int, List<String>>{
        0: ['', ''], 1: ['', ''], 2: ['', ''], 3: [''],
      };
      expect(bonusLayoutOutliers(layouts), isEmpty);
    });

    test('commonAudioLayout is the most frequent one, not the first', () {
      final layouts = <int, List<String>>{
        0: commentary, 1: tagged, 2: tagged, 3: tagged, 4: [''],
      };
      expect(commonAudioLayout(layouts), tagged);
      expect(commonAudioLayout({}), isEmpty);
    });

    test('describeAudioLayout', () {
      expect(describeAudioLayout(['']), '1 untagged track');
      expect(describeAudioLayout(tagged), '3 tracks (eng, fre, ger)');
      expect(describeAudioLayout(['eng', '']), '2 tracks (eng, ?)');
    });
  });

  group('shouldTrySpecials', () {
    bool call({
      bool layout = false,
      double? secs = 1320,
      double? median = 1320,
      int claimed = 10,
      int total = 22,
    }) => shouldTrySpecials(
      layoutOutlier: layout,
      durationSecs: secs,
      medianSecs: median,
      claimedRegular: claimed,
      totalRegular: total,
    );

    test('a fitting file in a half-claimed season is left alone', () {
      expect(call(), isFalse);
      expect(call(secs: 1441), isFalse); // 24:01 vs 22:00 is within 25 %
    });

    test('odd layout, odd length, or a fully claimed season allow it', () {
      expect(call(layout: true), isTrue);
      expect(call(secs: 3000), isTrue);
      expect(call(secs: 900), isTrue);
      expect(call(claimed: 22), isTrue);
      expect(call(claimed: 0), isTrue);
    });

    test('unknown durations never count as odd', () {
      expect(call(secs: null), isFalse);
      expect(call(median: null), isFalse);
    });
  });

  group('seasonSpecials', () {
    SeasonEpisode sp(int n, String title, String overview) => (
      season: 0,
      ep: _ep(n, title, overview),
    );

    test('keeps specials that mention the season or one of its episodes', () {
      final specials = [
        sp(2, 'How It Began', 'How the show was created, with the pilot.'),
        sp(127, 'Jerry Seinfeld: Submarine Captain',
            'What Seinfeld did to get season 8 going.'),
        sp(134, 'Inside Looks: The Abstinence', ''),
        sp(140, 'Not That There\'s Anything Wrong With That (Season 8)',
            'Bloopers.'),
        sp(150, 'Bloopers (Season 9)', 'Bloopers from season 9.'),
        sp(160, 'Inside Looks: The Pilot', 'Inside look at "The Pilot".'),
      ];
      final titles = ['The Foundation', 'The Abstinence', 'The Nap'];
      expect(
        seasonSpecials(specials, 8, titles).map((s) => s.ep.number),
        [127, 134, 140],
      );
      expect(seasonSpecials(specials, 3, const []), isEmpty);
    });
  });

  group('verifiableSpecials', () {
    test('drops season-0 placeholders without an overview', () {
      final specials = [
        _ep(1, 'The Seinfeld Story', 'Jerry takes questions from the crowd.'),
        _ep(162, 'Reunion Special', ''),
        _ep(163, 'Blank', '   '),
      ];
      expect(
        verifiableSpecials(specials).map((e) => e.number),
        [1],
      );
    });

    test('keeps everything when all specials have overviews', () {
      final specials = [_ep(1, 'A', 'a'), _ep(2, 'B', 'b')];
      expect(verifiableSpecials(specials), specials);
    });
  });
}
