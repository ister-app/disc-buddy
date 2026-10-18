import 'package:disc_buddy/src/naming/duration_probe.dart';
import 'package:test/test.dart';

void main() {
  group('DurationProbe.parseProbeJson', () {
    test('prefers the video stream over an inflated container duration', () {
      const json = '''
{"streams":[
  {"codec_type":"video","tags":{"DURATION":"00:21:56.088000000"}},
  {"codec_type":"audio","tags":{"DURATION":"00:22:01.377000000"}},
  {"codec_type":"subtitle","duration":"2603.192000","tags":{"DURATION":"00:43:03.376000000"}}
],"format":{"duration":"2603.192000"}}''';
      expect(DurationProbe.parseProbeJson(json), closeTo(1316.088, 0.001));
    });

    test('uses a direct stream duration when present', () {
      const json =
          '{"streams":[{"codec_type":"video","duration":"1500.5"}],"format":{"duration":"1600"}}';
      expect(DurationProbe.parseProbeJson(json), 1500.5);
    });

    test('falls back to audio, then container', () {
      expect(
        DurationProbe.parseProbeJson(
            '{"streams":[{"codec_type":"audio","duration":"42"}],"format":{"duration":"99"}}'),
        42,
      );
      expect(
        DurationProbe.parseProbeJson('{"streams":[],"format":{"duration":"99"}}'),
        99,
      );
    });

    test('returns null on garbage', () {
      expect(DurationProbe.parseProbeJson('not json'), isNull);
      expect(DurationProbe.parseProbeJson('{}'), isNull);
    });
  });

  test('parseHms', () {
    expect(DurationProbe.parseHms('01:02:03.5'), 3723.5);
    expect(DurationProbe.parseHms('bad'), isNull);
  });
}
