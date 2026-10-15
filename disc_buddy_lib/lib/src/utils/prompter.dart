import 'dart:io';

import 'log.dart';
import 'tty.dart';

/// Asks the user questions on behalf of the library.
///
/// The library never touches `/dev/tty` itself: rippers and the auto-namer
/// receive a [Prompter] and fall back to [NonInteractivePrompter] (which
/// answers every question with its default) when none is given or when
/// `force` is set. The CLI passes a [TtyPrompter]; a GUI can implement its
/// own with dialogs.
abstract interface class Prompter {
  /// Yes/no question. Returns [defaultValue] when the user just presses
  /// Enter or when the prompter is non-interactive.
  Future<bool> confirm(String question, {bool defaultValue = false});

  /// Lets the user pick one of [options]. Returns the chosen index, or
  /// [defaultIndex] on Enter, or null when the user skipped (or when
  /// non-interactive and no default was given).
  Future<int?> choose(String question, List<String> options, {int? defaultIndex});

  /// Free-text input. Returns [defaultValue] on an empty answer.
  Future<String> readLine(String prompt, {String defaultValue = ''});
}

/// Answers every question with its default without asking anyone.
class NonInteractivePrompter implements Prompter {
  const NonInteractivePrompter();

  @override
  Future<bool> confirm(String question, {bool defaultValue = false}) async =>
      defaultValue;

  @override
  Future<int?> choose(String question, List<String> options,
          {int? defaultIndex}) async =>
      defaultIndex != null && defaultIndex >= 0 && defaultIndex < options.length
          ? defaultIndex
          : null;

  @override
  Future<String> readLine(String prompt, {String defaultValue = ''}) async =>
      defaultValue;
}

/// Prompts on the controlling terminal via `/dev/tty`.
///
/// Question text is written through [onLog] (stdout when null) so it ends up
/// in the same place as the rest of the CLI output.
class TtyPrompter implements Prompter {
  const TtyPrompter({this.onLog});

  final LogCallback? onLog;

  void _emit(String msg) => emitLog(onLog, msg);

  @override
  Future<bool> confirm(String question, {bool defaultValue = false}) async {
    stdout.write(question);
    final answer = ttyReadLine().trim().toLowerCase();
    if (answer.isEmpty) return defaultValue;
    return answer == 'y' || answer == 'yes' || answer == 'j' || answer == 'ja';
  }

  @override
  Future<int?> choose(String question, List<String> options,
      {int? defaultIndex}) async {
    if (options.isEmpty) return null;
    _emit(question);
    for (var i = 0; i < options.length; i++) {
      _emit('     ${i + 1}. ${options[i]}');
    }
    final hint = defaultIndex != null
        ? 'Enter = ${defaultIndex + 1}, 0 = skip'
        : 'Enter = skip';
    stdout.write('   Pick 1-${options.length} ($hint): ');
    final input = ttyReadLine().trim();
    if (input.isEmpty) return defaultIndex;
    final n = int.tryParse(input);
    if (n == null || n < 1 || n > options.length) {
      if (n != 0) _emit('   Invalid choice — skipping.');
      return null;
    }
    return n - 1;
  }

  @override
  Future<String> readLine(String prompt, {String defaultValue = ''}) async {
    stdout.write(prompt);
    final input = ttyReadLine();
    return input.isEmpty ? defaultValue : input;
  }
}
