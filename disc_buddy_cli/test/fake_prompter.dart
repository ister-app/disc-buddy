import 'package:disc_buddy/disc_buddy.dart';
import 'package:test/test.dart';

/// Plays back a scripted list of answers. `null` means "press Enter"
/// (default) for confirm/choose/readLine alike.
class FakePrompter implements Prompter {
  FakePrompter([List<Object?> answers = const []]) : answers = List.of(answers);
  final List<Object?> answers;
  final List<String> asked = [];

  Object? _next(String q) {
    asked.add(q);
    if (answers.isEmpty) fail('no scripted answer left for: $q');
    return answers.removeAt(0);
  }

  @override
  Future<bool> confirm(String question, {bool defaultValue = false}) async =>
      (_next(question) as bool?) ?? defaultValue;

  @override
  Future<int?> choose(String question, List<String> options,
          {int? defaultIndex}) async =>
      (_next(question) as int?) ?? defaultIndex;

  @override
  Future<String> readLine(String prompt, {String defaultValue = ''}) async =>
      (_next(prompt) as String?) ?? defaultValue;
}

/// Collects log lines; errors are prefixed with `[ERR] `.
class LogSink {
  final lines = <String>[];
  void call(String m, {bool isError = false}) =>
      lines.add(isError ? '[ERR] $m' : m);
  String get text => lines.join('\n');
}
