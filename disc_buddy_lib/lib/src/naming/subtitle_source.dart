import 'dart:io';

import '../audio/transcriber.dart';
import '../subtitles/subtitle_extractor.dart';
import 'llm_client.dart';
import 'llm_json.dart';
import 'naming_prompts.dart';
import 'naming_types.dart';
import 'subtitle_text.dart';

/// Step 1 and 2 of auto-naming: obtain subtitle text for a file (sidecar
/// SRT, embedded track, or whisper transcript) and condense it into a
/// [Fingerprint] with one LLM call.
class SubtitleSource {
  SubtitleSource({
    required this.extractor,
    this.transcriber,
    required this.llm,
    required this.log,
  });

  static const int summaryMaxChars = 20000;

  final SubtitleExtractor extractor;
  /// Optional whisper.cpp fallback for titles without any subtitle track.
  final Transcriber? transcriber;
  final LlmClient llm;
  final NamingLog log;

  void _onRecapStripped(int cutPos) =>
      log('   Subtitle: stripped "Previously on" recap ($cutPos chars).');

  Future<SubtitleText?> load(File mkvFile, List<File> existingSrts) async {
    if (existingSrts.isNotEmpty) {
      final en = existingSrts.firstWhere(
        (f) => langFromSrtFile(f) == 'en',
        orElse: () => existingSrts.first,
      );
      try {
        final raw = await en.readAsString();
        final text = stripSrtFormatting(
            stripRecap(raw, onStripped: _onRecapStripped));
        if (text.trim().isNotEmpty) {
          return (text: text, language: langFromSrtFile(en));
        }
      } catch (_) {}
    }

    log('   Extracting subtitle for identification...');
    final result = await extractor.extractFirstSubtitleText(
      mkvFile,
      maxChars: 500000,
    );
    if (result == null || result.text.trim().isEmpty) {
      if (transcriber != null) {
        log('   No subtitle track — transcribing audio with whisper...');
        final t = await transcriber!.transcribe(mkvFile);
        if (t != null && t.text.trim().isNotEmpty) {
          return (text: t.text, language: t.language);
        }
      }
      log('   AutoNamer[step 1]: no subtitle track'
          '${transcriber != null ? ' and no usable transcript' : ''}'
          ' — skipping.', isError: true);
      return null;
    }
    return (
      text: stripSrtFormatting(
          stripRecap(result.text, onStripped: _onRecapStripped)),
      language: result.language,
    );
  }

  /// Summarises [fullText] into a [Fingerprint]. The LLM occasionally
  /// answers `{}` (its "failure" form) for a perfectly good subtitle; at
  /// temperature 0 the same excerpt fails the same way again, so the retry
  /// sends a different, name-dense excerpt instead.
  Future<Fingerprint> extractSummary(String fullText) async {
    if (fullText.isEmpty) return Fingerprint.empty;
    // Sample from beginning, middle and end so climax scenes are included.
    var fp = await _summariseOnce(
      episodeExcerpt(fullText, chunkSize: summaryMaxChars ~/ 3),
    );
    if (fp.isEmpty) {
      log('   Summary came back empty — retrying with a name-dense excerpt.');
      fp = await _summariseOnce(
        entityDenseExcerpt(fullText, maxChars: summaryMaxChars),
      );
    }
    return fp;
  }

  Future<Fingerprint> _summariseOnce(String excerpt) async {
    log('   Summarising subtitle (${excerpt.length} chars)...');
    final raw = await llm.chat(
      [
        {'role': 'system', 'content': summarySystemPrompt},
        {'role': 'user', 'content': 'Subtitle:\n$excerpt'},
      ],
      timeout: const Duration(minutes: 5),
      maxTokens: 8000,
      temperature: 0.0,
    );

    if (raw == null || raw.trim().isEmpty) {
      log('   Summary: no response from LLM.', isError: true);
      return Fingerprint.empty;
    }

    final parsed = parseJsonWithMode(raw);
    if (parsed == null) {
      log('   Summary: JSON parse failed. Raw: $raw', isError: true);
      return Fingerprint.empty;
    }

    final obj = parsed.obj;
    return Fingerprint(
      summary: (obj['summary'] as String? ?? '').trim(),
      titleGuess: (obj['titleGuess'] as String? ?? '').trim(),
    );
  }

  void logFingerprint(Fingerprint fp) {
    if (fp.isEmpty) {
      log('   Fingerprint: (empty — LLM summary failed)', isError: true);
      return;
    }
    log('   Fingerprint:');
    if (fp.summary.isNotEmpty) log('     summary:    ${fp.summary}');
    if (fp.titleGuess.isNotEmpty) log('     titleGuess: ${fp.titleGuess}');
  }
}
