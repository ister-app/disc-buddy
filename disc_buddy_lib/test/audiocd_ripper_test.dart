import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AudioCDRipper.cancel', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('audiocd_cancel_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    TrackInfo track(int nr) => TrackInfo(
          number: nr,
          title: 'Track $nr',
          artist: '',
          artistMbid: '',
          recordingMbid: '',
          startTime: (nr - 1) * 60.0,
          endTime: nr * 60.0,
        );

    test('stopt het lopende ffmpeg-proces en slaat de rest over', () async {
      // Stand-in for ffmpeg that hangs until killed. The device does not
      // exist, so the ripper takes the libcdio fallback path.
      final fake = File(p.join(tmp.path, 'ffmpeg'))
        ..writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
      Process.runSync('chmod', ['+x', fake.path]);

      final logs = <String>[];
      var started = 0;
      late AudioCDRipper ripper;
      ripper = AudioCDRipper(
        RipOptions(
          device: p.join(tmp.path, 'no-such-drive'),
          outputDir: tmp.path,
          ffmpeg: fake.path,
          force: true,
        ),
        onLog: (m, {isError = false}) => logs.add(m),
        onProgress: (_) {},
        onFfmpegProcess: (_) {
          started++;
          ripper.cancel();
        },
      );
      final meta = DiscMetadata(
          album: 'Album', artist: 'Artist', tracks: [track(1), track(2)]);

      final sw = Stopwatch()..start();
      await ripper.rip(meta, [1, 2]);

      expect(ripper.cancelled, isTrue);
      expect(started, 1, reason: 'track 2 must not start after a cancel');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect(logs, contains('Rip cancelled.'));
      expect(logs.where((l) => l.contains('Error ripping')), isEmpty);
      final leftovers = tmp
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.flac'));
      expect(leftovers, isEmpty, reason: 'the part file must be removed');
    });
  });
}
