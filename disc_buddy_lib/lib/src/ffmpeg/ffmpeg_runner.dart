import 'dart:async';
import 'dart:io';
import '../rippers/video_disc_ripper.dart' show LogCallback;

class FfmpegProgress {
  final Duration elapsed;
  final double speed;
  const FfmpegProgress(this.elapsed, this.speed);
}

typedef ProgressCallback = void Function(FfmpegProgress);

class FfmpegRunner {
  final String executable;
  final void Function(Process)? onProcessStarted;
  final LogCallback? onLog;

  const FfmpegRunner({this.executable = 'ffmpeg', this.onProcessStarted, this.onLog});

  /// Runs ffmpeg with the given arguments.
  ///
  /// [stdinData] — optional stream piped to ffmpeg's stdin (-i pipe:0).
  /// [timeout] — hard maximum run time as a safety net.
  /// [expectedDuration] — expected output duration; once ffmpeg's progress
  ///   reaches this, the process is gracefully stopped after 3 seconds.
  ///   This prevents libcdio from hanging after the last CD track.
  /// [onProgress] — callback for each progress line on stderr.
  /// [stderrCollect] — if provided, all non-progress stderr lines are appended.
  Future<int> run(
    List<String> args, {
    Stream<List<int>>? stdinData,
    Duration? timeout,
    Duration? expectedDuration,
    ProgressCallback? onProgress,
    List<String>? stderrCollect,
  }) async {
    final process = await Process.start(executable, args);
    onProcessStarted?.call(process);

    if (stdinData != null) {
      // Ignore broken-pipe errors when ffmpeg finishes early.
      stdinData.pipe(process.stdin).catchError((_) {});
    }

    Timer? killTimer;
    Timer? killSigkillTimer;
    if (timeout != null) {
      killTimer = Timer(timeout, () {
        process.kill(ProcessSignal.sigterm);
        killSigkillTimer = Timer(
            const Duration(seconds: 5), () => process.kill(ProcessSignal.sigkill));
      });
    }

    // Completion timer: started once elapsed >= expectedDuration
    Timer? completionTimer;
    Timer? completionSigkillTimer;

    final stderrDone = process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((chunk) {
      for (final line in chunk.split('\r')) {
        final progress = _parseProgress(line);
        if (progress != null) {
          onProgress?.call(progress);
          if (expectedDuration != null &&
              completionTimer == null &&
              progress.elapsed >= expectedDuration) {
            // All audio has been written; give ffmpeg 3 s to finalize
            completionTimer = Timer(const Duration(seconds: 3), () {
              process.kill(ProcessSignal.sigterm);
              completionSigkillTimer = Timer(const Duration(seconds: 5),
                  () => process.kill(ProcessSignal.sigkill));
            });
          }
        } else if (line.trim().isNotEmpty) {
          if (onLog != null) { onLog!(line, isError: true); } else { stderr.writeln(line); }
          stderrCollect?.add(line);
        }
      }
    }).asFuture<void>();

    final stdoutDone = process.stdout.drain<void>();

    final exitCode = await process.exitCode;
    // Wait for both pipes to be fully consumed before returning, otherwise
    // trailing stderr lines (and [stderrCollect] entries) can be dropped and a
    // full stdout pipe could stall the child. Errors here (e.g. broken pipe on
    // an early kill) are not fatal to the exit code.
    await Future.wait([stderrDone, stdoutDone]).catchError((_) => <void>[]);
    killTimer?.cancel();
    killSigkillTimer?.cancel();
    completionTimer?.cancel();
    completionSigkillTimer?.cancel();
    return exitCode;
  }

  static FfmpegProgress? _parseProgress(String line) {
    final timeMatch = RegExp(r'time=(\d+):(\d+):(\d+\.\d+)').firstMatch(line);
    if (timeMatch == null) return null;
    final h = int.parse(timeMatch.group(1)!);
    final m = int.parse(timeMatch.group(2)!);
    final s = double.parse(timeMatch.group(3)!);
    final elapsed = Duration(
      hours: h,
      minutes: m,
      seconds: s.truncate(),
      milliseconds: ((s % 1) * 1000).round(),
    );
    final speedMatch = RegExp(r'speed=\s*([\d.]+)x').firstMatch(line);
    final speed =
        speedMatch != null ? double.parse(speedMatch.group(1)!) : 0.0;
    return FfmpegProgress(elapsed, speed);
  }
}
