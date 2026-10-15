import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy/src/utils/file_utils.dart' show confirmOverwrite;
import 'package:disc_buddy/src/utils/languages.dart' show askLanguages;
import 'package:test/test.dart';

/// Plays back a scripted list of answers. `null` as an answer means
/// "use the default" (Enter) for confirm/choose/readLine alike.
class FakePrompter implements Prompter {
  FakePrompter(this.answers);
  final List<Object?> answers;
  final List<String> asked = [];

  Object? _next(String q) {
    asked.add(q);
    if (answers.isEmpty) fail('no scripted answer left for: $q');
    return answers.removeAt(0);
  }

  @override
  Future<bool> confirm(String question, {bool defaultValue = false}) async =>
      (_next(question) as bool?) ?? defaultValue;

  @override
  Future<int?> choose(String question, List<String> options,
          {int? defaultIndex}) async =>
      (_next(question) as int?) ?? defaultIndex;

  @override
  Future<String> readLine(String prompt, {String defaultValue = ''}) async =>
      (_next(prompt) as String?) ?? defaultValue;
}

void main() {
  group('NonInteractivePrompter', () {
    const p = NonInteractivePrompter();

    test('confirm geeft defaultValue terug', () async {
      expect(await p.confirm('x?'), isFalse);
      expect(await p.confirm('x?', defaultValue: true), isTrue);
    });

    test('choose geeft defaultIndex of null terug', () async {
      expect(await p.choose('q', ['a', 'b']), isNull);
      expect(await p.choose('q', ['a', 'b'], defaultIndex: 1), 1);
      expect(await p.choose('q', ['a', 'b'], defaultIndex: 5), isNull);
      expect(await p.choose('q', [], defaultIndex: 0), isNull);
    });

    test('readLine geeft defaultValue terug', () async {
      expect(await p.readLine('name: '), '');
      expect(await p.readLine('name: ', defaultValue: 'eng'), 'eng');
    });
  });

  group('askLanguages', () {
    final log = <String>[];
    void onLog(String m, {bool isError = false}) => log.add(m);
    setUp(log.clear);

    test('niet-interactief → huidige talen ongewijzigd', () async {
      final r = await askLanguages(
        audioLabels: ['AC3 5.1', ''],
        audioCurrents: ['eng', ''],
        subCurrents: ['dut'],
        prompter: const NonInteractivePrompter(),
        onLog: onLog,
      );
      expect(r.audioLangs, ['eng', '']);
      expect(r.subLangs, ['dut']);
      expect(log.first, contains('Current languages'));
    });

    test('manual=ja → antwoorden overschrijven huidige talen', () async {
      final p = FakePrompter([true, 'dut', null, 'eng']);
      final r = await askLanguages(
        audioLabels: const [],
        audioCurrents: ['eng', 'fre'],
        subCurrents: ['dut'],
        prompter: p,
        onLog: onLog,
      );
      expect(r.audioLangs, ['dut', 'fre']); // Enter keeps current
      expect(r.subLangs, ['eng']);
      expect(p.asked.first, contains('Set languages manually'));
    });

    test('spatie-antwoord → lege taal', () async {
      final p = FakePrompter([true, ' ', '  ']);
      final r = await askLanguages(
        audioLabels: const [],
        audioCurrents: ['eng'],
        subCurrents: ['dut'],
        prompter: p,
        onLog: onLog,
      );
      expect(r.audioLangs, ['']);
      expect(r.subLangs, ['']);
    });

    test('lege huidige taal wordt ook zonder manual gevraagd', () async {
      final p = FakePrompter([false, 'ger']);
      final r = await askLanguages(
        audioLabels: const [],
        audioCurrents: ['eng', ''],
        subCurrents: const [],
        prompter: p,
        onLog: onLog,
      );
      expect(r.audioLangs, ['eng', 'ger']);
      expect(p.asked.length, 2);
    });

    test('geen tracks → niets gevraagd', () async {
      final p = FakePrompter([]);
      final r = await askLanguages(
        audioLabels: const [],
        audioCurrents: const [],
        subCurrents: const [],
        prompter: p,
        onLog: onLog,
      );
      expect(r.audioLangs, isEmpty);
      expect(p.asked, isEmpty);
    });
  });

  group('confirmOverwrite met Prompter', () {
    late Directory tmp;
    final log = <String>[];
    void onLog(String m, {bool isError = false}) => log.add(m);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('prompter_test_');
      log.clear();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('prompter ja → verwijderd en true', () async {
      final f = File('${tmp.path}/a.mkv')..writeAsStringSync('x');
      final ok = await confirmOverwrite(f,
          force: false, onLog: onLog, prompter: FakePrompter([true]));
      expect(ok, isTrue);
      expect(f.existsSync(), isFalse);
    });

    test('prompter nee → "Skipped" en false', () async {
      final f = File('${tmp.path}/b.mkv')..writeAsStringSync('x');
      final ok = await confirmOverwrite(f,
          force: false, onLog: onLog, prompter: FakePrompter([false]));
      expect(ok, isFalse);
      expect(f.existsSync(), isTrue);
      expect(log, contains('   Skipped.'));
    });

    test('zonder prompter (default) → overslaan', () async {
      final f = File('${tmp.path}/c.mkv')..writeAsStringSync('x');
      expect(await confirmOverwrite(f, force: false, onLog: onLog), isFalse);
      expect(f.existsSync(), isTrue);
    });
  });
}
