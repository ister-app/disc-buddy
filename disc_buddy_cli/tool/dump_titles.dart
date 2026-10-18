import 'package:disc_buddy/disc_buddy.dart';

String fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return '${h}h${m.toString().padLeft(2,'0')}m${s.toString().padLeft(2,'0')}s';
}

Future<void> main(List<String> args) async {
  for (final dev in args) {
    final r = DVDRipper(RipOptions(device: dev, outputDir: '/tmp', force: true), onLog: (_, {isError = false}) {});
    final res = await r.loadTitles();
    if (res == null) { print('$dev: scan failed'); continue; }
    print('=== $dev  ${res.discTitle}  (${res.titles.length} titles)');
    final sel = autoSelectDvd(res.titles).toSet();
    final dedup = deduplicateDvdTitles(res.titles).toSet();
    for (final t in res.titles) {
      final mark = sel.contains(t) ? '*' : (dedup.contains(t) ? ' ' : 'x');
      final dens = t.duration.inSeconds > 0 ? (t.totalSectors / t.duration.inSeconds).toStringAsFixed(0) : '-';
      print('$mark VTS${t.vtsNumber.toString().padLeft(2,'0')} pgc${t.pgcIndex} ${fmt(t.duration).padLeft(10)} a=${t.audioTracks.length} s=${t.subtitleTracks.length} ch=${t.chapters.length} cells=${t.cells.length} sect=${t.totalSectors} dens=$dens  cells=${t.cells.map((c) => '${c.first}-${c.last}').join(',')}');
    }
  }
}
