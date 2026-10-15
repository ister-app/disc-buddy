import 'dart:async';
import 'dart:io';
import '../utils/log.dart';

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
  /// [onStdinError] — receives an error raised while piping [stdinData]
  ///   (from the producer stream or the pipe itself). Such an error does not
  ///   fail the run by itself — ffmpeg just sees end-of-input — but it is
  ///   logged and reported so the caller can decide the output is incomplete.
  Future<int> run(
    List<String> args, {
    Stream<List<int>>? stdinData,
    Duration? timeout,
    Duration? expectedDuration,
    ProgressCallback? onProgress,
    List<String>? stderrCollect,
    void Function(Object error)? onStdinError,
  }) async {
    final process = await Process.start(executable, args);
    onProcessStarted?.call(process);

    Object? stdinError;
    Future<void>? stdinDone;
    if (stdinData != null) {
      // Broken-pipe errors when ffmpeg finishes early must not throw; capture
      // them (and producer errors) instead. The cast keeps pipe() happy when
      // the caller passes a Stream<Uint8List>: its pipe() demands a
      // StreamConsumer<Uint8List>, which process.stdin is not.
      stdinDone = stdinData
          .cast<List<int>>()
          .pipe(process.stdin)
          .catchError((Object e) { stdinError ??= e; });
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
      for (final line in chunk.split(_lineBreak)) {
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
          final (line: stripped, :isError) = classifyStderrLine(line);
          emitLog(onLog, stripped, isError: isError);
          stderrCollect?.add(stripped);
        }
      }
    }).asFuture<void>();

    final stdoutDone = process.stdout.drain<void>();

    final exitCode = await process.exitCode;
    // Wait for both pipes to be fully consumed before returning, otherwise
    // trailing stderr lines (and [stderrCollect] entries) can be dropped and a
    // full stdout pipe could stall the child. Errors here (e.g. broken pipe on
    // an early kill) are not fatal to the exit code.
    await Future.wait([
      stderrDone,
      stdoutDone,
      ?stdinDone,
    ]).catchError((Object e) { stdinError ??= e; return <void>[]; });
    killTimer?.cancel();
    killSigkillTimer?.cancel();
    completionTimer?.cancel();
    completionSigkillTimer?.cancel();
    if (stdinError != null) {
      final e = stdinError!;
      // EPIPE after ffmpeg already exited is routine; anything else matters.
      final routine = exitCode == 0 && e is SocketException;
      if (!routine) {
        emitLog(onLog, '   ffmpeg input error: $e', isError: true);
      }
      onStdinError?.call(e);
    }
    return exitCode;
  }

  static final _lineBreak = RegExp('[\r\n]');

  // Severity tag emitted when ffmpeg runs with `-loglevel repeat+level+...`.
  // It follows the optional context prefix: `[vist#0:1/... @ 0x...] [warning] msg`
  // or sits at line start: `[error] msg`.
  static final _levelTag =
      RegExp(r'^(\[[^\]]*\] )?\[(info|verbose|debug|warning|error|fatal|panic)\] ');

  /// Classifies an ffmpeg stderr line by its `[level]` tag (see [_levelTag])
  /// and strips the tag. Lines without a recognized tag — e.g. from an ffmpeg
  /// invocation without the `level` log flag — are treated as errors, matching
  /// the historical behavior of `-loglevel warning` where anything on stderr
  /// was warning-or-worse.
  static ({String line, bool isError}) classifyStderrLine(String line) {
    final m = _levelTag.firstMatch(line);
    if (m == null) return (line: line, isError: true);
    final level = m.group(2)!;
    final isError = level == 'error' || level == 'fatal' || level == 'panic';
    final context = m.group(1) ?? '';
    return (line: '$context${line.substring(m.end)}', isError: isError);
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
