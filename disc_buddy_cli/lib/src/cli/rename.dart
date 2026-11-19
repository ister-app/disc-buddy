import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;

import 'directory_mode.dart' show videoExtensions;

// The file-level rename helpers live in the library (the UI needs them too);
// re-exported so CLI code and tests keep importing them from here.
export 'package:disc_buddy/disc_buddy.dart'
    show RenameFn, renameFile, renameAssociatedSidecars, renameWithSidecars;

/// Builds the default output file stem for a title.
String defaultStem(String discTitle, String titleFilename) {
  final stem = titleFilename.replaceFirst(RegExp(r'\.mkv$'), '');
  return '${sanitizeFilename(discTitle)}-$stem';
}

/// Renames MKV files (and associated SRT files) in [outDir] according to
/// [namePrefs]. Entries whose value equals the default stem are skipped.
Future<void> applyRenames(
  Directory outDir,
  String discTitle,
  List<String> filenames,
  Map<String, String> namePrefs, {
  LogCallback? onLog,
  RenameFn? rename,
}) async {
  for (final filename in filenames) {
    final newStem = namePrefs[filename];
    if (newStem == null || newStem == '?') continue;

    final oldStem = defaultStem(discTitle, filename);
    if (newStem == oldStem) continue;

    final oldMkv = File(p.join(outDir.path, '$oldStem.mkv'));
    final newMkv = File(p.join(outDir.path, '$newStem.mkv'));

    if (!await oldMkv.exists()) continue;
    if (await newMkv.exists()) {
      emitLog(onLog, '   Rename skipped: "$newStem.mkv" already exists.',
          isError: true);
      continue;
    }

    if (await renameFile(oldMkv, newMkv.path, onLog: onLog, rename: rename)) {
      emitLog(onLog, 'Renamed: ${oldMkv.path}\n      → ${newMkv.path}');
      await renameAssociatedSidecars(outDir, oldStem, newStem,
          onLog: onLog, rename: rename);
    }
  }
}

/// Moves the source of [split] aside to `<stem>.unsplit<ext>` (dropping its
/// cached sidecars, they describe the whole file), so no story's new name
/// collides with a source still waiting its turn: in a batch,
/// `s01e05.mkv` may hold s02e14 while s01e05 sits in another file.
Future<StorySplit> parkSource(StorySplit split) async {
  final src = split.source;
  await deleteWithSidecars(src, keepFile: true);
  final parked = File(p.join(src.parent.path,
      '${p.basenameWithoutExtension(src.path)}.unsplit${p.extension(src.path)}'));
  await src.rename(parked.path);
  return (
    source: parked,
    first: split.first,
    second: split.second,
    cut: split.cut,
  );
}

/// Settles a `--split-stories` file, parked by [parkSource], once both
/// halves were auto-named:
/// - two different stems → the halves take them and replace the source;
/// - the same stem twice → one story fills the file: the halves go and the
///   source takes that stem;
/// - anything else (a half unnamed, a target taken) → the halves go and the
///   source stays parked; [unparkSource] gives it [originalStem] back once
///   every other file has settled, so that name cannot block a story's.
/// Returns true when the source was renamed or replaced.
Future<bool> applySplitNames(
  StorySplit split,
  String? firstStem,
  String? secondStem, {
  required String originalStem,
  LogCallback? onLog,
}) async {
  final src = split.source;
  final dir = src.parent;
  final ext = p.extension(src.path);

  if (firstStem != null && secondStem != null && firstStem != secondStem) {
    final taken = [firstStem, secondStem]
        .where((s) => File(p.join(dir.path, '$s$ext')).existsSync())
        .toList();
    if (taken.isEmpty &&
        await renameWithSidecars(split.first, firstStem, onLog: onLog)) {
      if (await renameWithSidecars(split.second, secondStem, onLog: onLog)) {
        await src.delete();
        emitLog(onLog, 'Replaced $originalStem$ext by its two stories.');
        return true;
      }
      // Undo the first half so the source stays the only copy.
      await deleteWithSidecars(File(p.join(dir.path, '$firstStem$ext')));
    } else if (taken.isNotEmpty) {
      emitLog(onLog, 'Split skipped for $originalStem$ext: '
          '${taken.map((s) => '"$s$ext"').join(', ')} already exists.',
          isError: true);
    }
  } else if (firstStem != null && firstStem == secondStem) {
    await deleteWithSidecars(split.first);
    await deleteWithSidecars(split.second);
    emitLog(onLog, '   Both halves of $originalStem$ext are $firstStem — one '
        'story, keeping the file whole.');
    if (await renameWithSidecars(src, firstStem, onLog: onLog)) return true;
  } else {
    emitLog(onLog, '   Could not name both stories of $originalStem$ext — '
        'keeping its original name.', isError: true);
  }
  await deleteWithSidecars(split.first);
  await deleteWithSidecars(split.second);
  return false;
}

/// Gives a source [applySplitNames] left parked its [originalStem] back.
/// When a story took that name meanwhile it stays `<stem>.unsplit<ext>`.
Future<void> unparkSource(
  StorySplit split, {
  required String originalStem,
  LogCallback? onLog,
}) async {
  if (!await renameWithSidecars(split.source, originalStem, onLog: onLog)) {
    emitLog(onLog, '   Kept ${p.basename(split.source.path)}: '
        '"$originalStem${p.extension(split.source.path)}" is taken.',
        isError: true);
  }
}

/// Deletes [file] (unless [keepFile]) and its `<stem>.*.srt` /
/// `<stem>.whisper.json` sidecars.
Future<void> deleteWithSidecars(File file, {bool keepFile = false}) async {
  final stem = p.basenameWithoutExtension(file.path);
  if (!keepFile && await file.exists()) await file.delete();
  final entries = await file.parent.list().toList();
  // `<stem>.story1.mkv` shares the prefix: its sidecars are not ours.
  final longerStems = [
    for (final e in entries)
      if (e is File &&
          e.path != file.path &&
          videoExtensions.contains(p.extension(e.path).toLowerCase()) &&
          p.basenameWithoutExtension(e.path).startsWith('$stem.'))
        p.basenameWithoutExtension(e.path),
  ];
  for (final entry in entries) {
    if (entry is! File) continue;
    final base = p.basename(entry.path);
    if (!base.startsWith('$stem.')) continue;
    if (longerStems.any((other) => base.startsWith('$other.'))) continue;
    if (base.endsWith('.srt') || base.endsWith('.whisper.json')) {
      await entry.delete();
    }
  }
}
