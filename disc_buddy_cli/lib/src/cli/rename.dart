import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;

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
