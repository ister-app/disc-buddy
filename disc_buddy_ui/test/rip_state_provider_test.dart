import 'dart:async';
import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy_ui/models/rip_state.dart';
import 'package:disc_buddy_ui/models/settings.dart';
import 'package:disc_buddy_ui/providers/rip_state_provider.dart';
import 'package:disc_buddy_ui/providers/settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Settings that never touch the user's config file.
class _FixedSettings extends SettingsNotifier {
  @override
  Settings build() => Settings.defaults();
}

BlurayTitle _title(int index) => BlurayTitle(
      index: index,
      playlist: index.toString().padLeft(5, '0'),
      duration: const Duration(minutes: 22),
      audioCount: 1,
      subtitleCount: 0,
      audioLangs: const ['eng'],
      subtitleLangs: const [],
    );

void main() {
  late ProviderContainer container;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rip_state_test_');
    container = ProviderContainer(overrides: [
      settingsProvider.overrideWith(_FixedSettings.new),
    ]);
  });
  tearDown(() {
    container.dispose();
    tmp.deleteSync(recursive: true);
  });

  RipStateNotifier notifierFor(String id) =>
      container.read(ripStateProvider(id).notifier);

  /// Waits until the notifier leaves its in-progress state.
  Future<RipState> settled(String id) {
    final done = Completer<RipState>();
    final sub = container.listen<RipState>(ripStateProvider(id), (_, next) {
      if (next is RipCompleted || next is RipError) {
        if (!done.isCompleted) done.complete(next);
      }
    }, fireImmediately: true);
    return done.future.whenComplete(sub.close);
  }

  File touch(String name) =>
      File(p.join(tmp.path, name))..writeAsStringSync(name);

  group('title selection', () {
    const id = '/dev/test';

    Set<String> selected() =>
        (container.read(ripStateProvider(id)) as RipTitleSelection)
            .selectedKeys;

    test('toggle, select all and deselect all', () {
      final n = notifierFor(id);
      n.startTitleSelection('DISC', [_title(1), _title(2), _title(3)], {'1'});

      n.toggleTitle('2');
      n.toggleTitle('1');
      expect(selected(), {'2'});

      n.selectAll();
      expect(selected(), {'1', '2', '3'});

      n.deselectAll();
      expect(selected(), isEmpty);
    });

    test('naming step keeps only the selected titles, in disc order', () {
      final n = notifierFor(id);
      n.startTitleSelection(
          'DISC', [_title(1), _title(2), _title(3)], {'3', '1'},
          fingerprint: 'fp');
      n.proceedToNaming();

      final naming = container.read(ripStateProvider(id)) as RipNamingStep;
      expect(naming.selectedTitles.map((t) => t.displayKey), ['1', '3']);
      expect(naming.scanFingerprint, 'fp');
    });

    test('nothing selected → stays on the selection step', () {
      final n = notifierFor(id);
      n.startTitleSelection('DISC', [_title(1)], const {});
      n.proceedToNaming();
      expect(container.read(ripStateProvider(id)), isA<RipTitleSelection>());
    });

    test('subtitle step carries the naming choices', () {
      final n = notifierFor(id);
      n.startTitleSelection('DISC', [_title(1)], {'1'});
      n.proceedToNaming();
      n.proceedToSubtitles(
          nameHint: 'Seinfeld',
          seasons: [7],
          autoName: true,
          batchAssign: false);

      final step = container.read(ripStateProvider(id)) as RipSubtitleStep;
      expect(step.nameHint, 'Seinfeld');
      expect(step.seasons, [7]);
      expect(step.autoName, isTrue);
      expect(step.batchAssign, isFalse);
    });
  });

  group('startDirProcess', () {
    test('typed names rename the file, keep its extension and move sidecars',
        () async {
      final movie = touch('title_00001.mp4');
      touch('title_00001.en.srt');
      final other = touch('title_00002.mkv');
      final id = tmp.path;

      final result = settled(id);
      await notifierFor(id).startDirProcess(
        filePaths: [movie.path, other.path],
        extractSubtitles: false,
        subtitleLangs: '',
        fileNames: {movie.path: 'Movie One'},
      );
      final state = await result;

      expect(state, isA<RipCompleted>());
      expect((state as RipCompleted).outputFiles,
          [p.join(tmp.path, 'Movie One.mp4'), other.path]);
      expect(File(p.join(tmp.path, 'Movie One.mp4')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'Movie One.en.srt')).existsSync(), isTrue);
      expect(movie.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });

    test('never overwrites an existing file', () async {
      final a = touch('a.mkv');
      final taken = touch('Taken.mkv');
      final id = tmp.path;

      final result = settled(id);
      await notifierFor(id).startDirProcess(
        filePaths: [a.path],
        extractSubtitles: false,
        subtitleLangs: '',
        fileNames: {a.path: 'Taken'},
      );
      final state = await result as RipCompleted;

      expect(state.outputFiles, [a.path]);
      expect(a.readAsStringSync(), 'a.mkv');
      expect(taken.readAsStringSync(), 'Taken.mkv');
      expect(state.log.join('\n'), contains('already exists'));
    });

    test('says why when auto-naming or extraction is not configured',
        () async {
      final a = touch('a.mkv');
      final id = tmp.path;

      final result = settled(id);
      await notifierFor(id).startDirProcess(
        filePaths: [a.path],
        extractSubtitles: true,
        subtitleLangs: '',
        autoName: true,
      );
      final state = await result as RipCompleted;

      expect(state.outputFiles, [a.path]);
      final log = state.log.join('\n');
      expect(log, contains('Auto-naming skipped'));
      expect(log, contains('Subtitle extraction skipped'));
    });
  });
}
