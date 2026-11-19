import 'dart:async';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One question from the library waiting for the user.
///
/// Either a yes/no question ([options] is null) or a pick from [options].
class PromptRequest {
  final String question;
  final List<String>? options;

  /// Preselected option of a pick; null when skipping is the default.
  final int? defaultIndex;

  /// Default answer of a yes/no question.
  final bool defaultValue;

  /// The log lines leading up to the question — they say which file it is
  /// about, which the question itself usually does not.
  final List<String> context;

  final Completer<Object?> _answer = Completer<Object?>();

  PromptRequest._({
    required this.question,
    this.options,
    this.defaultIndex,
    this.defaultValue = false,
    this.context = const [],
  });

  bool get isConfirm => options == null;

  /// What the question resolves to when nobody answers it.
  Object? get _default => isConfirm ? defaultValue : defaultIndex;
}

/// Questions waiting for an answer, oldest first. `PromptHost` shows the
/// first one as a dialog and calls [resolve].
class PromptQueueNotifier extends Notifier<List<PromptRequest>> {
  // Mirrors `state`; Riverpod does not allow reading state while disposing.
  final List<PromptRequest> _pending = [];

  @override
  List<PromptRequest> build() {
    // Nobody is left to answer once the provider goes away: release every
    // waiting caller with its default instead of leaving it hanging.
    ref.onDispose(() {
      for (final r in _pending) {
        if (!r._answer.isCompleted) r._answer.complete(r._default);
      }
      _pending.clear();
    });
    return const [];
  }

  Future<Object?> _enqueue(PromptRequest request) {
    _pending.add(request);
    state = List.unmodifiable(_pending);
    return request._answer.future;
  }

  Future<bool> confirm(String question,
      {bool defaultValue = false, List<String> context = const []}) async {
    final answer = await _enqueue(PromptRequest._(
        question: question, defaultValue: defaultValue, context: context));
    return answer is bool ? answer : defaultValue;
  }

  Future<int?> choose(String question, List<String> options,
      {int? defaultIndex, List<String> context = const []}) async {
    if (options.isEmpty) return null;
    final answer = await _enqueue(PromptRequest._(
        question: question,
        options: options,
        defaultIndex: defaultIndex,
        context: context));
    return answer is int && answer >= 0 && answer < options.length
        ? answer
        : null;
  }

  /// Answers [request]: a bool for a yes/no question, an option index (or
  /// null for "skip") for a pick.
  void resolve(PromptRequest request, Object? answer) {
    if (!request._answer.isCompleted) request._answer.complete(answer);
    _pending.removeWhere((r) => identical(r, request));
    state = List.unmodifiable(_pending);
  }
}

final promptQueueProvider =
    NotifierProvider<PromptQueueNotifier, List<PromptRequest>>(
        PromptQueueNotifier.new);

/// A library [Prompter] that asks through [promptQueueProvider], i.e. with a
/// dialog. Only usable from the main isolate.
class DialogPrompter implements Prompter {
  final PromptQueueNotifier _queue;

  /// Supplies the recent log lines shown with each question.
  final List<String> Function() _context;

  DialogPrompter(this._queue, {List<String> Function()? context})
      : _context = context ?? (() => const []);

  @override
  Future<bool> confirm(String question, {bool defaultValue = false}) =>
      _queue.confirm(_clean(question),
          defaultValue: defaultValue, context: _context());

  @override
  Future<int?> choose(String question, List<String> options,
          {int? defaultIndex}) =>
      _queue.choose(_clean(question), options,
          defaultIndex: defaultIndex, context: _context());

  /// Free-text questions are not asked in the UI (the only ones the library
  /// has are the track-language fixes, which the title panel covers).
  @override
  Future<String> readLine(String prompt, {String defaultValue = ''}) async =>
      defaultValue;

  /// Library questions are written for a terminal: indented, and yes/no
  /// ones end in a `[y/N]` hint.
  static String _clean(String question) => question
      .replaceAll(RegExp(r'\s*\[[yYnN]/[yYnN]\]\s*$'), '')
      .trim();
}
