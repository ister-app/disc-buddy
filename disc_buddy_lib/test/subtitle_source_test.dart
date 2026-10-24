import 'package:disc_buddy/src/naming/llm_client.dart';
import 'package:disc_buddy/src/naming/subtitle_source.dart';
import 'package:disc_buddy/src/subtitles/subtitle_extractor.dart';
import 'package:test/test.dart';

class ScriptedLlm extends LlmClient {
  ScriptedLlm(this.answers)
      : super(baseUrl: 'http://fake', apiKey: 'x', model: 'fake');
  final List<String?> answers;
  int calls = 0;

  @override
  Future<String?> chat(
    List<Map<String, String>> messages, {
    Duration timeout = const Duration(minutes: 5),
    int? maxTokens,
    List<String>? stop,
    double temperature = 0.1,
    bool jsonMode = false,
  }) async {
    calls++;
    return answers.removeAt(0);
  }
}

SubtitleSource source(ScriptedLlm llm, List<String> logs) => SubtitleSource(
      extractor: SubtitleExtractor(
        ffmpeg: 'ffmpeg',
        ffprobe: 'ffprobe',
        mkvextract: 'mkvextract',
        subtileOcr: 'subtile-ocr',
      ),
      llm: llm,
      log: (m, {bool isError = false}) => logs.add(m),
    );

void main() {
  group('SubtitleSource.extractSummary', () {
    const good = '{"summary":"George proposes.","titleGuess":"Seinfeld"}';

    test('retries once when the LLM answers {}', () async {
      final llm = ScriptedLlm(['{}', good]);
      final logs = <String>[];
      final fp = await source(llm, logs).extractSummary('some subtitle text');
      expect(fp.summary, 'George proposes.');
      expect(llm.calls, 2);
      expect(logs, anyElement(contains('retrying with a name-dense excerpt')));
    });

    test('gives up after the second empty answer', () async {
      final llm = ScriptedLlm(['{}', null]);
      final fp = await source(llm, <String>[]).extractSummary('text');
      expect(fp.isEmpty, isTrue);
      expect(llm.calls, 2);
    });

    test('does not retry a good answer', () async {
      final llm = ScriptedLlm([good]);
      await source(llm, <String>[]).extractSummary('text');
      expect(llm.calls, 1);
    });
  });
}
