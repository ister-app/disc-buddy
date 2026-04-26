import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skeletonizer/skeletonizer.dart';
import '../providers/drive_list_provider.dart';
import 'drive_list_tile.dart';

class DriveListPanel extends ConsumerWidget {
  final VoidCallback onSettings;
  const DriveListPanel({super.key, required this.onSettings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivesAsync = ref.watch(driveListProvider);
    final selectedId = ref.watch(selectedDriveProvider);

    return Column(
      children: [
        _Header(onSettings: onSettings),
        const Divider(height: 1),
        Expanded(
          child: drivesAsync.when(
            loading: () => _SkeletonDriveList(),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (entries) {
              if (entries.isEmpty) {
                return const Center(
                  child: Text('No drives found'),
                );
              }
              return ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final entry = entries[i];
                  return DriveListTile(
                    entry: entry,
                    isSelected: selectedId == entry.id,
                    onTap: () {
                      ref.read(selectedDriveProvider.notifier).state = entry.id;
                    },
                  );
                },
              );
            },
          ),
        ),
        const Divider(height: 1),
        _BottomActions(),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onSettings;
  const _Header({required this.onSettings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.album, size: 20),
          const SizedBox(width: 8),
          Text(
            'Disc Buddy',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: onSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _BottomActions extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add file...'),
              onPressed: () => _pickFile(context, ref),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _pickFolder(context, ref),
            child: const Icon(Icons.folder_outlined, size: 16),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFile(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select file',
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    _addByPath(messenger, ref, path);
  }

  Future<void> _pickFolder(BuildContext context, WidgetRef ref) async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select video directory',
    );
    if (path != null) {
      ref.read(virtualEntriesProvider.notifier).addDir(path);
      ref.read(selectedDriveProvider.notifier).state = path;
    }
  }

  void _addByPath(ScaffoldMessengerState messenger, WidgetRef ref, String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      ref.read(virtualEntriesProvider.notifier).addDir(path);
      ref.read(selectedDriveProvider.notifier).state = path;
      return;
    }
    final lower = path.toLowerCase();
    if (lower.endsWith('.iso')) {
      ref.read(virtualEntriesProvider.notifier).addIso(path);
      ref.read(selectedDriveProvider.notifier).state = path;
    } else if (lower.endsWith('.mkv')) {
      ref.read(virtualEntriesProvider.notifier).addMkv(path);
      ref.read(selectedDriveProvider.notifier).state = path;
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('Unsupported file type. Select an .iso or .mkv file.')),
      );
    }
  }
}

class _SkeletonDriveList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final fakeDrives = List.generate(3, (i) => _FakeDrive());
    return Skeletonizer(
      child: ListView.builder(
        itemCount: fakeDrives.length,
        itemBuilder: (context, i) => ListTile(
          leading: const Icon(Icons.album),
          title: Text('ASUS DRW-24B1ST'),
          subtitle: Text('/dev/sr$i — (no disc)'),
          trailing: const SizedBox(width: 48),
        ),
      ),
    );
  }
}

class _FakeDrive {
  final String name = 'ASUS DRW-24B1ST';
  final String device = '/dev/sr0';
}
