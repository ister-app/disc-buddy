import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/disc_content.dart';
import '../providers/drive_list_provider.dart';
import '../providers/rip_state_provider.dart';
import '../providers/settings_provider.dart';

class MkvPanel extends ConsumerStatefulWidget {
  final DriveEntry entry;
  final MkvContent content;

  const MkvPanel({super.key, required this.entry, required this.content});

  @override
  ConsumerState<MkvPanel> createState() => _MkvPanelState();
}

class _MkvPanelState extends ConsumerState<MkvPanel> {
  late TextEditingController _nameController;
  late TextEditingController _langsController;
  bool _extractSubtitles = false;

  @override
  void initState() {
    super.initState();
    final filename = widget.content.path.split('/').last;
    final stem = filename.toLowerCase().endsWith('.mkv')
        ? filename.substring(0, filename.length - 4)
        : filename;
    _nameController = TextEditingController(text: stem);
    _langsController = TextEditingController(text: 'en,nl');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _langsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final canExtract = settings.mkvextract != null && settings.subtileOcr != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.movie_outlined, size: 32,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.content.path.split('/').last,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.content.path,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Output name (without .mkv)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (canExtract) ...[
                SwitchListTile(
                  title: const Text('Extract subtitles'),
                  value: _extractSubtitles,
                  onChanged: (v) => setState(() => _extractSubtitles = v),
                  contentPadding: EdgeInsets.zero,
                ),
                if (_extractSubtitles) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _langsController,
                    decoration: const InputDecoration(
                      labelText: 'Languages (e.g. en,nl)',
                      hintText: 'Leave empty for all languages',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ] else
                Text(
                  'Subtitle extraction unavailable — configure mkvextract and subtile-ocr in Settings.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.drive_file_rename_outline),
            label: const Text('Process'),
            onPressed: _process,
          ),
        ),
      ],
    );
  }

  void _process() {
    ref.read(ripStateProvider(widget.entry.id).notifier).startMkvProcess(
      mkvPath: widget.content.path,
      newName: _nameController.text.trim().isEmpty ? null : _nameController.text.trim(),
      extractSubtitles: _extractSubtitles,
      subtitleLangs: _langsController.text.trim(),
    );
  }
}
