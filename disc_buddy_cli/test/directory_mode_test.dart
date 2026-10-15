import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy_cli/src/cli/directory_mode.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_prompter.dart';

RipOptions opts({bool force = false}) => RipOptions(
      device: null,
      outputDir: '/out',
      ffmpeg: 'ffmpeg',
      ffprobe: 'ffprobe',
      force: force,
    );

void main() {
  late Directory tmp;
  late LogSink log;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dirmode_test_');
    log = LogSink();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File touch(String name) => File(p.join(tmp.path, name))..writeAsStringSync('x');
  bool exists(String name) => File(p.join(tmp.path, name)).existsSync();

  group('listVideoFiles / selectByNumbers', () {
    test('filtert op extensie en sorteert op naam', () {
      touch('b.mkv');
      touch('a.MP4');
      touch('notes.txt');
      touch('c.en.srt');
      Directory(p.join(tmp.path, 'sub.mkv')).createSync();
      expect(listVideoFiles(tmp).map((f) => p.basename(f.path)), ['a.MP4', 'b.mkv']);
    });

    test('selectie "1 3" kiest de juiste items, leeg = alles, rommel genegeerd', () {
      final items = ['a', 'b', 'c'];
      expect(selectByNumbers('1 3', items), ['a', 'c']);
      expect(selectByNumbers('3,1', items), ['c', 'a']);
      expect(selectByNumbers('', items), items);
      expect(selectByNumbers('0 4 x', items), isEmpty);
    });
  });

  group('processDirectory', () {
    test('lege map → false en foutmelding i.p.v. exit', () async {
      final ok = await processDirectory(opts(), tmp.path,
          prompter: FakePrompter(), onLog: log.call);
      expect(ok, isFalse);
      expect(log.text, contains('[ERR] No video files found'));
    });

    test('--force selecteert alles en hernoemt niets', () async {
      touch('a.mkv');
      touch('b.mkv');
      final p = FakePrompter();
      final ok = await processDirectory(opts(force: true), tmp.path,
          prompter: p, onLog: log.call);
      expect(ok, isTrue);
      expect(p.asked, isEmpty);
      expect(log.text, contains('Auto-selected all 2 files'));
      expect(exists('a.mkv') && exists('b.mkv'), isTrue);
    });

    test('selectie "2" en handmatige naam hernoemt alleen dat bestand met sidecar', () async {
      touch('a.mkv');
      touch('b.mkv');
      touch('b.en.srt');
      // answers: file selection, "Rename items?", new name for b
      final p = FakePrompter(['2', 'y', 'Episode One']);
      final ok = await processDirectory(opts(), tmp.path, prompter: p, onLog: log.call);
      expect(ok, isTrue);
      expect(exists('Episode One.mkv'), isTrue);
      expect(exists('Episode One.en.srt'), isTrue);
      expect(exists('a.mkv'), isTrue);
      expect(exists('b.mkv'), isFalse);
      // Without LLM config the rename prompt offers no "?" option.
      expect(p.asked[1], contains('[y/N]'));
    });

    test('geen selectie → niets gebeurt, maar wel true', () async {
      touch('a.mkv');
      final ok = await processDirectory(opts(), tmp.path,
          prompter: FakePrompter(['9']), onLog: log.call);
      expect(ok, isTrue);
      expect(log.text, contains('No files selected'));
    });
  });

  group('processMkv', () {
    test('"n" laat het bestand staan', () async {
      touch('film.mkv');
      await processMkv(opts(), p.join(tmp.path, 'film.mkv'),
          prompter: FakePrompter(['n']), onLog: log.call);
      expect(exists('film.mkv'), isTrue);
    });

    test('"y" + nieuwe naam hernoemt', () async {
      touch('film.mkv');
      await processMkv(opts(), p.join(tmp.path, 'film.mkv'),
          prompter: FakePrompter(['y', 'Better Name']), onLog: log.call);
      expect(exists('Better Name.mkv'), isTrue);
      expect(exists('film.mkv'), isFalse);
    });

    test('--force vraagt niets', () async {
      touch('film.mkv');
      final pr = FakePrompter();
      await processMkv(opts(force: true), p.join(tmp.path, 'film.mkv'),
          prompter: pr, onLog: log.call);
      expect(pr.asked, isEmpty);
      expect(exists('film.mkv'), isTrue);
    });
  });
}
