import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart' show StorySplit;
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

  group('parkSource / applySplitNames', () {
    String read(String name) => File(p.join(tmp.path, name)).readAsStringSync();
    List<String> names() =>
        tmp.listSync().map((e) => p.basename(e.path)).toList()..sort();

    Future<StorySplit> splitOf(String stem) async {
      final split = (
        source: touch('$stem.mkv', 'whole'),
        first: touch('$stem.story1.mkv', 'A'),
        second: touch('$stem.story2.mkv', 'B'),
        cut: 708.0,
      );
      touch('$stem.whisper.json');
      touch('$stem.story1.whisper.json', 'tA');
      touch('$stem.story2.whisper.json', 'tB');
      return parkSource(split);
    }

    test('twee verhalen vervangen het origineel, ook als een verhaal de naam '
        'van een ander nog wachtend origineel krijgt', () async {
      final a = await splitOf('s01e01');
      final b = await splitOf('s01e02');
      expect(exists('s01e01.mkv') || exists('s01e01.whisper.json'), isFalse);

      // s01e02's second story is s01e01: free now that s01e01 is parked.
      expect(await applySplitNames(b, 's02e14', 's01e01',
          originalStem: 's01e02', onLog: log.call), isTrue);
      expect(await applySplitNames(a, 's01e02', 's03e07',
          originalStem: 's01e01', onLog: log.call), isTrue);

      expect(names(), [
        's01e01.mkv', 's01e01.whisper.json',
        's01e02.mkv', 's01e02.whisper.json',
        's02e14.mkv', 's02e14.whisper.json',
        's03e07.mkv', 's03e07.whisper.json',
      ]);
      expect(read('s01e01.mkv'), 'B');
      expect(read('s01e01.whisper.json'), 'tB');
      expect(read('s01e02.mkv'), 'A');
      expect(read('s03e07.mkv'), 'B');
    });

    test('dezelfde naam voor beide helften → één verhaal, origineel blijft heel',
        () async {
      final a = await splitOf('s01e11');
      expect(await applySplitNames(a, 's01e21', 's01e21',
          originalStem: 's01e11', onLog: log.call), isTrue);
      expect(names(), ['s01e21.mkv']);
      expect(read('s01e21.mkv'), 'whole');
      expect(log.text, contains('one story'));
    });

    test('een helft zonder naam → helften weg, origineel terug onder oude naam',
        () async {
      final a = await splitOf('s01e10');
      expect(await applySplitNames(a, 's02e36', null,
          originalStem: 's01e10', onLog: log.call), isFalse);
      expect(names(), ['s01e10.unsplit.mkv']);
      await unparkSource(a, originalStem: 's01e10', onLog: log.call);
      expect(names(), ['s01e10.mkv']);
      expect(read('s01e10.mkv'), 'whole');
    });

    test('doelnaam al bezet → niets vervangen, origineel terug', () async {
      touch('s02e05.mkv', 'other');
      final a = await splitOf('s01e02');
      expect(await applySplitNames(a, 's02e05', 's02e06',
          originalStem: 's01e02', onLog: log.call), isFalse);
      await unparkSource(a, originalStem: 's01e02', onLog: log.call);
      expect(names(), ['s01e02.mkv', 's02e05.mkv']);
      expect(read('s02e05.mkv'), 'other');
      expect(log.text, contains('already exists'));
    });

    test('een mislukt origineel krijgt zijn naam pas terug als de rest klaar '
        'is, en blijft geparkeerd als een verhaal die naam kreeg', () async {
      final a = await splitOf('s01e16');
      final b = await splitOf('s01e21');
      expect(await applySplitNames(a, 's01e26', null,
          originalStem: 's01e16', onLog: log.call), isFalse);
      // s01e16's name is still free for s01e21's second story.
      expect(await applySplitNames(b, 's01e15', 's01e16',
          originalStem: 's01e21', onLog: log.call), isTrue);
      await unparkSource(a, originalStem: 's01e16', onLog: log.call);

      expect(names(), [
        's01e15.mkv', 's01e15.whisper.json',
        's01e16.mkv', 's01e16.unsplit.mkv', 's01e16.whisper.json',
      ]);
      expect(read('s01e16.mkv'), 'B');
      expect(read('s01e16.unsplit.mkv'), 'whole');
      expect(log.text, contains('is taken'));
    });
  });
}
