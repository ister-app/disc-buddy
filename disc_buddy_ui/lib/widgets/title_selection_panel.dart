import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../models/disc_content.dart';
import '../models/rip_state.dart';
import '../providers/drive_list_provider.dart';
import '../providers/rip_state_provider.dart';
import '../providers/settings_provider.dart';
import 'rip_option_widgets.dart';

class TitleSelectionPanel extends ConsumerStatefulWidget {
  final DriveEntry entry;
  final VideoDiscContent content;
  final RipState ripState;

  const TitleSelectionPanel({
    super.key,
    required this.entry,
    required this.content,
    required this.ripState,
  });

  @override
  ConsumerState<TitleSelectionPanel> createState() => _TitleSelectionPanelState();
}

class _TitleSelectionPanelState extends ConsumerState<TitleSelectionPanel> {
  final _nameController = TextEditingController();
  final _seasonController = TextEditingController();
  late bool _autoName;
  late bool _batchAssign;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _autoName = settings.autoName;
    _batchAssign = settings.batchAssign;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(ripStateProvider(widget.entry.id).notifier);
      final state = ref.read(ripStateProvider(widget.entry.id));
      if (state is RipIdle) {
        final autoSelected = _computeAutoSelect();
        notifier.startTitleSelection(widget.content.discTitle, widget.content.titles, autoSelected);
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _seasonController.dispose();
    super.dispose();
  }

  Set<String> _computeAutoSelect() => widget.content.suggestion;

  @override
  Widget build(BuildContext context) {
    final ripState = ref.watch(ripStateProvider(widget.entry.id));
    if (ripState is! RipTitleSelection && ripState is! RipNamingStep && ripState is! RipSubtitleStep) {
      return const SizedBox.shrink();
    }

    final selState = ripState is RipTitleSelection
        ? ripState
        : RipTitleSelection(
            discTitle: widget.content.discTitle,
            titles: widget.content.titles,
            selectedKeys: const {},
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          discTitle: widget.content.discTitle,
          discType: widget.content.discType,
          titleCount: widget.content.titles.length,
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
          child: _TitleList(
            entry: widget.entry,
            titles: widget.content.titles,
            selectedKeys: selState.selectedKeys,
            configs: selState.configs,
          ),
        ),
        const Divider(height: 1),
        _Footer(
          entry: widget.entry,
          selState: selState,
          content: widget.content,
          nameController: _nameController,
          seasonController: _seasonController,
          autoName: _autoName,
          batchAssign: _batchAssign,
          onAutoReset: () {
            final notifier = ref.read(ripStateProvider(widget.entry.id).notifier);
            notifier.resetToAutoSelect(_computeAutoSelect());
          },
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String discTitle;
  final DiscType discType;
  final int titleCount;
  const _Header({required this.discTitle, required this.discType, required this.titleCount});

  @override
  Widget build(BuildContext context) {
    final typeLabel = discType == DiscType.dvd ? 'DVD' : 'Blu-ray';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(discTitle, style: Theme.of(context).textTheme.titleLarge),
          Text('$typeLabel · $titleCount title${titleCount == 1 ? '' : 's'} found',
            style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}


class _TitleList extends ConsumerWidget {
  final DriveEntry entry;
  final List<VideoTitle> titles;
  final Set<String> selectedKeys;
  final Map<String, TitleConfig> configs;
  const _TitleList({
    required this.entry,
    required this.titles,
    required this.selectedKeys,
    required this.configs,
  });

  bool _hasCustomConfig(TitleConfig? cfg) =>
      cfg != null &&
      (cfg.customName?.isNotEmpty == true ||
          cfg.audioIndices != null ||
          cfg.subtitleIndices != null ||
          cfg.audioLangOverrides?.isNotEmpty == true ||
          cfg.subtitleLangOverrides?.isNotEmpty == true);

  Future<void> _showConfig(BuildContext context, WidgetRef ref, VideoTitle t) async {
    final settings = ref.read(settingsProvider);
    final result = await showDialog<_ConfigResult>(
      context: context,
      builder: (_) => _TitleConfigDialog(
        title: t,
        initial: configs[t.displayKey],
        audioLangFilter: _parseLangSet(settings.audioLangs),
        subtitleLangFilter: _parseLangSet(settings.subtitleTrackLangs),
      ),
    );
    if (result is _ConfigApply) {
      ref.read(ripStateProvider(entry.id).notifier).updateTitleConfig(t.displayKey, result.config);
    } else if (result is _ConfigReset) {
      ref.read(ripStateProvider(entry.id).notifier).updateTitleConfig(t.displayKey, null);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: titles.length,
      itemBuilder: (context, i) {
        final t = titles[i];
        final cfg = configs[t.displayKey];
        final hasCustom = _hasCustomConfig(cfg);
        return CheckboxListTile(
          value: selectedKeys.contains(t.displayKey),
          onChanged: (_) => ref
              .read(ripStateProvider(entry.id).notifier)
              .toggleTitle(t.displayKey),
          title: Row(
            children: [
              Text(
                t.displayKey.padRight(6),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(width: 4),
              Text(
                t.durationLabel,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  cfg?.customName?.isNotEmpty == true
                      ? cfg!.customName!
                      : '${t.audioStreamCount} audio  ${t.subtitleStreamCount} sub  ${t.chapters.length} ch',
                  style: cfg?.customName?.isNotEmpty == true
                      ? Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic)
                      : Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          subtitle: t.extraInfo != null
              ? Text(t.extraInfo!, style: Theme.of(context).textTheme.bodySmall)
              : null,
          secondary: IconButton(
            icon: Icon(
              Icons.tune,
              size: 18,
              color: hasCustom ? Theme.of(context).colorScheme.primary : null,
            ),
            tooltip: 'Configure tracks & name',
            onPressed: () => _showConfig(context, ref, t),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        );
      },
    );
  }
}

const _compactTextButton = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
  minimumSize: WidgetStatePropertyAll(Size.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

Set<String>? _parseLangSet(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final set = s.split(RegExp(r'[,\s]+')).map((l) => l.trim().toLowerCase()).where((l) => l.isNotEmpty).toSet();
  return set.isEmpty ? null : set;
}

sealed class _ConfigResult {}

class _ConfigApply extends _ConfigResult {
  final TitleConfig config;
  _ConfigApply(this.config);
}

class _ConfigReset extends _ConfigResult {}

class _TitleConfigDialog extends StatefulWidget {
  final VideoTitle title;
  final TitleConfig? initial;
  final Set<String>? audioLangFilter;
  final Set<String>? subtitleLangFilter;

  const _TitleConfigDialog({
    required this.title,
    this.initial,
    this.audioLangFilter,
    this.subtitleLangFilter,
  });

  @override
  State<_TitleConfigDialog> createState() => _TitleConfigDialogState();
}

class _TitleConfigDialogState extends State<_TitleConfigDialog> {
  late final TextEditingController _nameCtrl;
  late Set<int> _audioIndices;
  late Set<int> _subtitleIndices;
  late Map<int, String> _audioLangOverrides;
  late Map<int, String> _subtitleLangOverrides;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initial;
    _nameCtrl = TextEditingController(text: cfg?.customName ?? '');
    _audioIndices = cfg?.audioIndices != null
        ? Set.from(cfg!.audioIndices!)
        : _defaultByLang(widget.title.audioLangCodes, widget.audioLangFilter, widget.title.audioStreamCount);
    _subtitleIndices = cfg?.subtitleIndices != null
        ? Set.from(cfg!.subtitleIndices!)
        : _defaultByLang(widget.title.subtitleLangCodes, widget.subtitleLangFilter, widget.title.subtitleStreamCount);
    _audioLangOverrides = Map.from(cfg?.audioLangOverrides ?? {});
    _subtitleLangOverrides = Map.from(cfg?.subtitleLangOverrides ?? {});
  }

  String _effectiveAudioLang(int i) {
    final code = _audioLangOverrides[i] ??
        (i < widget.title.audioLangCodes.length ? widget.title.audioLangCodes[i] : '');
    return code.isNotEmpty ? code.toUpperCase() : '??';
  }

  String _effectiveSubLang(int i) {
    final code = _subtitleLangOverrides[i] ??
        (i < widget.title.subtitleLangCodes.length ? widget.title.subtitleLangCodes[i] : '');
    return code.isNotEmpty ? code.toUpperCase() : '??';
  }

  Future<void> _editLang({required bool isAudio, required int idx}) async {
    final current = isAudio ? _effectiveAudioLang(idx) : _effectiveSubLang(idx);
    final original = isAudio
        ? (idx < widget.title.audioLangCodes.length ? widget.title.audioLangCodes[idx].toUpperCase() : '??')
        : (idx < widget.title.subtitleLangCodes.length ? widget.title.subtitleLangCodes[idx].toUpperCase() : '??');
    final hasOverride = isAudio ? _audioLangOverrides.containsKey(idx) : _subtitleLangOverrides.containsKey(idx);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _LangEditDialog(
        current: current,
        original: original,
        hasOverride: hasOverride,
      ),
    );
    if (result == null) return;
    setState(() {
      if (result.isEmpty) {
        if (isAudio) { _audioLangOverrides.remove(idx); }
        else { _subtitleLangOverrides.remove(idx); }
      } else {
        if (isAudio) { _audioLangOverrides[idx] = result.toLowerCase(); }
        else { _subtitleLangOverrides[idx] = result.toLowerCase(); }
      }
    });
  }

  Set<int> _defaultByLang(List<String> langCodes, Set<String>? filter, int count) {
    if (filter == null || filter.isEmpty) return Set.from(List.generate(count, (i) => i));
    final matching = {
      for (var i = 0; i < langCodes.length; i++)
        if (filter.any((l) => langMatchesFilter(langCodes[i], l))) i,
    };
    return matching.isEmpty ? Set.from(List.generate(count, (i) => i)) : matching;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final audioLabels = widget.title.audioTrackLabels;
    final subLabels = widget.title.subtitleTrackLabels;
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text('Configure title ${widget.title.displayKey}'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: 'Custom output name',
                  hintText: widget.title.filename,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (audioLabels.isNotEmpty) ...[
                const SizedBox(height: 16),
                _TrackSectionHeader(
                  label: 'Audio (${_audioIndices.length}/${audioLabels.length})',
                  onAll: () => setState(() => _audioIndices = Set.from(List.generate(audioLabels.length, (i) => i))),
                  onNone: () => setState(() => _audioIndices = {}),
                ),
                for (int i = 0; i < audioLabels.length; i++)
                  CheckboxListTile(
                    value: _audioIndices.contains(i),
                    onChanged: (v) => setState(() {
                      if (v == true) { _audioIndices.add(i); } else { _audioIndices.remove(i); }
                    }),
                    title: Row(children: [
                      Expanded(child: Text('${i + 1}. ${audioLabels[i]}')),
                      _LangChip(
                        lang: _effectiveAudioLang(i),
                        overridden: _audioLangOverrides.containsKey(i),
                        onTap: () => _editLang(isAudio: true, idx: i),
                      ),
                    ]),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
              if (subLabels.isNotEmpty) ...[
                const SizedBox(height: 16),
                _TrackSectionHeader(
                  label: 'Subtitles (${_subtitleIndices.length}/${subLabels.length})',
                  onAll: () => setState(() => _subtitleIndices = Set.from(List.generate(subLabels.length, (i) => i))),
                  onNone: () => setState(() => _subtitleIndices = {}),
                ),
                for (int i = 0; i < subLabels.length; i++)
                  CheckboxListTile(
                    value: _subtitleIndices.contains(i),
                    onChanged: (v) => setState(() {
                      if (v == true) { _subtitleIndices.add(i); } else { _subtitleIndices.remove(i); }
                    }),
                    title: Row(children: [
                      Expanded(child: Text('${i + 1}. ${subLabels[i]}')),
                      _LangChip(
                        lang: _effectiveSubLang(i),
                        overridden: _subtitleLangOverrides.containsKey(i),
                        onTap: () => _editLang(isAudio: false, idx: i),
                      ),
                    ]),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _ConfigReset()),
          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
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
              onPressed: () {
                final allAudio = _audioIndices.length == widget.title.audioStreamCount;
                final allSubs = _subtitleIndices.length == widget.title.subtitleStreamCount;
                Navigator.pop(
                  context,
                  _ConfigApply(TitleConfig(
                    customName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
                    audioIndices: allAudio ? null : Set.from(_audioIndices),
                    subtitleIndices: allSubs ? null : Set.from(_subtitleIndices),
                    audioLangOverrides: _audioLangOverrides.isEmpty ? null : Map.from(_audioLangOverrides),
                    subtitleLangOverrides: _subtitleLangOverrides.isEmpty ? null : Map.from(_subtitleLangOverrides),
                  )),
                );
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Footer extends ConsumerStatefulWidget {
  final DriveEntry entry;
  final RipTitleSelection selState;
  final VideoDiscContent content;
  final TextEditingController nameController;
  final TextEditingController seasonController;
  final bool autoName;
  final bool batchAssign;
  final VoidCallback onAutoReset;

  const _Footer({
    required this.entry,
    required this.selState,
    required this.content,
    required this.nameController,
    required this.seasonController,
    required this.autoName,
    required this.batchAssign,
    required this.onAutoReset,
  });

  @override
  ConsumerState<_Footer> createState() => _FooterState();
}

class _FooterState extends ConsumerState<_Footer> {
  bool _extractSubs = false;

  @override
  Widget build(BuildContext context) {
    final selectedCount = widget.selState.selectedKeys.length;
    final notifier = ref.read(ripStateProvider(widget.entry.id).notifier);
    final canExtract = ref.watch(subtitleToolsAvailableProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          TextButton(
            style: _compactTextButton,
            onPressed: widget.onAutoReset,
            child: const Text('Auto'),
          ),
          TextButton(
            style: _compactTextButton,
            onPressed: () => notifier.selectAll(),
            child: const Text('All'),
          ),
          TextButton(
            style: _compactTextButton,
            onPressed: () => notifier.deselectAll(),
            child: const Text('None'),
          ),
          const Spacer(),
          if (canExtract) ...[
            Checkbox(
              value: _extractSubs,
              onChanged: (v) => setState(() => _extractSubs = v ?? false),
            ),
            const Text('SRT'),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text('Rip $selectedCount'),
            onPressed: selectedCount == 0 ? null : () => _onRip(context),
          ),
        ],
      ),
    );
  }

  Future<void> _onRip(BuildContext context) async {
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
    await _startRip(context, extractSubtitles: _extractSubs, subtitleLangs: subtitleLangs);
  }

  Future<void> _startRip(
    BuildContext context, {
    bool extractSubtitles = false,
    String subtitleLangs = '',
  }) async {
    final selState = widget.selState;
    final settings = ref.read(settingsProvider);
    final outDirPath = p.join(
      settings.effectiveOutputDir,
      sanitizeFilename(selState.discTitle),
    );
    final selectedTitles = widget.content.titles
        .where((t) => selState.selectedKeys.contains(t.displayKey))
        .toList();

    final conflicts = <VideoTitle>[];
    for (final title in selectedTitles) {
      final cfg = selState.configs[title.displayKey];
      final fileName = cfg?.customName?.isNotEmpty == true
          ? '${sanitizeFilename(cfg!.customName!)}.mkv'
          : '${sanitizeFilename(selState.discTitle)}-${title.filename}';
      if (await File(p.join(outDirPath, fileName)).exists()) {
        conflicts.add(title);
      }
    }

    if (conflicts.isNotEmpty) {
      if (!context.mounted) return;
      final choice = await showDialog<_OverwriteChoice>(
        context: context,
        builder: (_) => _OverwriteDialog(conflicts: conflicts, outDir: outDirPath),
      );
      if (choice == null || choice == _OverwriteChoice.cancel) return;
      if (choice == _OverwriteChoice.skip) {
        final conflictKeys = conflicts.map((t) => t.displayKey).toSet();
        final notifier = ref.read(ripStateProvider(widget.entry.id).notifier);
        for (final t in conflicts) {
          notifier.toggleTitle(t.displayKey);
        }
        if (selState.selectedKeys.difference(conflictKeys).isEmpty) return;
      }
    }

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

    final notifier = ref.read(ripStateProvider(widget.entry.id).notifier);
    notifier.proceedToNaming();
    notifier.proceedToSubtitles(nameHint: name, seasons: seasons, autoName: widget.autoName, batchAssign: widget.batchAssign);
    if (extractSubtitles) {
      notifier.startRipFromSubtitleStep(extract: true, langs: subtitleLangs);
    } else {
      notifier.skipSubtitles();
    }
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
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('Rip'),
        ),
      ],
    );
  }

  void _confirm() => Navigator.pop(context, _controller.text.trim());
}

enum _OverwriteChoice { overwrite, skip, cancel }

class _OverwriteDialog extends StatelessWidget {
  final List<VideoTitle> conflicts;
  final String outDir;

  const _OverwriteDialog({required this.conflicts, required this.outDir});

  @override
  Widget build(BuildContext context) {
    final count = conflicts.length;
    return AlertDialog(
      title: Text('$count file${count == 1 ? '' : 's'} already exist${count == 1 ? 's' : ''}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('In $outDir:', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          ...conflicts.map((t) => Text('• ${t.displayKey}',
              style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.skip),
          child: const Text('Skip existing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _OverwriteChoice.overwrite),
          child: const Text('Overwrite'),
        ),
      ],
    );
  }
}

class _LangChip extends StatelessWidget {
  final String lang;
  final bool overridden;
  final VoidCallback onTap;
  const _LangChip({required this.lang, required this.overridden, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = overridden
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outline;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(lang,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontFamily: 'monospace',
                )),
            const SizedBox(width: 2),
            Icon(Icons.edit_outlined, size: 10, color: color),
          ],
        ),
      ),
    );
  }
}

class _LangEditDialog extends StatefulWidget {
  final String current;
  final String original;
  final bool hasOverride;

  const _LangEditDialog({
    required this.current,
    required this.original,
    required this.hasOverride,
  });

  @override
  State<_LangEditDialog> createState() => _LangEditDialogState();
}

class _LangEditDialogState extends State<_LangEditDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.current == '??' ? '' : widget.current);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename language'),
      content: TextField(
        controller: _ctrl,
        decoration: InputDecoration(
          labelText: 'Language code',
          hintText: widget.original,
          border: const OutlineInputBorder(),
          isDense: true,
          helperText: 'e.g. NL, EN, FR, DE',
        ),
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: 8,
        onSubmitted: (_) => Navigator.pop(context, _ctrl.text.trim()),
      ),
      actions: [
        if (widget.hasOverride)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Reset'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _TrackSectionHeader extends StatelessWidget {
  final String label;
  final VoidCallback onAll;
  final VoidCallback onNone;

  const _TrackSectionHeader({required this.label, required this.onAll, required this.onNone});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const Spacer(),
        TextButton(onPressed: onAll, child: const Text('All')),
        TextButton(onPressed: onNone, child: const Text('None')),
      ],
    );
  }
}
