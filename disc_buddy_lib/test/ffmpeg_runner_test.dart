import 'package:disc_buddy/src/ffmpeg/ffmpeg_runner.dart';
import 'package:test/test.dart';

void main() {
  group('FfmpegRunner.classifyStderrLine', () {
    test('warning with context prefix → not an error, tag stripped', () {
      final r = FfmpegRunner.classifyStderrLine(
          '[vist#0:1/mpeg2video @ 0x5615c5338f00] [warning] '
          'timestamp discontinuity (stream id=480): -1416532389');
      expect(r.isError, isFalse);
      expect(
          r.line,
          '[vist#0:1/mpeg2video @ 0x5615c5338f00] '
          'timestamp discontinuity (stream id=480): -1416532389');
    });

    test('warning at line start → not an error, tag stripped', () {
      final r = FfmpegRunner.classifyStderrLine('[warning] deprecated option');
      expect(r.isError, isFalse);
      expect(r.line, 'deprecated option');
    });

    test('error and fatal → error, tag stripped', () {
      final e = FfmpegRunner.classifyStderrLine(
          '[in#0 @ 0x564b5cd20440] [error] Error opening input');
      expect(e.isError, isTrue);
      expect(e.line, '[in#0 @ 0x564b5cd20440] Error opening input');

      final f = FfmpegRunner.classifyStderrLine(
          '[fatal] Error opening input files: No such file or directory');
      expect(f.isError, isTrue);
      expect(f.line, 'Error opening input files: No such file or directory');
    });

    test('line without level tag → error (historical behavior), unchanged', () {
      final r = FfmpegRunner.classifyStderrLine(
          'Guessed Channel Layout for Input Stream #0.1 : stereo');
      expect(r.isError, isTrue);
      expect(r.line, 'Guessed Channel Layout for Input Stream #0.1 : stereo');
    });

    test('bracketed text that is not a level tag is left alone', () {
      final r = FfmpegRunner.classifyStderrLine(
          '[mpeg @ 0x55d] Packet corrupt [something] happened');
      expect(r.isError, isTrue);
      expect(r.line, '[mpeg @ 0x55d] Packet corrupt [something] happened');
    });
  });

  group('FfmpegRunner.run stdin errors', () {
    test('producer die gooit wordt via onStdinError gemeld', () async {
      Object? reported;
      final logs = <String>[];
      Stream<List<int>> producer() async* {
        yield [1, 2, 3];
        throw StateError('disc gone');
      }
      final code = await FfmpegRunner(
        executable: 'cat',
        onLog: (m, {isError = false}) => logs.add(m),
      ).run(const [], stdinData: producer(), onStdinError: (e) => reported = e);
      expect(reported, isA<StateError>());
      expect(logs.join('\n'), contains('ffmpeg input error'));
      expect(code, 0); // cat itself ended fine on EOF
    });

    test('vroegtijdig einde van het proces faalt de run niet', () async {
      Stream<List<int>> producer() async* {
        for (var i = 0; i < 2000; i++) {
          yield List.filled(65536, 0);
        }
      }
      final code = await FfmpegRunner(executable: 'true')
          .run(const [], stdinData: producer());
      expect(code, 0);
    });
  });
}
