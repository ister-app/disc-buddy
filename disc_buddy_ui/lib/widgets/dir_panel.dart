import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../models/disc_content.dart';
import '../providers/drive_list_provider.dart';
import '../providers/rip_state_provider.dart';
import '../providers/settings_provider.dart';
import 'rip_option_widgets.dart';

const _compactTextButton = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
  minimumSize: WidgetStatePropertyAll(Size.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class DirPanel extends ConsumerStatefulWidget {
  final DriveEntry entry;
  final DirContent content;

  const DirPanel({super.key, required this.entry, required this.content});

  @override
  ConsumerState<DirPanel> createState() => _DirPanelState();
}

class _DirPanelState extends ConsumerState<DirPanel> {
  late Set<String> _selected;
  final _nameController = TextEditingController();
  final _seasonController = TextEditingController();
  late bool _autoName;
  late bool _batchAssign;
  final Map<String, String?> _customNames = {};

  @override
  void initState() {
    super.initState();
    _selected = widget.content.files.map((f) => f.path).toSet();
    final settings = ref.read(settingsProvider);
    _autoName = settings.autoName;
    _batchAssign = settings.batchAssign;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _seasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.content.files;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DirHeader(
          dirPath: widget.content.dirPath,
          fileCount: files.length,
        ),
        const Divider(height: 1),
        RipOptionsRow(
          nameController: _nameController,
          seasonController: _seasonController,
          autoName: _autoName,
          onAutoNameChanged: (v) => setState(() => _autoName = v),
          batchAssign: _batchAssign,
          onBatchAssignChanged: (v) => setState(() => _batchAssign = v),
        ),
        const Divider(height: 1),
        const OutputDirRow(),
        const Divider(height: 1),
        Expanded(
          child: _FileList(
            files: files.map((f) => f.path).toList(),
            selected: _selected,
            customNames: _customNames,
            onToggle: (path, v) => setState(() {
              if (v == true) {
                _selected = {..._selected, path};
              } else {
                _selected = _selected.difference({path});
              }
            }),
            onToggleAll: () => setState(() {
              if (_selected.length == files.length) {
                _selected = {};
              } else {
                _selected = files.map((f) => f.path).toSet();
              }
            }),
            onConfigured: (path, name) => setState(() {
              _customNames[path] = name?.trim().isEmpty == true ? null : name;
            }),
          ),
        ),
        const Divider(height: 1),
        _DirFooter(
          entry: widget.entry,
          selectedCount: _selected.length,
          selectedPaths: _selected,
          customNames: _customNames,
          autoName: _autoName,
          batchAssign: _batchAssign,
          nameController: _nameController,
          seasonController: _seasonController,
          onSelectAll: () => setState(() =>
              _selected = widget.content.files.map((f) => f.path).toSet()),
          onSelectNone: () => setState(() => _selected = {}),
        ),
      ],
    );
  }
}

class _DirHeader extends StatelessWidget {
  final String dirPath;
  final int fileCount;
  const _DirHeader({required this.dirPath, required this.fileCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.basename(dirPath),
            style: Theme.of(context).textTheme.titleLarge,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '$fileCount file${fileCount == 1 ? '' : 's'} found',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  final List<String> files;
  final Set<String> selected;
  final Map<String, String?> customNames;
  final void Function(String, bool?) onToggle;
  final VoidCallback onToggleAll;
  final void Function(String path, String? name) onConfigured;

  const _FileList({
    required this.files,
    required this.selected,
    required this.customNames,
    required this.onToggle,
    required this.onToggleAll,
    required this.onConfigured,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: files.length,
      itemBuilder: (context, i) {
        final path = files[i];
        final filename = p.basename(path);
        final stem = p.basenameWithoutExtension(path);
        final customName = customNames[path];
        final hasCustom = customName != null && customName.isNotEmpty;

        return CheckboxListTile(
          value: selected.contains(path),
          onChanged: (v) => onToggle(path, v),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  filename,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (hasCustom) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    customName,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          secondary: IconButton(
            icon: Icon(
              Icons.tune,
              size: 18,
              color: hasCustom ? Theme.of(context).colorScheme.primary : null,
            ),
            tooltip: 'Configure name',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => _showConfig(context, path, stem, customName),
          ),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        );
      },
    );
  }

  Future<void> _showConfig(
    BuildContext context,
    String path,
    String stem,
    String? currentName,
  ) async {
    final result = await showDialog<_NameResult>(
      context: context,
      builder: (_) => _FileNameDialog(
        filename: p.basename(path),
        currentName: currentName ?? stem,
      ),
    );
    if (result is _NameApply) {
      onConfigured(path, result.name);
    } else if (result is _NameReset) {
      onConfigured(path, null);
    }
  }
}

sealed class _NameResult {}
class _NameApply extends _NameResult {
  final String name;
  _NameApply(this.name);
}
class _NameReset extends _NameResult {}

class _FileNameDialog extends StatefulWidget {
  final String filename;
  final String currentName;
  const _FileNameDialog({required this.filename, required this.currentName});

  @override
  State<_FileNameDialog> createState() => _FileNameDialogState();
}

class _FileNameDialogState extends State<_FileNameDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Rename ${widget.filename}'),
      content: TextField(
        controller: _ctrl,
        decoration: const InputDecoration(
          labelText: 'Output name (without .mkv)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        autofocus: true,
        onSubmitted: (_) => _apply(),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _NameReset()),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error),
          child: const Text('Reset'),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _apply,
              child: const Text('Apply'),
            ),
          ],
        ),
      ],
    );
  }

  void _apply() => Navigator.pop(context, _NameApply(_ctrl.text.trim()));
}

class _DirFooter extends ConsumerStatefulWidget {
  final DriveEntry entry;
  final int selectedCount;
  final Set<String> selectedPaths;
  final Map<String, String?> customNames;
  final bool autoName;
  final bool batchAssign;
  final TextEditingController nameController;
  final TextEditingController seasonController;
  final VoidCallback onSelectAll;
  final VoidCallback onSelectNone;

  const _DirFooter({
    required this.entry,
    required this.selectedCount,
    required this.selectedPaths,
    required this.customNames,
    required this.autoName,
    required this.batchAssign,
    required this.nameController,
    required this.seasonController,
    required this.onSelectAll,
    required this.onSelectNone,
  });

  @override
  ConsumerState<_DirFooter> createState() => _DirFooterState();
}

class _DirFooterState extends ConsumerState<_DirFooter> {
  bool _extractSubs = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          TextButton(
            style: _compactTextButton,
            onPressed: widget.onSelectAll,
            child: const Text('All'),
          ),
          TextButton(
            style: _compactTextButton,
            onPressed: widget.onSelectNone,
            child: const Text('None'),
          ),
          const Spacer(),
          if (ref.watch(subtitleToolsAvailableProvider)) ...[
            Checkbox(
              value: _extractSubs,
              onChanged: (v) => setState(() => _extractSubs = v ?? false),
            ),
            const Text('SRT'),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.drive_file_rename_outline),
            label: Text('Process ${widget.selectedCount}'),
            onPressed: widget.selectedCount == 0 ? null : () => _onProcess(context),
          ),
        ],
      ),
    );
  }

  Future<void> _onProcess(BuildContext context) async {
    String subtitleLangs = '';
    if (_extractSubs) {
      final langs = await showDialog<String>(
        context: context,
        builder: (_) => const _SubtitleLangsDialog(),
      );
      if (langs == null) return;
      subtitleLangs = langs;
    }
    if (!context.mounted) return;
    _process(subtitleLangs: subtitleLangs);
  }

  void _process({String subtitleLangs = ''}) {
    final name = widget.autoName && widget.nameController.text.trim().isNotEmpty
        ? widget.nameController.text.trim()
        : null;
    final seasons = widget.autoName
        ? widget.seasonController.text
            .split(RegExp(r'[,\s]+'))
            .map(int.tryParse)
            .whereType<int>()
            .toList()
        : <int>[];

    final fileNames = <String, String>{};
    for (final path in widget.selectedPaths) {
      final custom = widget.customNames[path];
      if (custom != null && custom.isNotEmpty) {
        fileNames[path] = custom;
      }
    }

    ref.read(ripStateProvider(widget.entry.id).notifier).startDirProcess(
      filePaths: widget.selectedPaths.toList()..sort(),
      extractSubtitles: _extractSubs,
      subtitleLangs: subtitleLangs,
      fileNames: fileNames,
      autoName: widget.autoName,
      batchAssign: widget.batchAssign,
      nameHint: name,
      seasons: seasons,
    );
  }
}

class _SubtitleLangsDialog extends StatefulWidget {
  const _SubtitleLangsDialog();

  @override
  State<_SubtitleLangsDialog> createState() => _SubtitleLangsDialogState();
}

class _SubtitleLangsDialogState extends State<_SubtitleLangsDialog> {
  final _controller = TextEditingController(text: 'en,nl');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Extract subtitles'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'Languages',
          hintText: 'e.g. en,nl — leave empty for all',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        autofocus: true,
        onSubmitted: (_) => Navigator.pop(context, _controller.text.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Process'),
        ),
      ],
    );
  }
}
