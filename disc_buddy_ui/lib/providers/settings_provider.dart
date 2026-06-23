import 'dart:convert';
import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/settings.dart';

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() {
    _load();
    return Settings.defaults();
  }

  Future<void> _load() async {
    try {
      final json = await ConfigLoader.load();
      state = Settings.fromJson(json);
    } catch (e) {
      // Keep the default settings if the config can't be read/parsed.
      stderr.writeln('Settings load failed, using defaults: $e');
    }
  }

  Future<void> save(Settings settings) async {
    state = settings;
    final file = File(ConfigLoader.defaultPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }

  /// Applies [updater] and persists. Returns the save future so callers can
  /// await it / observe failures instead of silently dropping them.
  Future<void> update(Settings Function(Settings) updater) => save(updater(state));
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  SettingsNotifier.new,
);

/// Returns true when both mkvextract and subtile-ocr are usable:
/// either the configured path exists, or the default command name is on PATH.
final subtitleToolsAvailableProvider = Provider<bool>((ref) {
  final s = ref.watch(settingsProvider);
  return _commandAvailable(s.mkvextract, 'mkvextract') &&
      _commandAvailable(s.subtileOcr, 'subtile-ocr');
});

// `which <name>` result cache. A binary's presence on PATH doesn't change
// during a session, so memoizing avoids spawning a subprocess on every settings
// change (which ran synchronously on the UI thread and caused jank).
final _whichCache = <String, bool>{};

bool _commandAvailable(String? configured, String defaultName) {
  // An explicitly configured path can be edited at runtime, so re-check it
  // (existsSync is cheap). Only the PATH lookup is cached.
  if (configured != null) return File(configured).existsSync();
  return _whichCache.putIfAbsent(
    defaultName,
    () => Process.runSync('which', [defaultName]).exitCode == 0,
  );
}
