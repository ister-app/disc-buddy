import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/disc_content.dart';
import '../providers/drive_list_provider.dart';
import '../providers/rip_state_provider.dart';
import '../models/rip_state.dart';

class DriveListTile extends ConsumerWidget {
  final DriveEntry entry;
  final bool isSelected;
  final VoidCallback onTap;

  const DriveListTile({
    super.key,
    required this.entry,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ripState = ref.watch(ripStateProvider(entry.id));
    final isRipping = ripState is RipInProgress || ripState is RipAudioCdProgress;

    Widget trailing;
    if (isRipping) {
      trailing = Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: ripState is RipInProgress ? ripState.progressFraction : null,
          ),
        ),
      );
    } else if (_hasDisc(entry)) {
      trailing = IconButton(
        icon: const Icon(Icons.eject_outlined, size: 20),
        tooltip: 'Eject',
        onPressed: () => _eject(entry, ref),
      );
    } else {
      trailing = const SizedBox(width: 48);
    }

    return ListTile(
      selected: isSelected,
      leading: _leadingIcon(entry),
      title: Text(
        entry.displayName,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _subtitle(entry),
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _leadingIcon(DriveEntry entry) => switch (entry) {
    RealDriveEntry(:final info) => Icon(switch (info.status) {
      DiscStatus.audioCD => Icons.album,
      DiscStatus.dataDisc => Icons.disc_full,
      DiscStatus.loading => Icons.more_horiz,
      _ => Icons.album_outlined,
    }),
    VirtualFileEntry(:final entry) => Icon(switch (entry) {
      IsoEntry() => Icons.storage_outlined,
      MkvEntry() => Icons.movie_outlined,
      DirEntry() => Icons.folder_outlined,
    }),
  };

  String _subtitle(DriveEntry entry) => switch (entry) {
    RealDriveEntry(:final info) => '${info.device} — ${info.statusLabel}',
    VirtualFileEntry(:final entry) => switch (entry) {
      IsoEntry(:final path) => path,
      MkvEntry(:final path) => path,
      DirEntry(:final path) => path,
    },
  };

  bool _hasDisc(DriveEntry entry) => switch (entry) {
    RealDriveEntry(:final info) =>
      info.status == DiscStatus.audioCD || info.status == DiscStatus.dataDisc,
    VirtualFileEntry() => true,
  };

  Future<void> _eject(DriveEntry entry, WidgetRef ref) async {
    if (entry is RealDriveEntry) {
      await Process.run('eject', [entry.info.device]);
    } else if (entry is VirtualFileEntry) {
      ref.read(virtualEntriesProvider.notifier).remove(entry.entry.toString());
    }
  }
}
