import 'log.dart';
import 'prompter.dart';

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

/// Converts an ISO 639-2 (3-letter, B or T) code to ISO 639-1 (2-letter).
/// A 2-letter input is returned lower-cased. Returns null for `und`, empty
/// or unmapped codes.
String? convertIso2to1(String raw) {
  final code = raw.trim().toLowerCase();
  if (code.isEmpty || code == 'und') return null;
  if (code.length == 2) return code;
  final b = convertIso2Tto2B(code);
  for (final e in iso639_1to2B.entries) {
    if (e.value == b) return e.key;
  }
  return null;
}

/// Returns true when [trackLang] matches [filterLang], normalizing both to
/// ISO 639-2/B so that e.g. "nl" matches "dut" and "de" matches "ger".
bool langMatchesFilter(String trackLang, String filterLang) {
  final a = convertIso2Tto2B(convertIso1to2(trackLang));
  final b = convertIso2Tto2B(convertIso1to2(filterLang));
  return a == b;
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
/// [prompter]      — asks whether to correct languages manually and for each
///                   missing language. A [NonInteractivePrompter] keeps the
///                   current languages as they are.
Future<({List<String> audioLangs, List<String> subLangs})> askLanguages({
  required List<String> audioLabels,
  required List<String> audioCurrents,
  required List<String> subCurrents,
  required Prompter prompter,
  LogCallback? onLog,
}) async {
  if (audioCurrents.isEmpty && subCurrents.isEmpty) {
    return (audioLangs: <String>[], subLangs: <String>[]);
  }

  void emit(String msg) => emitLog(onLog, msg);

  emit('   Current languages:');
  for (var i = 0; i < audioCurrents.length; i++) {
    final extra = i < audioLabels.length ? audioLabels[i] : '';
    final e = extra.isNotEmpty ? ' ($extra)' : '';
    final lang = audioCurrents[i];
    emit('     Audio ${i + 1}$e: ${lang.isNotEmpty ? lang : "?"}');
  }
  for (var i = 0; i < subCurrents.length; i++) {
    final lang = subCurrents[i];
    emit('     Subtitle ${i + 1}: ${lang.isNotEmpty ? lang : "?"}');
  }

  final manual = await prompter.confirm('   Set languages manually? [y/N] ');

  // Returns [current] unchanged if not in manual mode and current is non-empty.
  // Otherwise prompts the user; a space-only reply clears the language.
  Future<String> askLang(String current, String prompt) async {
    if (!manual && current.isNotEmpty) return current;
    final input = await prompter.readLine(prompt, defaultValue: current);
    if (input.isEmpty) return current;
    if (input.replaceAll(' ', '').isEmpty) return '';
    return input.replaceAll(' ', '');
  }

  final audioLangs = <String>[];
  for (var i = 0; i < audioCurrents.length; i++) {
    final extra = i < audioLabels.length ? audioLabels[i] : '';
    final e = extra.isNotEmpty ? ' ($extra)' : '';
    final h = audioCurrents[i].isNotEmpty ? ' [current: ${audioCurrents[i]}]' : '';
    audioLangs.add(await askLang(
        audioCurrents[i], '   Audio ${i + 1}$e language$h (space=empty): '));
  }
  final subLangs = <String>[];
  for (var i = 0; i < subCurrents.length; i++) {
    final h = subCurrents[i].isNotEmpty ? ' [current: ${subCurrents[i]}]' : '';
    subLangs.add(await askLang(
        subCurrents[i], '   Subtitle ${i + 1} language$h (space=remove track): '));
  }
  return (audioLangs: audioLangs, subLangs: subLangs);
}
