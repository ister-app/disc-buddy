import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/drive_info.dart';
import '../device/drive_detector.dart';

/// Reads a line from /dev/tty (works even after stdin has been used as a stream).
/// Restores echo + canonical mode via stty so characters are visible.
String _ttyReadLine() {
  // Ensure the terminal is in canonical/echo mode regardless of what the
  // drive selection menu did with it.
  try { Process.runSync('stty', ['-F', '/dev/tty', 'echo', 'icanon']); } catch (_) {}

  final tty = File('/dev/tty').openSync();
  final bytes = <int>[];
  while (true) {
    final b = tty.readByteSync();
    if (b == -1 || b == 10) break; // EOF or newline
    if (b != 13) bytes.add(b);     // ignore CR
  }
  tty.closeSync();
  return String.fromCharCodes(bytes);
}

class Menu {
  /// Shows the drive selection menu with real-time disc-status updates.
  static Future<DriveInfo> selectDrive() async {
    var drives = await DriveDetector.detect();

    if (drives.isEmpty) {
      stderr.writeln('Error: no optical drives found.');
      exit(1);
    }

    if (drives.length == 1) return drives.first;

    _printDriveMenu(drives);
    stdout.write('Select drive (1-${drives.length}): ');

    var partial = '';
    var lastState = _driveState(drives);

    // Attempt raw mode for character-by-character input
    bool rawMode;
    try {
      stdin.echoMode = false;
      stdin.lineMode = false;
      rawMode = true;
    } catch (_) {
      rawMode = false;
    }

    if (!rawMode) {
      return _selectDriveTty(drives);
    }

    // Single stdin subscription, buffering characters in a queue
    final queue = <String>[];
    final stdinSub = stdin.listen(
      (bytes) => queue.add(String.fromCharCode(bytes.first)),
    );

    // udevadm monitor for immediate disc-status updates (no polling)
    Process? udevProcess;
    StreamSubscription<String>? udevSub;
    try {
      udevProcess = await Process.start(
        'udevadm', ['monitor', '--udev', '--subsystem-match=block'],
      );
    } catch (_) { /* not available, fall back to polling */ }

    bool refreshing = false;
    udevSub = udevProcess?.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((_) async {
      if (refreshing) return;
      refreshing = true;
      drives = await DriveDetector.detect();
      refreshing = false;
      final state = _driveState(drives);
      if (state != lastState) {
        lastState = state;
        _clearAndPrint(drives, partial);
      }
    });

    // Poll interval: short when udevadm is unavailable, otherwise 30 s safety net
    final pollInterval = udevProcess != null
        ? const Duration(seconds: 30)
        : const Duration(seconds: 2);

    try {
      while (true) {
        final deadline = DateTime.now().add(pollInterval);
        String? char;
        while (char == null && DateTime.now().isBefore(deadline)) {
          if (queue.isNotEmpty) {
            char = queue.removeAt(0);
          } else {
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }

        if (char == null) {
          // Periodic fallback poll (or 30 s safety net)
          if (!refreshing) {
            refreshing = true;
            drives = await DriveDetector.detect();
            refreshing = false;
            final state = _driveState(drives);
            if (state != lastState) {
              lastState = state;
              _clearAndPrint(drives, partial);
            }
          }
          continue;
        }

        final code = char.codeUnitAt(0);
        if (code == 10 || code == 13) {
          stdout.writeln('');
          final nr = int.tryParse(partial);
          if (nr != null && nr >= 1 && nr <= drives.length) {
            return drives[nr - 1];
          }
          stdout.write('Invalid choice. Select drive (1-${drives.length}): ');
          partial = '';
        } else if (code == 127 || code == 8) {
          if (partial.isNotEmpty) {
            partial = partial.substring(0, partial.length - 1);
            stdout.write('\b \b');
          }
        } else if (char.contains(RegExp(r'[0-9]'))) {
          partial += char;
          stdout.write(char);
        }
      }
    } finally {
      await stdinSub.cancel();
      await udevSub?.cancel();
      udevProcess?.kill();
      try {
        stdin.echoMode = true;
        stdin.lineMode = true;
      } catch (_) {}
    }
  }

  /// Prompts for which tracks to rip.
  /// Reads via /dev/tty so stdin-stream usage is not a problem.
  static List<int> selectTracks(int totalTracks) {
    stdout.writeln('');
    stdout.writeln('Enter tracks (comma- or space-separated),');
    stdout.writeln('or press Enter for all tracks:');
    final input = _ttyReadLine();
    if (input.trim().isEmpty) {
      stdout.writeln('→ All $totalTracks tracks will be ripped.');
      return List.generate(totalTracks, (i) => i + 1);
    }
    return input
        .split(RegExp(r'[,\s]+'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
  }

  /// Reads a line from /dev/tty (for arbitrary input).
  static String readLine() => _ttyReadLine();

  /// Reads a yes/no question via /dev/tty. Default is no.
  static bool confirm(String prompt) {
    stdout.write(prompt);
    final answer = _ttyReadLine().toLowerCase();
    return answer == 'j' || answer == 'y';
  }

  static DriveInfo _selectDriveTty(List<DriveInfo> drives) {
    while (true) {
      final input = _ttyReadLine();
      final nr = int.tryParse(input.trim());
      if (nr != null && nr >= 1 && nr <= drives.length) {
        return drives[nr - 1];
      }
      stdout.write('Invalid choice. Select drive (1-${drives.length}): ');
    }
  }

  static void _printDriveMenu(List<DriveInfo> drives) {
    stdout.write('\x1B[2J\x1B[H');
    stdout.writeln('Available drives:');
    for (var i = 0; i < drives.length; i++) {
      final d = drives[i];
      stdout.writeln(
        '  ${i + 1}: ${d.device.padRight(12)}  '
        '${d.displayModel.padRight(30)}  ${d.statusLabel}',
      );
    }
    stdout.writeln('');
  }

  static void _clearAndPrint(List<DriveInfo> drives, String partial) {
    _printDriveMenu(drives);
    stdout.write('Select drive (1-${drives.length}): $partial');
  }

  static String _driveState(List<DriveInfo> drives) =>
      drives.map((d) => '${d.device}:${d.statusLabel}').join('|');
}
