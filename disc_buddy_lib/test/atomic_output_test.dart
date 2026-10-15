import 'dart:io';

import 'package:disc_buddy/src/utils/atomic_output.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('atomic_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('partPath zet .part vóór de extensie', () {
    expect(partPath('/a/b/Disc-title_01.mkv'), '/a/b/Disc-title_01.part.mkv');
    expect(partPath('/a/01-track.flac'), '/a/01-track.part.flac');
    expect(partPath('/a/noext'), '/a/noext.part');
  });

  group('withPartFile', () {
    test('succes → eindbestand bestaat, .part niet', () async {
      final finalFile = File(p.join(tmp.path, 'out.mkv'));
      final r = await withPartFile<bool>(finalFile, (part) async {
        expect(part.path, endsWith('out.part.mkv'));
        part.writeAsStringSync('data');
        return true;
      }, succeeded: (b) => b);
      expect(r, isTrue);
      expect(finalFile.readAsStringSync(), 'data');
      expect(File(partPath(finalFile.path)).existsSync(), isFalse);
    });

    test('mislukking → geen van beide', () async {
      final finalFile = File(p.join(tmp.path, 'out.mkv'));
      final r = await withPartFile<int>(finalFile, (part) async {
        part.writeAsStringSync('half');
        return 1;
      }, succeeded: (code) => code == 0);
      expect(r, 1);
      expect(finalFile.existsSync(), isFalse);
      expect(File(partPath(finalFile.path)).existsSync(), isFalse);
    });

    test('exception in body → opgeruimd en exception propageert', () async {
      final finalFile = File(p.join(tmp.path, 'out.mkv'));
      await expectLater(
        withPartFile<bool>(finalFile, (part) async {
          part.writeAsStringSync('half');
          throw StateError('boom');
        }, succeeded: (b) => b),
        throwsStateError,
      );
      expect(finalFile.existsSync(), isFalse);
      expect(File(partPath(finalFile.path)).existsSync(), isFalse);
    });

    test('succes zonder geschreven part → telt als mislukt', () async {
      final finalFile = File(p.join(tmp.path, 'out.mkv'));
      await withPartFile<bool>(finalFile, (_) async => true, succeeded: (b) => b);
      expect(finalFile.existsSync(), isFalse);
    });

    test('oud .part-restant wordt eerst opgeruimd', () async {
      final finalFile = File(p.join(tmp.path, 'out.mkv'));
      File(partPath(finalFile.path)).writeAsStringSync('stale');
      await withPartFile<bool>(finalFile, (part) async {
        expect(part.existsSync(), isFalse);
        return false;
      }, succeeded: (b) => b);
      expect(File(partPath(finalFile.path)).existsSync(), isFalse);
    });
  });
}
