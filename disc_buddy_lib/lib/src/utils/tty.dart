import 'dart:io';

/// Reads a line from /dev/tty (works even when stdin is used as a stream).
/// Restores echo + canonical mode via stty so characters are visible.
String ttyReadLine() {
  try { Process.runSync('stty', ['-F', '/dev/tty', 'echo', 'icanon']); } catch (_) {}
  final tty = File('/dev/tty').openSync();
  final bytes = <int>[];
  while (true) {
    final b = tty.readByteSync();
    if (b == -1 || b == 10) break;
    if (b != 13) bytes.add(b);
  }
  tty.closeSync();
  return String.fromCharCodes(bytes);
}

/// Writes [prompt] and reads a yes/no answer via /dev/tty.
/// Returns true for 'y' / 'j', false for anything else.
bool ttyConfirm(String prompt) {
  stdout.write(prompt);
  final answer = ttyReadLine().toLowerCase();
  return answer == 'j' || answer == 'y';
}
