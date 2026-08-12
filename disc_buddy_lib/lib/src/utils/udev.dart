/// Parses `udevadm info --query=property` output into a key→value map.
Map<String, String> parseUdevProps(String output) {
  final map = <String, String>{};
  for (final line in output.split('\n')) {
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    map[line.substring(0, eq)] = line.substring(eq + 1);
  }
  return map;
}

/// Cheap media identity from already-fetched udev props (no disc I/O).
///
/// Data discs: filesystem label + UUID (for ISO9660 the UUID is derived from
/// the volume creation timestamp, so it changes per pressing). Audio CDs:
/// track count + session lead-out offset. Empty string when no medium.
///
/// Only good for change *detection* across polls — udev may lag a swap
/// briefly; use `readDiscFingerprint` for an authoritative pre-rip check.
String mediaIdFromProps(Map<String, String> props) {
  if (props['ID_CDROM_MEDIA'] != '1') return '';
  final audioTracks = props['ID_CDROM_MEDIA_TRACK_COUNT_AUDIO'] ?? '';
  if ((int.tryParse(audioTracks) ?? 0) > 0) {
    final offset = props['ID_CDROM_MEDIA_SESSION_LAST_OFFSET'] ?? '';
    return 'audio:$audioTracks|$offset';
  }
  final label = (props['ID_FS_LABEL'] ?? '').trim();
  final uuid  = (props['ID_FS_UUID'] ?? '').trim();
  if (label.isEmpty && uuid.isEmpty) return 'data:';
  return 'data:$label|$uuid';
}
