import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class LlmClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client _http;

  LlmClient({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? httpClient,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        _http = httpClient ?? http.Client();

  /// Appends `/v1` when the URL has no meaningful path (e.g. bare Ollama host).
  static String _normalizeBaseUrl(String url) {
    final trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final uri = Uri.parse(trimmed);
    if (uri.path.isEmpty || uri.path == '/') {
      return '$trimmed/v1';
    }
    return trimmed;
  }

  /// Sends a chat request and returns the assistant's reply, or null on error.
  /// [timeout] defaults to 5 minutes; pass a shorter value for quick lookups.
  /// [maxTokens] caps the generated response length (omit for server default).
  /// [stop] lists strings that end generation early (e.g. `["}", "\n\n"]`).
  /// [temperature] overrides the default 0.1; use 0.0 for deterministic output.
  /// [jsonMode] sets `response_format: {type: json_object}` (Ollama / OpenAI).
  Future<String?> chat(
    List<Map<String, String>> messages, {
    Duration timeout = const Duration(minutes: 5),
    int? maxTokens,
    List<String>? stop,
    double temperature = 0.1,
    bool jsonMode = false,
  }) async {
    try {
      final body = <String, dynamic>{
        'model': model,
        'messages': messages,
        'temperature': temperature,
      };
      if (maxTokens != null) body['max_tokens'] = maxTokens;
      if (stop != null && stop.isNotEmpty) body['stop'] = stop;
      if (jsonMode) body['response_format'] = {'type': 'json_object'};

      final response = await _http
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        stderr.writeln(
            '   LLM request failed (${response.statusCode}): ${response.body}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final choice = (json['choices'] as List?)?.firstOrNull;
      final content  = choice?['message']?['content'] as String?;
      final finish   = choice?['finish_reason'] as String?;
      if (content == null || content.trim().isEmpty) {
        final snippet = response.body.length > 400
            ? response.body.substring(0, 400)
            : response.body;
        stderr.writeln('   LLM: empty/null content '
            '(finish_reason=$finish). Response: $snippet');
      }
      return content;
    } catch (e) {
      stderr.writeln('   LLM error: $e');
      return null;
    }
  }

  void close() => _http.close();
}
