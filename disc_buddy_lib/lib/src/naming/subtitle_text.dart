import 'dart:io';

// Pure text helpers for subtitle-based identification: SRT cleanup,
// excerpting, language heuristics and word-set similarity.

/// Strips a "Previously on …" recap section from raw SRT text.
///
/// Activates only when the first subtitle block contains "previously on".
/// Finds the first timestamp that follows a gap of more than [gapSeconds]
/// seconds and returns the SRT from that point. [onStripped] receives the
/// number of characters removed.
String stripRecap(
  String rawSrt, {
  int gapSeconds = 60,
  void Function(int cutChars)? onStripped,
}) {
  final firstBlock = RegExp(
    r'^\d+\r?\n[^\r\n]+\r?\n([^\r\n]+)',
    multiLine: true,
  ).firstMatch(rawSrt);
  if (firstBlock == null) return rawSrt;
  if (!firstBlock.group(1)!.toLowerCase().contains('previously on')) {
    return rawSrt;
  }

  final tsPattern = RegExp(r'(\d+):(\d+):(\d+),\d+ -->');
  int? prevSecs;
  for (final m in tsPattern.allMatches(rawSrt)) {
    final secs = int.parse(m.group(1)!) * 3600 +
        int.parse(m.group(2)!) * 60 +
        int.parse(m.group(3)!);
    if (prevSecs != null && secs - prevSecs > gapSeconds) {
      final before = rawSrt.substring(0, m.start);
      final blankIdx = before.lastIndexOf('\n\n');
      final cutPos = blankIdx >= 0 ? blankIdx + 2 : 0;
      if (cutPos > 0) {
        onStripped?.call(cutPos);
        return rawSrt.substring(cutPos);
      }
    }
    prevSecs = secs;
  }
  return rawSrt;
}

/// Drops SRT indices and timestamps, joining cue lines with spaces.
String stripSrtFormatting(String srt) {
  final buf = StringBuffer();
  for (final line in srt.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (RegExp(r'^\d+$').hasMatch(t)) continue;
    if (t.contains('-->')) continue;
    buf.write('$t ');
  }
  return buf.toString().trimRight();
}

/// ISO 639-1 language from a `name.<lang>.srt` file name; 'en' when absent.
String langFromSrtFile(File srt) {
  final name = srt.uri.pathSegments.last;
  final match = RegExp(r'\.([a-z]{2,3})\.srt$').firstMatch(name);
  if (match == null) return 'en';
  final code = match.group(1)!;
  const iso2 = {
    'eng': 'en',
    'nld': 'nl',
    'dut': 'nl',
    'fra': 'fr',
    'fre': 'fr',
    'deu': 'de',
    'ger': 'de',
    'spa': 'es',
    'ita': 'it',
    'por': 'pt',
    'rus': 'ru',
    'jpn': 'ja',
    'zho': 'zh',
    'chi': 'zh',
    'kor': 'ko',
  };
  return iso2[code] ?? code;
}

/// Three chunks: beginning, middle (50%), and end of episode.
/// Sampling the true end is critical — climax scenes are often the most
/// distinctive (character deaths, weddings, confrontations).
String episodeExcerpt(String text, {int chunkSize = 2500}) {
  if (text.length <= chunkSize * 3) return text;
  final half   = text.length ~/ 2;
  final endOff = text.length - chunkSize;
  return '${text.substring(0, chunkSize)}\n...\n'
      '${text.substring(half, half + chunkSize)}\n...\n'
      '${text.substring(endOff)}';
}

/// Builds an excerpt of sentences dense in recurring proper nouns —
/// character and place names are the strongest episode-identification
/// signal when a plain excerpt failed.
String entityDenseExcerpt(String text, {int maxChars = 8000}) {
  final counts = <String, int>{};
  for (final m in RegExp(r'\b[A-Z][a-z]{2,}\b').allMatches(text)) {
    final w = m.group(0)!;
    counts[w] = (counts[w] ?? 0) + 1;
  }
  final recurring = counts.entries
      .where((e) => e.value >= 3)
      .map((e) => e.key)
      .toSet();
  if (recurring.isEmpty) return episodeExcerpt(text);

  final buf = StringBuffer();
  for (final sentence in text.split(RegExp(r'(?<=[.!?])\s+'))) {
    if (buf.length >= maxChars) break;
    final hasEntity = RegExp(r'\b[A-Z][a-z]{2,}\b')
        .allMatches(sentence)
        .any((m) => recurring.contains(m.group(0)));
    if (hasEntity) buf.write('$sentence ');
  }
  final out = buf.toString().trim();
  return out.isEmpty ? episodeExcerpt(text) : out;
}

/// Returns true when [text] looks like English based on stopword frequency.
bool looksEnglish(String text) {
  const stopwords = {
    'the', 'and', 'you', 'that', 'was', 'for', 'are', 'with',
    'his', 'they', 'this', 'have', 'from', 'not', 'but', 'what',
    'all', 'were', 'when', 'your', 'she', 'him',
  };
  final sample = text.length > 800 ? text.substring(0, 800) : text;
  final words = sample
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.length >= 2)
      .toList();
  if (words.isEmpty) return false;
  final hits = words.where(stopwords.contains).length;
  // At least 8% of sample words should be English stopwords.
  return hits / words.length >= 0.08;
}

/// Returns true when [s] is too short, lacks punctuation, or is not English.
bool isWeakSummary(String s) {
  if (s.length < 80) return true;
  if (!RegExp(r'[.!?,;]').hasMatch(s)) return true;
  if (!looksEnglish(s)) return true;
  return false;
}

/// Extracts up to 8 unique capitalised names / phrases from [text].
List<String> extractEntities(String text) {
  final seen = <String>{};
  final entities = <String>[];
  for (final m in RegExp(r'\b[A-Z][a-z]{1,}(?:\s[A-Z][a-z]{1,})*\b')
      .allMatches(text)) {
    final word = m.group(0)!;
    if (seen.add(word)) entities.add(word);
    if (entities.length >= 8) break;
  }
  return entities;
}

/// Jaccard similarity of the sets of words (≥ 3 chars) in [a] and [b].
/// Case-sensitive; callers lower-case first when needed.
double wordSetSimilarity(String a, String b) {
  final sa = a.split(RegExp(r'\s+')).where((w) => w.length >= 3).toSet();
  final sb = b.split(RegExp(r'\s+')).where((w) => w.length >= 3).toSet();
  if (sa.isEmpty || sb.isEmpty) return 0.0;
  final inter = sa.intersection(sb).length;
  final union = sa.union(sb).length;
  return inter / union;
}

/// Jaccard word-set similarity between two subtitle texts (case-folded).
/// Unlike [isNearDuplicateText] there is no length-ratio gate, so an
/// extended cut still scores high against its broadcast version.
double textSimilarity(String a, String b) =>
    wordSetSimilarity(a.toLowerCase(), b.toLowerCase());

/// True when two subtitle texts are near-identical — the same episode
/// ripped from two discs. Compares length ratio plus Jaccard word-set
/// similarity, so capitalisation and small CC differences don't matter.
bool isNearDuplicateText(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  final ratio = a.length < b.length ? a.length / b.length : b.length / a.length;
  if (ratio < 0.8) return false;
  return wordSetSimilarity(a.toLowerCase(), b.toLowerCase()) >= 0.8;
}
