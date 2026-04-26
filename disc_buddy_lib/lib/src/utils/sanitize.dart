/// Removes filesystem-unsafe characters and normalizes whitespace.
String sanitizeFilename(dynamic s) => (s?.toString() ?? '')
    .trim()
    .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
    .replaceAll(RegExp(r'\s+'), ' ');
