import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;

import 'directory_mode.dart' show videoExtensions;

/// Low-level rename used by [renameFile]; injectable for tests.
typedef RenameFn = Future<FileSystemEntity> Function(File src, String destPath);

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

/// Renames [src] to [destPath], returning whether it succeeded.
///
/// Falls back to copy+delete when the rename crosses a filesystem boundary
/// (EXDEV — `rename(2)` cannot move between mounts), and logs + returns false
/// on any other failure rather than throwing, so one bad file doesn't abort
/// the whole batch.
Future<bool> renameFile(
  File src,
  String destPath, {
  LogCallback? onLog,
  RenameFn? rename,
}) async {
  rename ??= (f, d) => f.rename(d);
  try {
    await rename(src, destPath);
    return true;
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode == 18) { // EXDEV: cross-device link
      try {
        await src.copy(destPath);
        await src.delete();
        return true;
      } catch (e2) {
        emitLog(onLog, '   Rename (copy fallback) failed for ${src.path}: $e2',
            isError: true);
        return false;
      }
    }
    emitLog(onLog, '   Rename failed for ${src.path}: $e', isError: true);
    return false;
  }
}

/// Renames every `<oldStem>.*.srt` and `<oldStem>.whisper.json` sidecar in
/// [outDir] to use [newStem], so cached transcripts follow the renamed file.
Future<void> renameAssociatedSidecars(
  Directory outDir,
  String oldStem,
  String newStem, {
  LogCallback? onLog,
  RenameFn? rename,
}) async {
  await for (final entry in outDir.list()) {
    if (entry is! File) continue;
    final base = p.basename(entry.path);
    if (!base.startsWith('$oldStem.')) continue;
    if (!base.endsWith('.srt') && !base.endsWith('.whisper.json')) continue;
    final suffix = base.substring(oldStem.length);
    await renameFile(entry, p.join(outDir.path, '$newStem$suffix'),
        onLog: onLog, rename: rename);
  }
}

/// Renames a single media file to `<newStem><ext>` next to it, taking its
/// sidecars along. Skips (with a message) when the target already exists or
/// when [newStem] equals the current stem. Returns true when renamed.
Future<bool> renameWithSidecars(
  File file,
  String newStem, {
  LogCallback? onLog,
  RenameFn? rename,
}) async {
  final oldStem = p.basenameWithoutExtension(file.path);
  if (newStem == oldStem) return false;
  final ext = p.extension(file.path);
  final outDir = file.parent;
  final newFile = File(p.join(outDir.path, '$newStem$ext'));
  if (await newFile.exists()) {
    emitLog(onLog, 'Rename skipped: "${p.basename(newFile.path)}" already exists.',
        isError: true);
    return false;
  }
  if (!await renameFile(file, newFile.path, onLog: onLog, rename: rename)) {
    return false;
  }
  emitLog(onLog, 'Renamed: ${file.path}\n      → ${newFile.path}');
  await renameAssociatedSidecars(outDir, oldStem, newStem,
      onLog: onLog, rename: rename);
  return true;
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
