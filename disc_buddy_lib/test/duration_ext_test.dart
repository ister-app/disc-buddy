import 'package:disc_buddy/src/utils/duration_ext.dart';
import 'package:test/test.dart';

void main() {
  group('durationWithinTolerance', () {
    const expected = Duration(minutes: 22, seconds: 7);

    test('binnen absolute marge', () {
      expect(durationWithinTolerance(expected: expected, actual: expected - const Duration(seconds: 4)), isTrue);
      expect(durationWithinTolerance(expected: expected, actual: expected - const Duration(seconds: 5)), isTrue);
    });

    test('binnen relatieve marge bij lange titel', () {
      const long = Duration(hours: 2);
      // 2% of 2 h = 144 s, well above the 5 s absolute floor.
      expect(durationWithinTolerance(expected: long, actual: long - const Duration(seconds: 100)), isTrue);
      expect(durationWithinTolerance(expected: long, actual: long - const Duration(seconds: 200)), isFalse);
    });

    test('te kort → false', () {
      expect(durationWithinTolerance(expected: expected, actual: const Duration(minutes: 10)), isFalse);
      expect(durationWithinTolerance(expected: expected, actual: expected - const Duration(seconds: 40)), isFalse);
    });

    test('te lang (overshoot) → true', () {
      expect(durationWithinTolerance(expected: expected, actual: expected + const Duration(minutes: 5)), isTrue);
    });

    test('hmsLabel', () {
      expect(const Duration(hours: 1, minutes: 2, seconds: 3).hmsLabel, '01:02:03');
    });
  });
}
