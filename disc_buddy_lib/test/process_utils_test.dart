import 'dart:async';
import 'dart:io';

import 'package:disc_buddy/src/utils/process_utils.dart';
import 'package:test/test.dart';

void main() {
  test('runWithTimeout geeft exitcode en uitvoer terug', () async {
    final r = await runWithTimeout('sh', ['-c', 'echo out; echo err >&2; exit 3'],
        timeout: const Duration(seconds: 10));
    expect(r.exitCode, 3);
    expect(r.stdout, 'out\n');
    expect(r.stderr, 'err\n');
  });

  test('ongeldige UTF-8 in de uitvoer en een proces dat stdin leest', () async {
    final r = await runWithTimeout(
        'sh', ['-c', r"printf 'a\377b' >&2; cat; echo done"],
        timeout: const Duration(seconds: 10));
    expect(r.exitCode, 0);
    expect(r.stdout, 'done\n'); // cat saw end-of-input instead of hanging
    expect(r.stderr, startsWith('a'));
    expect(r.stderr, endsWith('b'));
  });

  test('runWithTimeout beëindigt het proces bij een timeout', () async {
    final tmp = Directory.systemTemp.createTempSync('run_timeout_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final marker = File('${tmp.path}/still-running');

    final sw = Stopwatch()..start();
    await expectLater(
      // The shell's `sleep` child inherits the pipes and outlives the kill:
      // the timeout must not wait for it.
      runWithTimeout('sh', ['-c', 'sleep 2; touch "${marker.path}"'],
          timeout: const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));

    // Had the shell survived, it would create the marker after its sleep.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(marker.existsSync(), isFalse);
  });
}
