import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart';

/// Path a rip writes to before it is complete: `name.part.mkv` for
/// `name.mkv`. The extension stays last so ffmpeg still picks the container
/// from it, and the file sits next to the final one so the rename is atomic.
String partPath(String finalPath) {
  final ext = p.extension(finalPath);
  final stem = finalPath.substring(0, finalPath.length - ext.length);
  return '$stem.part$ext';
}

/// Runs [body] against the `.part` sibling of [finalFile] and finalises it.
///
/// A stale `.part` from an earlier run is removed first. When [body] returns
/// a value for which [succeeded] is true the part file is renamed onto
/// [finalFile]; otherwise (including when [body] throws) the part file is
/// deleted, so an interrupted or failed rip never leaves a half-written file
/// under the final name.
Future<T> withPartFile<T>(
  File finalFile,
  Future<T> Function(File part) body, {
  required bool Function(T result) succeeded,
  LogCallback? onLog,
}) async {
  final part = File(partPath(finalFile.path));
  await _deleteQuietly(part, onLog);
  T result;
  var ok = false;
  try {
    result = await body(part);
    ok = succeeded(result);
    if (ok) {
      if (await part.exists()) {
        await part.rename(finalFile.path);
      } else {
        ok = false;
      }
    }
    return result;
  } finally {
    if (!ok) await _deleteQuietly(part, onLog);
  }
}

Future<void> _deleteQuietly(File f, LogCallback? onLog) async {
  if (!await f.exists()) return;
  try {
    await f.delete();
  } catch (e) {
    emitLog(onLog, '   Cannot delete ${f.path}: $e', isError: true);
  }
}
