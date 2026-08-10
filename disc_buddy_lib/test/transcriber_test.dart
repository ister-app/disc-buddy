import 'dart:convert';
import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:test/test.dart';

void main() {
  group('Transcriber.windowOffsets', () {
    test('unknown duration falls back to a single 5-minute window', () {
      for (final duration in [null, 0.0, -3.0]) {
        final windows = Transcriber.windowOffsets(duration);
        expect(windows, hasLength(1));
        expect(windows.single.start, 0.0);
        expect(windows.single.len, 300.0);
      }
    });

    test('short title gets one window skipping the intro', () {
      final windows = Transcriber.windowOffsets(400.0);
      expect(windows, hasLength(1));
      expect(windows.single.start, 90.0);
      expect(windows.single.len, 310.0);
    });

    test('very short title starts at 0', () {
      final windows = Transcriber.windowOffsets(200.0);
      expect(windows, hasLength(1));
      expect(windows.single.start, 0.0);
      expect(windows.single.len, 200.0);
    });

    test('long title gets three non-overlapping windows within bounds', () {
      const duration = 2700.0; // 45 min
      final windows = Transcriber.windowOffsets(duration);
      expect(windows, hasLength(3));
      // First window: past the intro (>= 90 s).
      expect(windows.first.start, greaterThanOrEqualTo(90.0));
      for (final w in windows) {
        expect(w.len, 180.0);
        expect(w.start + w.len, lessThanOrEqualTo(duration));
      }
      // Strictly ordered, no overlap.
      for (var i = 1; i < windows.length; i++) {
        expect(windows[i].start,
            greaterThanOrEqualTo(windows[i - 1].start + windows[i - 1].len));
      }
    });
  });

  group('Transcriber.parseWhisperJson', () {
    test('joins segments and reads the detected language', () {
      final raw = jsonEncode({
        'result': {'language': 'nl'},
        'transcription': [
          {'text': ' Hallo daar.'},
          {'text': ' Hoe gaat het?'},
        ],
      });
      final parsed = Transcriber.parseWhisperJson(raw);
      expect(parsed, isNotNull);
      expect(parsed!.text, ' Hallo daar.  Hoe gaat het?');
      expect(parsed.language, 'nl');
    });

    test('defaults language to en and tolerates missing fields', () {
      final parsed = Transcriber.parseWhisperJson('{"transcription": []}');
      expect(parsed, isNotNull);
      expect(parsed!.language, 'en');
      expect(parsed.text, isEmpty);
    });

    test('returns null on malformed JSON', () {
      expect(Transcriber.parseWhisperJson('not json'), isNull);
    });
  });

  group('Transcriber.cleanTranscript', () {
    test('strips non-speech markers and collapses whitespace', () {
      const raw = '[BLANK_AUDIO] Hello   there. (dramatic music) ♪♪ Bye.';
      expect(Transcriber.cleanTranscript(raw), 'Hello there. Bye.');
    });
  });

  group('Transcriber.transcribe sidecar cache', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('transcriber_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('returns cached transcript without spawning any process', () async {
      final mkv = File('${tmpDir.path}/episode.mkv');
      await mkv.writeAsString(''); // never probed thanks to the cache
      await File('${tmpDir.path}/episode.whisper.json').writeAsString(
        jsonEncode({'language': 'nl', 'text': 'gecachete transcriptie'}),
      );

      // Bogus tool paths: any process spawn would fail loudly.
      final transcriber = Transcriber(
        ffmpeg: '/nonexistent/ffmpeg',
        ffprobe: '/nonexistent/ffprobe',
        whisperCli: '/nonexistent/whisper-cli',
        whisperModel: '/nonexistent/model.bin',
        onLog: (_, {isError = false}) {},
      );

      final result = await transcriber.transcribe(mkv);
      expect(result, isNotNull);
      expect(result!.text, 'gecachete transcriptie');
      expect(result.language, 'nl');
    });

    test('ignores a corrupt sidecar', () async {
      final mkv = File('${tmpDir.path}/episode.mkv');
      await mkv.writeAsString('');
      await File('${tmpDir.path}/episode.whisper.json')
          .writeAsString('not json');

      final transcriber = Transcriber(
        ffmpeg: '/nonexistent/ffmpeg',
        ffprobe: '/nonexistent/ffprobe',
        whisperCli: '/nonexistent/whisper-cli',
        whisperModel: '/nonexistent/model.bin',
        onLog: (_, {isError = false}) {},
      );

      // Falls through to probing, which fails on the bogus ffprobe → null.
      final result = await transcriber.transcribe(mkv);
      expect(result, isNull);
    });
  });

  group('Transcriber.transcribe with fake tools', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('transcriber_fake_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    Future<File> fakeBin(String name, String script) async {
      final f = File('${tmpDir.path}/$name');
      await f.writeAsString('#!/bin/sh\n$script');
      await Process.run('chmod', ['+x', f.path]);
      return f;
    }

    test('extracts windows, transcribes and joins with separators', () async {
      final mkv = File('${tmpDir.path}/episode.mkv');
      await mkv.writeAsString('');

      // 2700 s episode with one English audio stream → 3 windows.
      final probeJson = jsonEncode({
        'streams': [
          {'codec_type': 'audio', 'tags': {'language': 'eng'}},
        ],
        'format': {'duration': '2700.0'},
      });
      final ffprobe = await fakeBin('ffprobe', "echo '$probeJson'");
      // "Extract" the wav: last argument is the output path.
      final ffmpeg = await fakeBin('ffmpeg',
          'for out; do true; done; touch "\$out"');
      // Whisper: -of <prefix> precedes -np; write <prefix>.json.
      final whisperJson = jsonEncode({
        'result': {'language': 'en'},
        'transcription': [
          {'text': 'a transcript window with plenty of spoken words in it '
              'to comfortably clear the minimum transcript length check '
              'that guards against silence-only discs'},
        ],
      });
      final whisper = await fakeBin('whisper-cli', '''
prefix=""
prev=""
for arg; do
  if [ "\$prev" = "-of" ]; then prefix="\$arg"; fi
  prev="\$arg"
done
echo '$whisperJson' > "\$prefix.json"
''');

      final transcriber = Transcriber(
        ffmpeg: ffmpeg.path,
        ffprobe: ffprobe.path,
        whisperCli: whisper.path,
        whisperModel: '${tmpDir.path}/model.bin',
        onLog: (_, {isError = false}) {},
      );

      final result = await transcriber.transcribe(mkv);
      expect(result, isNotNull);
      expect(result!.language, 'en');
      expect('\n...\n'.allMatches(result.text), hasLength(2),
          reason: '3 windows joined by 2 separators');

      // A successful run writes the sidecar cache.
      expect(
        File('${tmpDir.path}/episode.whisper.json').existsSync(),
        isTrue,
      );
    });

    test('returns null when the file has no audio streams', () async {
      final mkv = File('${tmpDir.path}/silent.mkv');
      await mkv.writeAsString('');

      final probeJson = jsonEncode({
        'streams': [
          {'codec_type': 'video'},
        ],
        'format': {'duration': '2700.0'},
      });
      final ffprobe = await fakeBin('ffprobe', "echo '$probeJson'");

      final transcriber = Transcriber(
        ffmpeg: '/nonexistent/ffmpeg',
        ffprobe: ffprobe.path,
        whisperCli: '/nonexistent/whisper-cli',
        whisperModel: '/nonexistent/model.bin',
        onLog: (_, {isError = false}) {},
      );

      expect(await transcriber.transcribe(mkv), isNull);
    });
  });
}
