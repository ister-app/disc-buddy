import 'dart:io';
import 'tty.dart';

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
  final tmpFile = File('${Directory.systemTemp.path}/disc_buddy_chapters_$ts.txt');
  await tmpFile.writeAsString(buf.toString());
  return tmpFile;
}

/// Checks if [file] already exists and asks for overwrite confirmation.
///
/// Returns `true` if ripping may proceed (file did not exist, or was deleted
/// after confirmation). Returns `false` if the file should be skipped.
Future<bool> confirmOverwrite(File file, {required bool force}) async {
  if (!await file.exists()) return true;
  if (force || ttyConfirm('   File already exists — delete? [y/N] ')) {
    await file.delete().catchError((e) {
      stderr.writeln('   Cannot delete file: $e');
      return File('');
    });
    return true;
  }
  stdout.writeln('   Skipped.');
  return false;
}
