import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;

// The file-level rename helpers live in the library (the UI needs them too);
// re-exported so CLI code and tests keep importing them from here.
export 'package:disc_buddy/disc_buddy.dart'
    show
        RenameFn,
        renameFile,
        renameAssociatedSidecars,
        renameWithSidecars,
        parkSource,
        applySplitNames,
        unparkSource,
        deleteWithSidecars;

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
