import 'dart:convert';
import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:test/test.dart';

void main() {
  group('language helpers', () {
    test('majorityLanguage picks the mode, first seen on ties', () {
      expect(Transcriber.majorityLanguage([]), isNull);
      expect(Transcriber.majorityLanguage(['en', 'nl', 'nl']), 'nl');
      expect(Transcriber.majorityLanguage(['en', 'nl']), 'en');
    });

    test('looksLikeGarbage flags wrong-script and repeated text', () {
      expect(Transcriber.looksLikeGarbage(
          'Floris Wolfs and I often met each other over hope.', 'nl'), isFalse);
      expect(Transcriber.looksLikeGarbage(
          'Weet je dat er een telefoon onder de auto ligt?', 'nl'), isFalse);
      expect(Transcriber.looksLikeGarbage(
          '中文字幕:YK 中文字幕:YK 中文字幕:YK', 'nl'), isTrue);
      expect(Transcriber.looksLikeGarbage(
          List.filled(20, 'Dank je wel.').join(' '), 'nl'), isTrue);
      expect(Transcriber.looksLikeGarbage('', 'nl'), isTrue);
      // Non-Latin language with its own script is fine.
      expect(Transcriber.looksLikeGarbage('これはテストです。昨日は雨でした。', 'ja'), isFalse);
    });

    test('convertIso2to1 maps B/T codes and rejects und', () {
      expect(convertIso2to1('dut'), 'nl');
      expect(convertIso2to1('nld'), 'nl');
      expect(convertIso2to1('eng'), 'en');
      expect(convertIso2to1('DE'), 'de');
      expect(convertIso2to1('und'), isNull);
      expect(convertIso2to1(''), isNull);
      expect(convertIso2to1('xyz'), isNull);
    });
  });

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

    // Fake whisper that records its `-l` argument per call and answers with
    // a language chosen by the shell snippet [langExpr] (sees \$lang, \$prefix).
    Future<File> fakeWhisper(String langExpr) => fakeBin('whisper-cli', '''
prefix=""
lang=""
prev=""
for arg; do
  if [ "\$prev" = "-of" ]; then prefix="\$arg"; fi
  if [ "\$prev" = "-l" ]; then lang="\$arg"; fi
  prev="\$arg"
done
echo "\$lang \$(basename "\$prefix")" >> "${tmpDir.path}/calls.log"
out=\$($langExpr)
printf '%s' "{\\"result\\":{\\"language\\":\\"\$out\\"},\\"transcription\\":[{\\"text\\":\\"een lange nederlandse zin met genoeg woorden om ruim boven de minimale lengte van het transcript uit te komen zodat de controle slaagt en de test door kan gaan\\"}]}" > "\$prefix.json"
''');

    Future<File> fakeProbe(String tag) async => fakeBin('ffprobe',
        "echo '${jsonEncode({
          'streams': [{'codec_type': 'audio', 'tags': {'language': tag}}],
          'format': {'duration': '2700.0'},
        })}'");

    Future<List<String>> calls() async =>
        (await File('${tmpDir.path}/calls.log').readAsLines());

    test('auto-detect: minority-language window is redone as the majority',
        () async {
      final mkv = File('${tmpDir.path}/ep.mkv');
      await mkv.writeAsString('');
      final ffprobe = await fakeProbe('und');
      final ffmpeg = await fakeBin('ffmpeg', 'for out; do true; done; touch "\$out"');
      // win0 detects English on auto; everything else is Dutch.
      final whisper = await fakeWhisper(
          'if [ "\$lang" = auto ] && [ "\$(basename "\$prefix")" = win0 ]; '
          'then echo en; else echo nl; fi');

      final t = Transcriber(
        ffmpeg: ffmpeg.path, ffprobe: ffprobe.path,
        whisperCli: whisper.path, whisperModel: 'm.bin',
        onLog: (_, {isError = false}) {},
      );
      final result = await t.transcribe(mkv);
      expect(result, isNotNull);
      expect(result!.language, 'nl');
      expect(await calls(), [
        'auto win0', 'auto win1', 'auto win2', 'nl win0_redo',
      ]);
      final side = jsonDecode(
          await File('${tmpDir.path}/ep.whisper.json').readAsString());
      expect(side['version'], 2);
      expect(side['language'], 'nl');
      expect(side['languages'], ['nl', 'nl', 'nl']);
    });

    test('audio track tag pins the language without auto-detect', () async {
      final mkv = File('${tmpDir.path}/ep.mkv');
      await mkv.writeAsString('');
      final ffprobe = await fakeProbe('dut');
      final ffmpeg = await fakeBin('ffmpeg', 'for out; do true; done; touch "\$out"');
      final whisper = await fakeWhisper('echo "\$lang"');

      final t = Transcriber(
        ffmpeg: ffmpeg.path, ffprobe: ffprobe.path,
        whisperCli: whisper.path, whisperModel: 'm.bin',
        onLog: (_, {isError = false}) {},
      );
      final result = await t.transcribe(mkv);
      expect(result!.language, 'nl');
      expect(await calls(), ['nl win0', 'nl win1', 'nl win2']);
    });

    test('explicit language wins over the track tag', () async {
      final mkv = File('${tmpDir.path}/ep.mkv');
      await mkv.writeAsString('');
      final ffprobe = await fakeProbe('dut');
      final ffmpeg = await fakeBin('ffmpeg', 'for out; do true; done; touch "\$out"');
      final whisper = await fakeWhisper('echo "\$lang"');

      final t = Transcriber(
        ffmpeg: ffmpeg.path, ffprobe: ffprobe.path,
        whisperCli: whisper.path, whisperModel: 'm.bin', language: 'en',
        onLog: (_, {isError = false}) {},
      );
      final result = await t.transcribe(mkv);
      expect(result!.language, 'en');
      expect(await calls(), ['en win0', 'en win1', 'en win2']);
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
