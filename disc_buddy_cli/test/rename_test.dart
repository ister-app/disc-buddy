import 'dart:io';

import 'package:disc_buddy_cli/src/cli/rename.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_prompter.dart';

void main() {
  late Directory tmp;
  late LogSink log;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rename_test_');
    log = LogSink();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File touch(String name, [String content = 'x']) =>
      File(p.join(tmp.path, name))..writeAsStringSync(content);
  bool exists(String name) => File(p.join(tmp.path, name)).existsSync();

  test('defaultStem', () {
    expect(defaultStem('My Disc', 'title_01.mkv'), 'My Disc-title_01');
    expect(defaultStem('A/B:C', 'x.mkv'), isNot(contains('/')));
  });

  group('applyRenames', () {
    test('hernoemt mkv en neemt .srt/.whisper.json sidecars mee', () async {
      touch('DISC-title_01.mkv');
      touch('DISC-title_01.en.srt');
      touch('DISC-title_01.nl.srt');
      touch('DISC-title_01.whisper.json');
      touch('DISC-title_01.txt'); // not a sidecar

      await applyRenames(tmp, 'DISC', ['title_01.mkv'],
          {'title_01.mkv': 's01e01'}, onLog: log.call);

      expect(exists('s01e01.mkv'), isTrue);
      expect(exists('s01e01.en.srt'), isTrue);
      expect(exists('s01e01.nl.srt'), isTrue);
      expect(exists('s01e01.whisper.json'), isTrue);
      expect(exists('DISC-title_01.txt'), isTrue);
      expect(exists('DISC-title_01.mkv'), isFalse);
      expect(log.text, contains('Renamed:'));
    });

    test('botsende doelnaam wordt niet overschreven', () async {
      touch('DISC-title_01.mkv', 'source');
      touch('s01e01.mkv', 'existing');

      await applyRenames(tmp, 'DISC', ['title_01.mkv'],
          {'title_01.mkv': 's01e01'}, onLog: log.call);

      expect(File(p.join(tmp.path, 's01e01.mkv')).readAsStringSync(), 'existing');
      expect(exists('DISC-title_01.mkv'), isTrue);
      expect(log.text, contains('Rename skipped'));
    });

    test('default stem, "?" en ontbrekend bestand worden overgeslagen', () async {
      touch('DISC-title_01.mkv');
      await applyRenames(tmp, 'DISC', ['title_01.mkv', 'title_02.mkv', 'title_03.mkv'], {
        'title_01.mkv': 'DISC-title_01', // equals default
        'title_02.mkv': '?',             // unresolved auto-name
        'title_03.mkv': 'new',           // file does not exist
      }, onLog: log.call);
      expect(exists('DISC-title_01.mkv'), isTrue);
      expect(log.lines, isEmpty);
    });
  });

  group('renameFile', () {
    test('EXDEV valt terug op copy+delete', () async {
      final src = touch('a.mkv', 'payload');
      final dest = p.join(tmp.path, 'b.mkv');
      var calls = 0;
      final ok = await renameFile(src, dest, onLog: log.call, rename: (f, d) async {
        calls++;
        throw FileSystemException('rename', f.path, const OSError('EXDEV', 18));
      });
      expect(ok, isTrue);
      expect(calls, 1);
      expect(exists('a.mkv'), isFalse);
      expect(File(dest).readAsStringSync(), 'payload');
    });

    test('andere fout → false en logregel, bron blijft', () async {
      final src = touch('a.mkv');
      final ok = await renameFile(src, p.join(tmp.path, 'b.mkv'),
          onLog: log.call,
          rename: (f, d) async =>
              throw FileSystemException('rename', f.path, const OSError('EACCES', 13)));
      expect(ok, isFalse);
      expect(exists('a.mkv'), isTrue);
      expect(log.text, contains('[ERR]'));
    });
  });

  group('renameWithSidecars', () {
    test('zelfde stem → niets doen', () async {
      touch('ep.mkv');
      expect(await renameWithSidecars(File(p.join(tmp.path, 'ep.mkv')), 'ep'), isFalse);
      expect(exists('ep.mkv'), isTrue);
    });

    test('hernoemt met extensie behouden en sidecars mee', () async {
      touch('ep.mp4');
      touch('ep.en.srt');
      final ok = await renameWithSidecars(File(p.join(tmp.path, 'ep.mp4')), 'Film (2001)');
      expect(ok, isTrue);
      expect(exists('Film (2001).mp4'), isTrue);
      expect(exists('Film (2001).en.srt'), isTrue);
    });
  });
}
