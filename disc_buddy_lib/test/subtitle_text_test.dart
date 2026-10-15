import 'dart:io';

import 'package:disc_buddy/src/naming/subtitle_text.dart';
import 'package:test/test.dart';

const _recapSrt = '1\n'
    '00:00:01,000 --> 00:00:03,000\n'
    'Previously on Flikken...\n\n'
    '2\n'
    '00:00:04,000 --> 00:00:06,000\n'
    'Last week stuff.\n\n'
    '3\n'
    '00:02:30,000 --> 00:02:33,000\n'
    'The real episode starts.\n\n'
    '4\n'
    '00:02:34,000 --> 00:02:36,000\n'
    'More dialogue.\n';

void main() {
  group('stripRecap', () {
    test('knipt de recap weg na de eerste lange stilte', () {
      int? cut;
      final out = stripRecap(_recapSrt, onStripped: (c) => cut = c);
      expect(out, startsWith('3\n00:02:30'));
      expect(out, isNot(contains('Previously on')));
      expect(cut, isNotNull);
    });

    test('doet niets zonder "previously on" in het eerste blok', () {
      final plain = _recapSrt.replaceFirst('Previously on Flikken...', 'Hi.');
      expect(stripRecap(plain), plain);
    });

    test('doet niets zonder voldoende gat', () {
      final noGap = _recapSrt.replaceAll('00:02:3', '00:00:1');
      expect(stripRecap(noGap), noGap);
    });

    test('lege of ongeldige SRT blijft ongewijzigd', () {
      expect(stripRecap(''), '');
      expect(stripRecap('just text'), 'just text');
    });
  });

  group('stripSrtFormatting', () {
    test('verwijdert nummers en tijdcodes, voegt regels samen', () {
      expect(
        stripSrtFormatting('1\n00:00:01,000 --> 00:00:02,000\nHello\nthere\n\n2\n'
            '00:00:03,000 --> 00:00:04,000\nBye\n'),
        'Hello there Bye',
      );
    });
  });

  group('langFromSrtFile', () {
    test('tweeletterige code', () {
      expect(langFromSrtFile(File('/x/ep.nl.srt')), 'nl');
    });
    test('drieletterige code wordt vertaald', () {
      expect(langFromSrtFile(File('/x/ep.dut.srt')), 'nl');
      expect(langFromSrtFile(File('/x/ep.eng.srt')), 'en');
    });
    test('onbekende drieletterige code blijft staan', () {
      expect(langFromSrtFile(File('/x/ep.swe.srt')), 'swe');
    });
    test('geen taalcode → en', () {
      expect(langFromSrtFile(File('/x/ep.srt')), 'en');
    });
  });

  group('episodeExcerpt', () {
    test('korte tekst ongewijzigd', () {
      expect(episodeExcerpt('abc', chunkSize: 10), 'abc');
    });
    test('lange tekst: begin, midden, einde', () {
      final text = List.generate(100, (i) => 'w$i').join(' ');
      final ex = episodeExcerpt(text, chunkSize: 20);
      expect(ex, startsWith(text.substring(0, 20)));
      expect(ex, endsWith(text.substring(text.length - 20)));
      expect(ex.split('\n...\n'), hasLength(3));
    });
  });

  group('looksEnglish / isWeakSummary', () {
    const english =
        'The detective and his partner were sure that they had the right '
        'man, but when the evidence came back from the lab it was clear '
        'that this was not what they thought.';
    const dutch =
        'De rechercheur en zijn partner waren er zeker van dat ze de juiste '
        'man hadden, maar toen het bewijs terugkwam was het duidelijk.';

    test('Engels wordt herkend, Nederlands niet', () {
      expect(looksEnglish(english), isTrue);
      expect(looksEnglish(dutch), isFalse);
      expect(looksEnglish(''), isFalse);
    });

    test('zwakke samenvatting: kort, zonder leestekens of niet-Engels', () {
      expect(isWeakSummary('Too short.'), isTrue);
      expect(isWeakSummary(english.replaceAll(RegExp(r'[.,]'), '')), isTrue);
      expect(isWeakSummary(dutch), isTrue);
      expect(isWeakSummary(english), isFalse);
    });
  });

  group('extractEntities', () {
    test('max 8 unieke namen in volgorde', () {
      const names = [
        'Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo', 'Foxtrot',
        'Golf', 'Hotel', 'India', 'Juliet', 'Kilo', 'Lima',
      ];
      final text = '${names.join(' and ')} and ${names.first} again.';
      final ents = extractEntities(text);
      expect(ents, hasLength(8));
      expect(ents.first, names.first);
      expect(ents.toSet(), hasLength(8));
    });
  });

  group('similarity', () {
    test('identiek → 1, disjunct → 0', () {
      expect(wordSetSimilarity('one two three', 'one two three'), 1.0);
      expect(wordSetSimilarity('one two', 'four five'), 0.0);
      expect(wordSetSimilarity('', 'abc'), 0.0);
    });
    test('textSimilarity is hoofdletterongevoelig', () {
      expect(textSimilarity('Hello World', 'hello world'), 1.0);
    });
    test('isNearDuplicateText vereist ook een lengteverhouding', () {
      const a = 'alpha beta gamma delta epsilon';
      expect(isNearDuplicateText(a, a.toUpperCase()), isTrue);
      expect(isNearDuplicateText(a, '$a $a $a'), isFalse);
      expect(isNearDuplicateText(a, ''), isFalse);
    });
  });
}
