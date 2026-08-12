import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skeletonizer/skeletonizer.dart';
import '../models/disc_content.dart';
import '../models/rip_state.dart';
import '../providers/disc_titles_provider.dart';
import '../providers/drive_list_provider.dart';
import '../providers/rip_state_provider.dart';
import 'audio_cd_panel.dart';
import 'dir_panel.dart';
import 'mkv_panel.dart';
import 'rip_progress_panel.dart';
import 'title_selection_panel.dart';

bool _isNoDisc(DiscStatus s) =>
    s == DiscStatus.noDisc ||
    s == DiscStatus.ejected ||
    s == DiscStatus.unreachable;
bool _isDiscReady(DiscStatus s) =>
    s == DiscStatus.audioCD || s == DiscStatus.dataDisc || s == DiscStatus.unknown;

class DriveDetailPanel extends ConsumerWidget {
  final DriveEntry entry;
  const DriveDetailPanel({super.key, required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // On disc swap: flush cached titles and reset rip state so the new disc starts clean.
    ref.listen<DriveEntry?>(selectedDriveEntryProvider, (prev, next) {
      if (prev is RealDriveEntry && next is RealDriveEntry && prev.id == next.id) {
        final wasReady = _isDiscReady(prev.info.status);
        final nowReady = _isDiscReady(next.info.status);
        final wasNoDisc = _isNoDisc(prev.info.status);
        final nowNoDisc = _isNoDisc(next.info.status);

        // Disc removed: clear stale cached titles and reset title-selection UI (skip in loop mode).
        if (!wasNoDisc && nowNoDisc) {
          ref.invalidate(discTitlesProvider(next.id));
          final rip = ref.read(ripStateProvider(next.id));
          if (rip is! RipInProgress && rip is! RipAudioCdProgress &&
              rip is! MkvProcessing && rip is! LoopWaiting) {
            ref.read(ripStateProvider(next.id).notifier).reset();
          }
        }

        // Disc became readable: re-scan titles.
        if (!wasReady && nowReady) {
          ref.invalidate(discTitlesProvider(next.id));
          final rip = ref.read(ripStateProvider(next.id));
          if (rip is! RipInProgress && rip is! RipAudioCdProgress &&
              rip is! MkvProcessing && rip is! LoopWaiting) {
            ref.read(ripStateProvider(next.id).notifier).reset();
          }
        }
      }
    });

    // Disc-swap guard tripped: tell the user and rescan the current disc.
    ref.listen<RipState>(ripStateProvider(entry.id), (prev, next) async {
      if (next is! RipDiscMismatch || prev is RipDiscMismatch) return;
      if (!ref.read(loopEnabledProvider(entry.id))) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Disc changed'),
            content: const Text(
                'The disc in the drive is not the disc that was scanned, '
                'so the rip was not started. The drive will be rescanned.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Rescan'),
              ),
            ],
          ),
        );
      }
      ref.invalidate(discTitlesProvider(entry.id));
      ref.read(ripStateProvider(entry.id).notifier).reset();
    });

    // In loop mode: auto-start rip when a new disc is scanned.
    ref.listen<AsyncValue<DiscContent?>>(discTitlesProvider(entry.id), (prev, next) {
      final rip = ref.read(ripStateProvider(entry.id));
      if (rip is! LoopWaiting) return;
      switch (next) {
        case AsyncData(:final value):
          if (value is VideoDiscContent) {
            final selected = value.titles
                .where((t) => value.suggestion.contains(t.displayKey))
                .toList();
            ref.read(ripStateProvider(entry.id).notifier)
                .startRipDirect(value.discTitle, selected,
                    fingerprint: value.fingerprint);
          } else if (value is AudioCdContent) {
            final tracks =
                List.generate(value.metadata.tracks.length, (i) => i + 1);
            ref.read(ripStateProvider(entry.id).notifier)
                .startAudioCdRip(value.metadata, tracks,
                    scanFingerprint: value.fingerprint);
          }
        default:
          break;
      }
    });

    final ripState = ref.watch(ripStateProvider(entry.id));

    // Show rip flow states regardless of disc content.
    if (ripState is RipInProgress ||
        ripState is RipAudioCdProgress ||
        ripState is MkvProcessing) {
      return RipProgressPanel(devicePath: entry.id, ripState: ripState);
    }
    if (ripState is RipCompleted) {
      return _CompletedPanel(devicePath: entry.id, state: ripState, entry: entry);
    }
    if (ripState is RipError) {
      return _ErrorPanel(message: ripState.message, devicePath: entry.id);
    }
    if (ripState is LoopWaiting) {
      return _LoopWaitingPanel(devicePath: entry.id, state: ripState);
    }

    // No active rip: show disc content.
    return _DiscContentView(entry: entry, ripState: ripState);
  }
}

class _DiscContentView extends ConsumerWidget {
  final DriveEntry entry;
  final RipState ripState;
  const _DiscContentView({required this.entry, required this.ripState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // For real drives: check if a disc is present.
    if (entry case RealDriveEntry(:final info)) {
      // Never start a scan on a drive that is empty or off the bus.
      if (_isNoDisc(info.status)) {
        return _NoDiscPlaceholder(status: info.statusLabel);
      }
      if (info.status == DiscStatus.loading) {
        return _SkeletonDetail();
      }
    }

    final titlesAsync = ref.watch(discTitlesProvider(entry.id));
    return titlesAsync.when(
      loading: () => _SkeletonDetail(),
      error: (e, _) => _ErrorPanel(message: e.toString(), devicePath: entry.id),
      data: (content) {
        if (content == null || content is EmptyDisc) {
          return _NoDiscPlaceholder(status: 'No readable disc');
        }
        return switch (content) {
          AudioCdContent(:final metadata) => AudioCdPanel(
            entry: entry,
            metadata: metadata,
            fingerprint: content.fingerprint,
          ),
          VideoDiscContent() => TitleSelectionPanel(
            entry: entry,
            content: content,
            ripState: ripState,
          ),
          MkvContent() => MkvPanel(entry: entry, content: content),
          DirContent() => DirPanel(entry: entry, content: content),
          EmptyDisc() => _NoDiscPlaceholder(status: 'No readable disc'),
        };
      },
    );
  }
}

class _NoDiscPlaceholder extends StatelessWidget {
  final String status;
  const _NoDiscPlaceholder({required this.status});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.no_photography_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(status, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _SkeletonDetail extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DISC_TITLE_LOADING', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Titles found: 6'),
            const SizedBox(height: 16),
            ...List.generate(5, (i) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: CheckboxListTile(
                value: i < 4,
                onChanged: null,
                title: Text('${i + 1}: 00:22:0${i + 1}  4 audio  19 sub  5 ch'),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            )),
          ],
        ),
      ),
    );
  }
}

class _CompletedPanel extends ConsumerWidget {
  final String devicePath;
  final RipCompleted state;
  final DriveEntry entry;
  const _CompletedPanel({required this.devicePath, required this.state, required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 72,
            color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('Rip completed!', style: Theme.of(context).textTheme.headlineSmall),
          if (state.outputFiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...state.outputFiles.map((f) => Text(f,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            )),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Rip another'),
                onPressed: () => ref.read(ripStateProvider(devicePath).notifier).reset(),
              ),
              if (entry case RealDriveEntry(:final info)) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.eject_outlined),
                  label: const Text('Eject'),
                  onPressed: () async {
                    // Capture the notifier before the await — the panel may be
                    // rebuilt/replaced while `eject` runs (the drive removal it
                    // triggers swaps the panel), making `ref` unsafe afterwards.
                    final notifier =
                        ref.read(ripStateProvider(devicePath).notifier);
                    // The container outlives this panel, unlike `ref`.
                    final container = ProviderScope.containerOf(context);
                    await Process.run('eject', [info.device]);
                    container.invalidate(discTitlesProvider(devicePath));
                    notifier.reset();
                  },
                ),
              ],
              if (state.log.isNotEmpty) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('View log'),
                  onPressed: () => _showLogDialog(context, state.log),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

void _showLogDialog(BuildContext context, List<String> log) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rip log'),
      content: SizedBox(
        width: 700,
        height: 500,
        child: LogView(log: log),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _ErrorPanel extends ConsumerWidget {
  final String message;
  final String devicePath;
  const _ErrorPanel({required this.message, required this.devicePath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 16),
          Text('Error', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => ref.read(ripStateProvider(devicePath).notifier).reset(),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _LoopWaitingPanel extends ConsumerWidget {
  final String devicePath;
  final LoopWaiting state;
  const _LoopWaitingPanel({required this.devicePath, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.album_outlined, size: 72,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('Waiting for next disc…',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Insert the next disc to continue automatically.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center),
          if (state.lastOutputFiles.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...state.lastOutputFiles.map((f) => Text(f,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            )),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop loop'),
                onPressed: () =>
                    ref.read(ripStateProvider(devicePath).notifier).stopLoop(),
              ),
              if (state.log.isNotEmpty) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('View log'),
                  onPressed: () => _showLogDialog(context, state.log),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
