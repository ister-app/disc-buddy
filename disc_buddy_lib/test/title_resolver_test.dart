import 'dart:convert';

import 'package:disc_buddy/src/naming/llm_client.dart';
import 'package:disc_buddy/src/naming/naming_types.dart';
import 'package:disc_buddy/src/naming/title_resolver.dart';
import 'package:disc_buddy/src/naming/tmdb_client.dart';
import 'package:disc_buddy/src/utils/prompter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// LLM that must not be consulted: a hint-backed pick is deterministic.
class NoLlm extends LlmClient {
  NoLlm() : super(baseUrl: 'http://fake', apiKey: 'x', model: 'fake');
  @override
  Future<String?> chat(
    List<Map<String, String>> messages, {
    Duration timeout = const Duration(minutes: 5),
    int? maxTokens,
    List<String>? stop,
    double temperature = 0.1,
    bool jsonMode = false,
  }) async =>
      throw StateError('LLM consulted: ${messages.first['content']}');
}

TmdbClient tmdbWith({
  required List<Map<String, Object>> movies,
  required List<Map<String, Object>> tv,
}) =>
    TmdbClient(
      token: 't',
      httpClient: MockClient((req) async {
        final results = req.url.path.endsWith('/search/movie') ? movies : tv;
        return http.Response(jsonEncode({'results': results}), 200);
      }),
    );

void main() {
  test('titelhint zonder seizoen scoort de serie, niet de afleveringsgok', () async {
    final resolver = TitleResolver(
      tmdb: tmdbWith(
        movies: [
          {'id': 1, 'title': 'Hey Arnold! The Movie', 'release_date': '2002-06-28'},
          {'id': 2, 'title': 'Hey Arnold! The Jungle Movie', 'release_date': '2017-11-24'},
        ],
        tv: [
          {'id': 537, 'name': 'Hey Arnold!', 'first_air_date': '1996-10-07'},
        ],
      ),
      llm: NoLlm(),
      prompter: const NonInteractivePrompter(),
      log: (_, {isError = false}) {},
    );

    final pick = await resolver.resolve(
      discName: 's01e02',
      // The LLM recognised the episode, not the show.
      fp: const Fingerprint(summary: 'A school newspaper rivalry.', titleGuess: 'The Big Scoop'),
      titleHint: 'Hey Arnold!',
    );

    expect(pick, isNotNull);
    expect(pick!.type, 'series');
    expect(pick.id, 537);
  });
}
