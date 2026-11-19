import 'package:file_picker/file_picker.dart';

/// Shows the native directory picker and returns the chosen directory as a
/// filesystem path, or null when the dialog was cancelled.
///
/// `FilePicker.pickDirectory` returns a [Uri] because Android hands out
/// `content://` URIs; this app runs on Linux, where it is always `file://`.
/// Anything else cannot be opened by the rippers and is treated as a cancel.
Future<String?> pickDirectoryPath({
  String? dialogTitle,
  String? initialDirectory,
}) async {
  final uri = await FilePicker.pickDirectory(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
  );
  if (uri == null || !uri.isScheme('file')) return null;
  return uri.toFilePath();
}
