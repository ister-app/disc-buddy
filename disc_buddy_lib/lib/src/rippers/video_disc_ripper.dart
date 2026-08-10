import 'package:path/path.dart' as p;
import '../models/video_title.dart';
import '../utils/sanitize.dart';

/// Callback for log messages from rippers.
/// [isError] is true for error/warning messages (stderr equivalent).
typedef LogCallback = void Function(String message, {bool isError});

/// Output path a video rip will write for [title]:
/// `<outputDir>/<discTitle>/<discTitle>-<title.filename>`.
///
/// Exposed so UIs can predict output files (e.g. for overwrite prompts)
/// before starting a rip. Must stay in sync with the DVD/Blu-ray rippers,
/// which build their output paths through this function.
String videoTitleOutputPath(
        String outputDir, String discTitle, VideoTitle title) =>
    p.join(outputDir, sanitizeFilename(discTitle),
        '${sanitizeFilename(discTitle)}-${title.filename}');

/// Common interface for DVD and Blu-ray rippers.
///
/// Two-phase contract:
///   1. [loadTitles] — scan and parse disc metadata.
///   2. [rip] — encode selected titles to MKV.
///
/// Returns null from [loadTitles] on unrecoverable error; the caller is
/// expected to exit. [mountPath] is non-null when operating on an ISO image
/// inside a caller-managed mount scope.
/// [rip]'s [overwrite] set mirrors the Audio CD ripper: when non-null,
/// existing output files whose path is in the set are deleted and re-ripped;
/// other existing files are skipped without prompting. When null, the legacy
/// behavior applies (force deletes, interactive TTY asks per file, UI skips).
abstract interface class VideoDiscRipper<T extends VideoTitle> {
  Future<({String discTitle, List<T> titles})?> loadTitles({String? mountPath});
  Future<void> rip(String discTitle, List<T> selected,
      {String? mountPath, Set<String>? overwrite});
}

