import '../models/video_title.dart';

/// Common interface for DVD and Blu-ray rippers.
///
/// Two-phase contract:
///   1. [loadTitles] — scan and parse disc metadata.
///   2. [rip] — encode selected titles to MKV.
///
/// Returns null from [loadTitles] on unrecoverable error; the caller is
/// expected to exit. [mountPath] is non-null when operating on an ISO image
/// inside a caller-managed mount scope.
abstract interface class VideoDiscRipper<T extends VideoTitle> {
  Future<({String discTitle, List<T> titles})?> loadTitles({String? mountPath});
  Future<void> rip(String discTitle, List<T> selected, {String? mountPath});
}
