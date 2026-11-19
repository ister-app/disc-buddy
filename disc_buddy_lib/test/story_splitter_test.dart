import 'package:disc_buddy/src/naming/story_splitter.dart';
import 'package:test/test.dart';

void main() {
  group('StorySplitter.parseBlackdetect', () {
    test('leest de intervallen en verschuift ze naar bestandstijd', () {
      const stderr = '''
[blackdetect @ 0x55] black_start:146.8 black_end:147.28 black_duration:0.48
frame= 1234 fps=...
[blackdetect @ 0x55] black_start:228.16 black_end:229.16 black_duration:1
''';
      expect(StorySplitter.parseBlackdetect(stderr, offset: 480), [
        (start: 626.8, end: 627.28),
        (start: 708.16, end: 709.16),
      ]);
    });
  });

  group('StorySplitter.pickCut', () {
    test('kiest het midden van de zwarte strook die het dichtst bij het midden ligt',
        () {
      final cut = StorySplitter.pickCut([
        (start: 626.8, end: 627.28),
        (start: 708.16, end: 709.16),
        (start: 760.0, end: 760.5),
      ], 1416);
      expect(cut, closeTo(708.66, 0.001));
    });

    test('geen zwart binnen de straal rond het midden → null', () {
      expect(
        StorySplitter.pickCut([(start: 100.0, end: 101.0)], 1416),
        isNull,
      );
      expect(StorySplitter.pickCut([], 1416), isNull);
    });
  });
}
