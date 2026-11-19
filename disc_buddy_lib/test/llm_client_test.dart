import 'dart:convert';

import 'package:disc_buddy/src/naming/llm_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  LlmClient client(int status, List<int> calls, List<String> logs) => LlmClient(
        baseUrl: 'http://fake',
        apiKey: 'k',
        model: 'm',
        httpClient: MockClient((_) async {
          calls.add(status);
          return http.Response('{"error":{"message":"nope"}}', status);
        }),
        onLog: (m, {isError = false}) => logs.add(m),
      );

  test('402 maakt de client onbruikbaar: geen verdere verzoeken', () async {
    final calls = <int>[];
    final logs = <String>[];
    final llm = client(402, calls, logs);

    expect(await llm.chat([{'role': 'user', 'content': 'a'}]), isNull);
    expect(llm.unavailableReason, contains('no credit'));
    expect(await llm.chat([{'role': 'user', 'content': 'b'}]), isNull);
    expect(await llm.chat([{'role': 'user', 'content': 'c'}]), isNull);

    expect(calls, hasLength(1));
    expect(logs.where((l) => l.contains('LLM unavailable')), hasLength(1));
  });

  test('een tijdelijke fout (500) blijft opnieuw te proberen', () async {
    final calls = <int>[];
    final llm = client(500, calls, []);

    await llm.chat([{'role': 'user', 'content': 'a'}]);
    await llm.chat([{'role': 'user', 'content': 'b'}]);

    expect(llm.unavailableReason, isNull);
    expect(calls, hasLength(2));
  });

  test('reasoning_effort wordt alleen meegestuurd als het is ingesteld',
      () async {
    final bodies = <Map<String, dynamic>>[];
    LlmClient make(String? effort) => LlmClient(
          baseUrl: 'http://fake',
          apiKey: 'k',
          model: 'm',
          reasoningEffort: effort,
          httpClient: MockClient((req) async {
            bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'content': 'ok'},
                      'finish_reason': 'stop'
                    }
                  ]
                }),
                200);
          }),
        );

    expect(await make(null).chat([{'role': 'user', 'content': 'a'}]), 'ok');
    expect(await make('none').chat([{'role': 'user', 'content': 'a'}]), 'ok');
    expect(await make('  ').chat([{'role': 'user', 'content': 'a'}]), 'ok');

    expect(bodies[0].containsKey('reasoning_effort'), isFalse);
    expect(bodies[1]['reasoning_effort'], 'none');
    expect(bodies[2].containsKey('reasoning_effort'), isFalse);
  });
}
