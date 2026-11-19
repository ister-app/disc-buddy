import 'dart:async';
import 'dart:io';

/// Like `Process.run(...).timeout(...)`, but the child does not outlive the
/// timeout: it is killed before the [TimeoutException] is thrown.
///
/// `Future.timeout` on `Process.run` only stops waiting — ffmpeg, whisper or
/// an OCR tool would keep running (and keep the CPU busy for the next step)
/// after the caller has given up on it.
Future<ProcessResult> runWithTimeout(
  String executable,
  List<String> arguments, {
  required Duration timeout,
}) async {
  final process = await Process.start(executable, arguments);
  final stdoutText = process.stdout.transform(systemEncoding.decoder).join();
  final stderrText = process.stderr.transform(systemEncoding.decoder).join();
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
  });
  try {
    final exitCode = await process.exitCode;
    final out = await stdoutText;
    final err = await stderrText;
    if (timedOut) {
      throw TimeoutException('$executable did not finish in time', timeout);
    }
    return ProcessResult(process.pid, exitCode, out, err);
  } finally {
    timer.cancel();
  }
}
