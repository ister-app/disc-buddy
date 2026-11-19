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
  final out = StringBuffer();
  final err = StringBuffer();
  final outDone = process.stdout
      .transform(systemEncoding.decoder)
      .listen(out.write)
      .asFuture<void>();
  final errDone = process.stderr
      .transform(systemEncoding.decoder)
      .listen(err.write)
      .asFuture<void>();
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
  });
  try {
    final exitCode = await process.exitCode;
    if (timedOut) {
      // Do not wait for the pipes: a grandchild that inherited them (a shell
      // wrapper's command) can keep them open long after the kill.
      throw TimeoutException('$executable did not finish in time', timeout);
    }
    await Future.wait([outDone, errDone]);
    return ProcessResult(process.pid, exitCode, out.toString(), err.toString());
  } finally {
    timer.cancel();
  }
}
