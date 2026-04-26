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
    final json = await ConfigLoader.load();
    state = Settings.fromJson(json);
  }

  Future<void> save(Settings settings) async {
    state = settings;
    final file = File(ConfigLoader.defaultPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }

  void update(Settings Function(Settings) updater) {
    save(updater(state));
  }
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

bool _commandAvailable(String? configured, String defaultName) {
  if (configured != null) return File(configured).existsSync();
  final result = Process.runSync('which', [defaultName]);
  return result.exitCode == 0;
}
