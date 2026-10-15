import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy_cli/src/cli/naming_flow.dart';
import 'package:test/test.dart';

import 'fake_prompter.dart';

RipOptions opts({
  bool force = false,
  bool autoName = false,
  bool canAuto = true,
  bool whisper = false,
  String? titleHint,
  List<int>? seasonHint,
  Set<String>? subtitleLangs,
  bool? batchAssign,
}) =>
    RipOptions(
      device: null,
      outputDir: '/out',
      ffmpeg: 'ffmpeg',
      ffprobe: 'ffprobe',
      force: force,
      autoName: autoName,
      mkvextract: 'mkvextract',
      subtileOcr: 'subtile-ocr',
      whisper: whisper ? 'whisper-cli' : null,
      whisperModel: whisper ? 'model.bin' : null,
      tmdbToken: canAuto ? 'tok' : null,
      llmUrl: canAuto ? 'http://llm' : null,
      llmModel: canAuto ? 'm' : null,
      titleHint: titleHint,
      seasonHint: seasonHint,
      subtitleLangs: subtitleLangs,
      batchAssign: batchAssign,
    );

const titles = <NameableItem>[
  (filename: 'title_01.mkv', displayKey: '1', hasSubtitles: true),
  (filename: 'title_02.mkv', displayKey: '2', hasSubtitles: false),
];

String def(String f) => 'DISC-${f.replaceFirst('.mkv', '')}';

/// Records holding lists/sets compare by identity; match field-wise instead.
Matcher hints(String? title, List<int>? season) => predicate<NamingHints>(
    (h) => h.title == title && (season == null ? h.season == null : h.season != null && h.season!.join(',') == season.join(',')),
    'hints(title: $title, season: $season)');

Matcher extract(bool doExtract, Set<String>? langs) => predicate<ExtractChoice>(
    (e) => e.doExtract == doExtract && (langs == null ? e.langs == null : e.langs != null && e.langs!.containsAll(langs) && langs.containsAll(e.langs!)),
    'extract(doExtract: $doExtract, langs: $langs)');

void main() {
  group('collectNamingPrefs', () {
    test('--force → niets gevraagd, lege map', () async {
      final p = FakePrompter();
      expect(await collectNamingPrefs(opts(force: true), titles, p, defaultStemOf: def), isEmpty);
      expect(p.asked, isEmpty);
    });

    test('--auto-name → "?" voor titels met ondertitels, default voor de rest', () async {
      final p = FakePrompter();
      final prefs = await collectNamingPrefs(opts(autoName: true), titles, p, defaultStemOf: def);
      expect(prefs, {'title_01.mkv': '?', 'title_02.mkv': 'DISC-title_02'});
      expect(p.asked, isEmpty);
    });

    test('--auto-name met whisper → alles "?"', () async {
      final prefs = await collectNamingPrefs(
          opts(autoName: true, whisper: true), titles, FakePrompter(), defaultStemOf: def);
      expect(prefs.values, everyElement('?'));
    });

    test('--auto-name zonder LLM-config → gewone vraag', () async {
      final p = FakePrompter(['n']);
      final prefs = await collectNamingPrefs(
          opts(autoName: true, canAuto: false), titles, p, defaultStemOf: def);
      expect(prefs, isEmpty);
      expect(p.asked.single, contains('[y/N]'));
    });

    test('antwoord "?" → auto voor alle nameable titels', () async {
      final p = FakePrompter(['?']);
      final prefs = await collectNamingPrefs(opts(), titles, p, defaultStemOf: def);
      expect(prefs['title_01.mkv'], '?');
      expect(prefs['title_02.mkv'], 'DISC-title_02');
      expect(p.asked.single, contains('[y/?/N]'));
    });

    test('antwoord "y": Enter houdt default, naam wordt gesanitized, "?" alleen waar het kan', () async {
      final p = FakePrompter(['y', 'My: Name', '?']);
      final prefs = await collectNamingPrefs(opts(), titles, p, defaultStemOf: def);
      expect(prefs['title_01.mkv'], sanitizeFilename('My: Name'));
      // title_02 has no subtitles and no whisper: "?" is taken literally.
      expect(prefs['title_02.mkv'], sanitizeFilename('?'));
      expect(p.asked[1], contains('[DISC-title_01], ? for auto'));
      expect(p.asked[2], isNot(contains('? for auto')));
    });

    test('antwoord "y" en Enter → geen entry', () async {
      final prefs = await collectNamingPrefs(
          opts(), titles, FakePrompter(['j', null, null]), defaultStemOf: def);
      expect(prefs, isEmpty);
    });
  });

  group('askNamingHints', () {
    test('beide hints bekend → niets gevraagd', () async {
      final p = FakePrompter();
      final h = await askNamingHints(opts(titleHint: 'X', seasonHint: [2]), p);
      expect(h, hints('X', [2]));
      expect(p.asked, isEmpty);
    });

    test('alleen titel bekend → seizoen gevraagd', () async {
      final h = await askNamingHints(opts(titleHint: 'X'), FakePrompter(['4, 5']));
      expect(h, hints('X', [4, 5]));
    });

    test('alleen seizoen bekend → naam gevraagd, ? = auto', () async {
      expect(await askNamingHints(opts(seasonHint: [1]), FakePrompter(['?'])), hints(null, [1]));
      expect(await askNamingHints(opts(seasonHint: [1]), FakePrompter(['Show'])), hints('Show', [1]));
    });

    test('niets bekend: Enter → volledig auto; naam + Enter → film', () async {
      expect(await askNamingHints(opts(), FakePrompter([null])), hints(null, null));
      expect(await askNamingHints(opts(), FakePrompter(['Film', null])), hints('Film', null));
      expect(await askNamingHints(opts(), FakePrompter(['Show', '2'])), hints('Show', [2]));
    });
  });

  group('resolveNamingHints', () {
    test('zonder auto-name → null; met force → CLI-hints zonder vragen', () async {
      final p = FakePrompter();
      expect(await resolveNamingHints(opts(), p, anyAutoName: false), isNull);
      expect(await resolveNamingHints(opts(force: true, titleHint: 'T'), p, anyAutoName: true),
          hints('T', null));
      expect(p.asked, isEmpty);
    });
  });

  group('promptBatchAssign', () {
    test('CLI-waarde wint; force of ≤1 bestand vraagt niet', () async {
      final p = FakePrompter();
      expect(await promptBatchAssign(opts(batchAssign: true), 5, p), isTrue);
      expect(await promptBatchAssign(opts(force: true), 5, p), isNull);
      expect(await promptBatchAssign(opts(), 1, p), isNull);
      expect(p.asked, isEmpty);
    });

    test('anders gevraagd', () async {
      expect(await promptBatchAssign(opts(), 3, FakePrompter([true])), isTrue);
      expect(await promptBatchAssign(opts(), 3, FakePrompter([false])), isFalse);
    });
  });

  group('promptExtractSubtitles', () {
    test('nee → noExtract', () async {
      expect(await promptExtractSubtitles(opts(), FakePrompter([false])), noExtract);
    });

    test('ja + talen uit config → geen taalvraag', () async {
      final p = FakePrompter([true]);
      final r = await promptExtractSubtitles(opts(subtitleLangs: {'en'}), p);
      expect(r, extract(true, {'en'}));
      expect(p.asked, hasLength(1));
    });

    test('ja + lege configset ("all") → langs null', () async {
      final r = await promptExtractSubtitles(opts(subtitleLangs: {}), FakePrompter([true]));
      expect(r, extract(true, null));
    });

    test('ja + interactieve talen', () async {
      expect(await promptExtractSubtitles(opts(), FakePrompter([true, 'EN, nl'])),
          extract(true, {'en', 'nl'}));
      expect(await promptExtractSubtitles(opts(), FakePrompter([true, null])),
          extract(true, null));
    });
  });
}
