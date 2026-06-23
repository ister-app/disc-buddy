import 'dart:io';
import 'tty.dart';
import '../rippers/video_disc_ripper.dart' show LogCallback;

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
Future<bool> confirmOverwrite(File file, {required bool force, LogCallback? onLog}) async {
  if (!await file.exists()) return true;
  final shouldDelete = force ||
      (onLog == null && ttyConfirm('   File already exists — delete? [y/N] '));
  if (shouldDelete) {
    try {
      await file.delete();
      return true;
    } catch (e) {
      // The delete failed (e.g. permissions). Returning true here would let the
      // caller write over a file we couldn't remove, so report failure instead.
      final msg = '   Cannot delete file: $e';
      if (onLog != null) { onLog(msg, isError: true); } else { stderr.writeln(msg); }
      return false;
    }
  }
  if (onLog != null) { onLog('   Skipped.'); } else { stdout.writeln('   Skipped.'); }
  return false;
}
