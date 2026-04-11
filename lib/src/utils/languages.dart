import 'dart:io';
import '../cli/menu.dart';

/// ISO 639-1 (2-letter) → ISO 639-2/B (3-letter bibliographic).
const iso639_1to2B = {
  'nl': 'dut', 'en': 'eng', 'fr': 'fre', 'de': 'ger', 'es': 'spa', 'it': 'ita',
  'pt': 'por', 'ru': 'rus', 'ja': 'jpn', 'zh': 'chi', 'ko': 'kor', 'sv': 'swe',
  'da': 'dan', 'no': 'nor', 'fi': 'fin', 'pl': 'pol', 'cs': 'cze', 'hu': 'hun',
  'ro': 'rum', 'sk': 'slo', 'hr': 'hrv', 'ar': 'ara', 'he': 'heb', 'tr': 'tur',
  'el': 'gre', 'uk': 'ukr', 'bg': 'bul', 'sr': 'srp', 'ca': 'cat', 'sq': 'alb',
  'iw': 'heb',
};

/// ISO 639-2/T (terminologic) → ISO 639-2/B (bibliographic).
const iso639_2Tto2B = {
  'nld': 'dut', 'deu': 'ger', 'fra': 'fre', 'zho': 'chi',
  'ces': 'cze', 'slk': 'slo', 'ron': 'rum', 'isl': 'ice',
  'msa': 'may', 'eus': 'baq', 'sqi': 'alb', 'hye': 'arm',
  'mkd': 'mac', 'mri': 'mao', 'mya': 'bur', 'fas': 'per',
};

/// Converts an ISO 639-1 (2-letter) code to ISO 639-2/B (3-letter).
String convertIso1to2(String raw) =>
    iso639_1to2B[raw.toLowerCase()] ?? raw.toLowerCase();

/// Converts an ISO 639-2/T code to ISO 639-2/B; returns unknown codes unchanged.
String convertIso2Tto2B(String code) {
  if (code.length != 3) return code;
  return iso639_2Tto2B[code.toLowerCase()] ?? code.toLowerCase();
}

/// Channel count → human-readable label, e.g. 6 → "5.1".
const channelLabels = {
  1: 'Mono', 2: 'Stereo', 3: '2.1', 4: '4.0',
  5: '5.0',  6: '5.1',   7: '6.1', 8: '7.1',
};

String channelLabel(int ch) => channelLabels[ch] ?? '${ch}ch';

/// Shows current languages and optionally prompts for manual correction.
///
/// [audioLabels]   — extra info per audio track, e.g. "AC3 5.1". Empty = no extra.
/// [audioCurrents] — current language codes per audio track.
/// [subCurrents]   — current language codes per subtitle track.
/// [force]         — use current languages directly without asking.
({List<String> audioLangs, List<String> subLangs}) askLanguages({
  required List<String> audioLabels,
  required List<String> audioCurrents,
  required List<String> subCurrents,
  required bool force,
}) {
  if (audioCurrents.isEmpty && subCurrents.isEmpty) {
    return (audioLangs: [], subLangs: []);
  }

  stdout.writeln('   Current languages:');
  for (var i = 0; i < audioCurrents.length; i++) {
    final extra = i < audioLabels.length ? audioLabels[i] : '';
    final e = extra.isNotEmpty ? ' ($extra)' : '';
    final lang = audioCurrents[i];
    stdout.writeln('     Audio ${i + 1}$e: ${lang.isNotEmpty ? lang : "?"}');
  }
  for (var i = 0; i < subCurrents.length; i++) {
    final lang = subCurrents[i];
    stdout.writeln('     Subtitle ${i + 1}: ${lang.isNotEmpty ? lang : "?"}');
  }

  if (force) {
    return (audioLangs: List.of(audioCurrents), subLangs: List.of(subCurrents));
  }

  final manual = Menu.confirm('   Set languages manually? [y/N] ');

  // Returns [current] unchanged if not in manual mode and current is non-empty.
  // Otherwise prompts the user; a space-only reply clears the language.
  String askLang(String current, String prompt) {
    if (!manual && current.isNotEmpty) return current;
    stdout.write(prompt);
    final input = Menu.readLine();
    if (input.isEmpty) return current;
    if (input.replaceAll(' ', '').isEmpty) return '';
    return input.replaceAll(' ', '');
  }

  return (
    audioLangs: [
      for (var i = 0; i < audioCurrents.length; i++) () {
        final extra = i < audioLabels.length ? audioLabels[i] : '';
        final e = extra.isNotEmpty ? ' ($extra)' : '';
        final h = audioCurrents[i].isNotEmpty ? ' [current: ${audioCurrents[i]}]' : '';
        return askLang(audioCurrents[i], '   Audio ${i + 1}$e language$h (space=empty): ');
      }(),
    ],
    subLangs: [
      for (var i = 0; i < subCurrents.length; i++) () {
        final h = subCurrents[i].isNotEmpty ? ' [current: ${subCurrents[i]}]' : '';
        return askLang(subCurrents[i], '   Subtitle ${i + 1} language$h (space=empty): ');
      }(),
    ],
  );
}
