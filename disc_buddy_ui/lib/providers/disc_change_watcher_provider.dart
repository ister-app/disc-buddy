import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/rip_state.dart';
import 'disc_titles_provider.dart';
import 'drive_list_provider.dart';
import 'rip_state_provider.dart';

/// App-wide disc-swap watcher.
///
/// Compares each drive's (status, mediaId) across [realDrivesProvider]
/// emissions and invalidates the cached scan + idle rip state when the medium
/// changes — also on a direct disc-to-disc swap that never shows an empty
/// tray (which the status-transition listener in DriveDetailPanel misses).
///
/// Must be watched from the root widget so it is alive even when no detail
/// panel is mounted. Compares values, not event occurrence, so udev events
/// caused by a rip opening the device do not trigger invalidation. During an
/// active rip nothing is reset — the pre-rip fingerprint guard owns that case.
final discChangeWatcherProvider = Provider<void>((ref) {
  var last = <String, ({DiscStatus status, String mediaId})>{};

  ref.listen<AsyncValue<List<DriveInfo>>>(realDrivesProvider, (prev, next) {
    final drives = next.value;
    if (drives == null) return;

    for (final d in drives) {
      final p = last[d.device];
      if (p != null && (p.status != d.status || p.mediaId != d.mediaId)) {
        final rip = ref.read(ripStateProvider(d.device));
        final busy = rip is RipInProgress ||
            rip is RipAudioCdProgress ||
            rip is MkvProcessing ||
            rip is LoopWaiting;
        if (!busy) {
          ref.invalidate(discTitlesProvider(d.device));
          ref.read(ripStateProvider(d.device).notifier).reset();
        }
      }
    }
    last = {
      for (final d in drives) d.device: (status: d.status, mediaId: d.mediaId),
    };
  });
});
