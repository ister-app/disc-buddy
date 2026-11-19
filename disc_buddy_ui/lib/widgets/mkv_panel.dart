import 'package:material_ui/material_ui.dart';
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
  final _hintController = TextEditingController();
  final _seasonController = TextEditingController();
  bool _extractSubtitles = false;
  late bool _autoName;

  @override
  void initState() {
    super.initState();
    final filename = widget.content.path.split('/').last;
    final stem = filename.toLowerCase().endsWith('.mkv')
        ? filename.substring(0, filename.length - 4)
        : filename;
    _nameController = TextEditingController(text: stem);
    _langsController = TextEditingController(text: 'en,nl');
    _autoName = ref.read(settingsProvider).autoName;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _langsController.dispose();
    _hintController.dispose();
    _seasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // Configured path or default command on PATH — same check as elsewhere.
    final canExtract = ref.watch(subtitleToolsAvailableProvider);
    final canAutoName = settings.tmdbToken != null &&
        settings.llmUrl != null &&
        settings.llmModel != null &&
        (canExtract || ref.watch(whisperAvailableProvider));
    final autoName = _autoName && canAutoName;

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
              if (canAutoName)
                SwitchListTile(
                  title: const Text('Auto name'),
                  subtitle: const Text(
                      'Identify the film or episode from its subtitles or audio'),
                  value: _autoName,
                  onChanged: (v) => setState(() => _autoName = v),
                  contentPadding: EdgeInsets.zero,
                ),
              if (autoName)
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hintController,
                        decoration: const InputDecoration(
                          labelText: 'Series / Movie name (optional hint)',
                          hintText: 'e.g. Seinfeld',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _seasonController,
                        decoration: const InputDecoration(
                          labelText: 'Season(s)',
                          hintText: 'e.g. 7',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                )
              else
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
                  'Subtitle extraction unavailable — install mkvextract and subtile-ocr or set their paths in Settings.',
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
    final settings = ref.read(settingsProvider);
    final autoName = _autoName &&
        settings.tmdbToken != null &&
        settings.llmUrl != null &&
        settings.llmModel != null &&
        (ref.read(subtitleToolsAvailableProvider) ||
            ref.read(whisperAvailableProvider));
    final typed =
        (autoName ? _hintController.text : _nameController.text).trim();
    ref.read(ripStateProvider(widget.entry.id).notifier).startMkvProcess(
      mkvPath: widget.content.path,
      newName: typed.isEmpty ? null : typed,
      extractSubtitles: _extractSubtitles,
      subtitleLangs: _langsController.text.trim(),
      autoName: autoName,
      seasons: autoName
          ? _seasonController.text
              .split(RegExp(r'[,\s]+'))
              .map(int.tryParse)
              .whereType<int>()
              .toList()
          : const [],
    );
  }
}
