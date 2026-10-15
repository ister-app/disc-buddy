import 'dart:io';

/// Callback for log messages from the library.
/// [isError] is true for error/warning messages (stderr equivalent).
typedef LogCallback = void Function(String message, {bool isError});

/// Default sink used when no [LogCallback] was supplied: errors go to
/// stderr, everything else to stdout.
void stdioLog(String message, {bool isError = false}) {
  if (isError) {
    stderr.writeln(message);
  } else {
    stdout.writeln(message);
  }
}

/// Discards every message.
void silentLog(String message, {bool isError = false}) {}

/// Sends [message] to [onLog], falling back to [stdioLog] when it is null.
void emitLog(LogCallback? onLog, String message, {bool isError = false}) {
  (onLog ?? stdioLog)(message, isError: isError);
}
