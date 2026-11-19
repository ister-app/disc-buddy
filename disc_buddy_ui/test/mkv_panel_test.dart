import 'package:disc_buddy_ui/models/disc_content.dart';
import 'package:disc_buddy_ui/models/settings.dart';
import 'package:disc_buddy_ui/providers/drive_list_provider.dart';
import 'package:disc_buddy_ui/providers/settings_provider.dart';
import 'package:disc_buddy_ui/widgets/mkv_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

void main() {
  const path = '/videos/title_00001.mkv';

  Future<void> pumpPanel(
    WidgetTester tester, {
    required Settings settings,
    required bool ocrTools,
    required bool whisper,
  }) =>
      tester.pumpWidget(ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _FixedSettings(settings)),
          subtitleToolsAvailableProvider.overrideWithValue(ocrTools),
          whisperAvailableProvider.overrideWithValue(whisper),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MkvPanel(
              entry: VirtualFileEntry(MkvEntry(path)),
              content: MkvContent(path),
            ),
          ),
        ),
      ));

  final withLlm = Settings.defaults().copyWith(
      tmdbToken: 'token', llmUrl: 'http://localhost:1', llmModel: 'model');

  testWidgets('without LLM settings there is only a name field',
      (tester) async {
    await pumpPanel(tester,
        settings: Settings.defaults(), ocrTools: true, whisper: true);

    expect(find.text('Auto name'), findsNothing);
    expect(find.text('Output name (without .mkv)'), findsOneWidget);
    // Tools found on PATH count as available, not only configured paths.
    expect(find.text('Extract subtitles'), findsOneWidget);
  });

  testWidgets('auto name swaps the name field for the hint fields',
      (tester) async {
    await pumpPanel(tester, settings: withLlm, ocrTools: false, whisper: true);

    expect(find.text('Auto name'), findsOneWidget);
    expect(find.text('Output name (without .mkv)'), findsOneWidget);
    expect(find.text('Extract subtitles'), findsNothing);

    await tester.tap(find.text('Auto name'));
    await tester.pump();

    expect(find.text('Output name (without .mkv)'), findsNothing);
    expect(find.text('Series / Movie name (optional hint)'), findsOneWidget);
    expect(find.text('Season(s)'), findsOneWidget);
  });

  testWidgets('auto name needs a text source: OCR tools or whisper',
      (tester) async {
    await pumpPanel(tester,
        settings: withLlm, ocrTools: false, whisper: false);

    expect(find.text('Auto name'), findsNothing);
  });
}
