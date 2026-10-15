import 'dart:io';
import 'log.dart';
import 'prompter.dart';

// Monotonic counter so two chapter files created in the same millisecond (and
// process) don't collide on their temp-file names.
int _chapterFileSeq = 0;

/// Writes a temporary ffmetadata file containing chapter marks.
/// Returns null if [chapters] has fewer than 2 entries.
/// The caller is responsible for deleting the returned file after use.
Future<File?> writeChapterMetadata(
  List<Duration> chapters,
  Duration totalDuration,
) async {
  if (chapters.length < 2) return null;
  final buf = StringBuffer(';FFMETADATA1\n\n');
  for (var i = 0; i < chapters.length; i++) {
    final start = chapters[i].inMilliseconds;
    final end   = i + 1 < chapters.length
        ? chapters[i + 1].inMilliseconds - 1
        : totalDuration.inMilliseconds;
    final label = (i + 1).toString().padLeft(2, '0');
    buf.write('[CHAPTER]\nTIMEBASE=1/1000\nSTART=$start\nEND=$end\ntitle=Chapter $label\n\n');
  }
  final ts      = DateTime.now().millisecondsSinceEpoch;
  final tmpFile = File('${Directory.systemTemp.path}'
      '/disc_buddy_chapters_${pid}_${ts}_${_chapterFileSeq++}.txt');
  await tmpFile.writeAsString(buf.toString());
  return tmpFile;
}

/// Checks if [file] already exists and asks for overwrite confirmation.
///
/// Returns `true` if ripping may proceed (file did not exist, or was deleted
/// after confirmation). Returns `false` if the file should be skipped.
///
/// [overwrite] — when non-null (and not [force]), the decision is made from
/// the set instead of prompting: paths in the set are deleted and re-ripped,
/// other existing files are skipped. Used by UIs that ask up front which
/// files to overwrite.
///
/// [prompter] — asked when neither [force] nor [overwrite] decides. The
/// default [NonInteractivePrompter] answers "no", so an existing file is
/// skipped unless the caller passes an interactive prompter.
Future<bool> confirmOverwrite(File file,
    {required bool force,
    LogCallback? onLog,
    Set<String>? overwrite,
    Prompter prompter = const NonInteractivePrompter()}) async {
  if (!await file.exists()) return true;
  if (overwrite != null && !force && !overwrite.contains(file.path)) {
    emitLog(onLog, '   Skipped.');
    return false;
  }
  final shouldDelete = force || (overwrite != null) ||
      await prompter.confirm('   File already exists — delete? [y/N] ');
  if (shouldDelete) {
    try {
      await file.delete();
      return true;
    } catch (e) {
      // The delete failed (e.g. permissions). Returning true here would let the
      // caller write over a file we couldn't remove, so report failure instead.
      emitLog(onLog, '   Cannot delete file: $e', isError: true);
      return false;
    }
  }
  emitLog(onLog, '   Skipped.');
  return false;
}
