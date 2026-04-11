import 'dart:io';
import '../ffmpeg/ffmpeg_runner.dart';

/// Writes a progress line "\r   HH:MM:SS  1.2x   " to stdout.
void logProgress(FfmpegProgress prog) {
  final t  = prog.elapsed;
  final ts = '${t.inHours.toString().padLeft(2, '0')}:'
      '${(t.inMinutes % 60).toString().padLeft(2, '0')}:'
      '${(t.inSeconds % 60).toString().padLeft(2, '0')}';
  stdout.write('\r   $ts  ${prog.speed.toStringAsFixed(1)}x   ');
}
