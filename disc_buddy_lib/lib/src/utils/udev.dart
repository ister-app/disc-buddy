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
