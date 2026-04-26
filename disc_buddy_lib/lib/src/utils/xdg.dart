import 'dart:io';

String xdgConfigHome() {
  final xdg  = Platform.environment['XDG_CONFIG_HOME'];
  final home = Platform.environment['HOME'] ?? '';
  return (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.config';
}

String xdgCacheHome() {
  final xdg  = Platform.environment['XDG_CACHE_HOME'];
  final home = Platform.environment['HOME'] ?? '';
  return (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.cache';
}

/// Resolves an XDG user directory by [name] (e.g. 'VIDEOS', 'MUSIC').
/// Checks env var `XDG_<NAME>_DIR` first, then `user-dirs.dirs`, then [fallback].
/// [fallback] may contain the literal `$HOME` which is expanded automatically.
String xdgUserDir(String name, {required String fallback}) {
  final home   = Platform.environment['HOME'] ?? '';
  final envKey = 'XDG_${name}_DIR';
  final envVal = Platform.environment[envKey];
  if (envVal != null && envVal.isNotEmpty) return envVal;
  final file = File('${xdgConfigHome()}/user-dirs.dirs');
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      final m = RegExp('^$envKey="(.*)"').firstMatch(line.trim());
      if (m != null) return m.group(1)!.replaceAll(r'$HOME', home);
    }
  }
  return fallback.replaceAll(r'$HOME', home);
}
