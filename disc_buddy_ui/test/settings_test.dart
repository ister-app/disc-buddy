import 'package:disc_buddy_ui/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown config keys survive a load → edit → save round trip', () {
    final loaded = Settings.fromJson({
      'output': '/videos',
      'transcribe-lang': 'nl',
      'subtitle-langs': 'en,nl', // CLI-only
      'season': 7, // CLI-only
    });

    final saved = loaded.copyWith(videoDir: '/other', llmModel: 'm').toJson();

    expect(saved['output'], '/other');
    expect(saved['llm-model'], 'm');
    expect(saved['transcribe-lang'], 'nl');
    expect(saved['subtitle-langs'], 'en,nl');
    expect(saved['season'], 7);
  });

  test('clearing a known field removes its key, not the unknown ones', () {
    final loaded = Settings.fromJson({'output': '/videos', 'name': 'Seinfeld'});
    final saved = loaded.copyWith(videoDir: null).toJson();
    expect(saved.containsKey('output'), isFalse);
    expect(saved['name'], 'Seinfeld');
  });
}
