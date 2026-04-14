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
  Future<String?> chat(
    List<Map<String, String>> messages, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    try {
      final response = await _http
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'messages': messages,
              'temperature': 0.1,
            }),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        stderr.writeln(
            '   LLM request failed (${response.statusCode}): ${response.body}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final content = (json['choices'] as List?)
          ?.firstOrNull?['message']?['content'] as String?;
      return content;
    } catch (e) {
      stderr.writeln('   LLM error: $e');
      return null;
    }
  }

  void close() => _http.close();
}
