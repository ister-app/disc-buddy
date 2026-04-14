import 'dart:convert';
import 'dart:io';

class ConfigLoader {
  /// Default config path per XDG Base Directory spec:
  ///   $XDG_CONFIG_HOME/disc-buddy/config.json
  ///   fallback: $HOME/.config/disc-buddy/config.json
  static String get defaultPath {
    final xdg  = Platform.environment['XDG_CONFIG_HOME'];
    final home = Platform.environment['HOME'] ?? '';
    final base =
        (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.config';
    return '$base/disc-buddy/config.json';
  }

  /// Loads the config from [path] or [defaultPath].
  /// Returns an empty map if the file does not exist.
  /// Prints a warning to stderr and returns an empty map on parse errors.
  static Future<Map<String, dynamic>> load({String? path}) async {
    final file = File(path ?? defaultPath);
    if (!await file.exists()) return {};
    try {
      final content = await file.readAsString();
      final parsed  = jsonDecode(content);
      if (parsed is Map<String, dynamic>) return parsed;
      stderr.writeln(
          'Warning: config file "${file.path}" must be a JSON object — ignored.');
      return {};
    } on FormatException catch (e) {
      stderr.writeln(
          'Warning: config file "${file.path}" contains invalid JSON: ${e.message} — ignored.');
      return {};
    } catch (e) {
      stderr.writeln('Warning: could not read config file "${file.path}": $e — ignored.');
      return {};
    }
  }
}
