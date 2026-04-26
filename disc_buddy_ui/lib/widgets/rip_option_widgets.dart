import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/settings_provider.dart';

class RipOptionsRow extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController seasonController;
  final bool autoName;
  final ValueChanged<bool> onAutoNameChanged;
  final bool batchAssign;
  final ValueChanged<bool> onBatchAssignChanged;

  const RipOptionsRow({
    super.key,
    required this.nameController,
    required this.seasonController,
    required this.autoName,
    required this.onAutoNameChanged,
    required this.batchAssign,
    required this.onBatchAssignChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: autoName,
                onChanged: (v) => onAutoNameChanged(v ?? false),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => onAutoNameChanged(!autoName),
                child: const Text('Auto name'),
              ),
              if (autoName) ...[
                const SizedBox(width: 16),
                Checkbox(
                  value: batchAssign,
                  onChanged: (v) => onBatchAssignChanged(v ?? false),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => onBatchAssignChanged(!batchAssign),
                  child: const Text('Batch'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: nameController,
                  enabled: autoName,
                  decoration: const InputDecoration(
                    labelText: 'Series / Movie name',
                    hintText: 'e.g. Seinfeld',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: seasonController,
                  enabled: autoName,
                  decoration: const InputDecoration(
                    labelText: 'Season(s)',
                    hintText: 'e.g. 4 or 1,2',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class OutputDirRow extends ConsumerWidget {
  const OutputDirRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return _DirRow(
      effectiveDir: settings.effectiveOutputDir,
      isDefault: settings.videoDir == null,
      tooltip: 'Change video output directory',
      onPick: (path) => ref.read(settingsProvider.notifier)
          .update((s) => s.copyWith(videoDir: path)),
      onReset: () => ref.read(settingsProvider.notifier)
          .update((s) => s.copyWith(videoDir: null)),
    );
  }
}

class OutputMusicDirRow extends ConsumerWidget {
  const OutputMusicDirRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return _DirRow(
      effectiveDir: settings.effectiveMusicDir,
      isDefault: settings.musicDir == null,
      tooltip: 'Change music output directory',
      onPick: (path) => ref.read(settingsProvider.notifier)
          .update((s) => s.copyWith(musicDir: path)),
      onReset: () => ref.read(settingsProvider.notifier)
          .update((s) => s.copyWith(musicDir: null)),
    );
  }
}

class _DirRow extends StatelessWidget {
  final String effectiveDir;
  final bool isDefault;
  final String tooltip;
  final ValueChanged<String> onPick;
  final VoidCallback onReset;

  const _DirRow({
    required this.effectiveDir,
    required this.isDefault,
    required this.tooltip,
    required this.onPick,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context, ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.folder_outlined,
              size: 18, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              effectiveDir,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isDefault ? Theme.of(context).colorScheme.outline : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () async {
              final path = await FilePicker.getDirectoryPath(
                dialogTitle: tooltip,
                initialDirectory: effectiveDir,
              );
              if (path != null) onPick(path);
            },
          ),
          if (!isDefault)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Reset to default',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onReset,
            ),
        ],
      ),
    );
  }
}
