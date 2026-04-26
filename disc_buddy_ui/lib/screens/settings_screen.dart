import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart' show xdgUserDir;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/settings.dart';
import '../providers/settings_provider.dart';

const _kWarningColor = Colors.amber;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = ref.watch(settingsProvider.select((s) => s.isLoaded));
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: loaded ? const _SettingsBody() : const _SettingsSkeleton(),
    );
  }
}

class _SettingsSkeleton extends StatelessWidget {
  const _SettingsSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget box(double h, {double? w}) => Container(
      height: h,
      width: w ?? double.infinity,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
    );
    Widget field() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: box(48),
    );
    Widget section(int fieldCount) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 10),
            child: box(13, w: 100),
          ),
          for (var i = 0; i < fieldCount; i++) field(),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        section(2),
        section(4),
        section(2),
        section(6),
        const SizedBox(height: 24),
        box(44),
      ],
    );
  }
}

class _SettingsBody extends ConsumerStatefulWidget {
  const _SettingsBody();

  @override
  ConsumerState<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<_SettingsBody> {
  late TextEditingController _videoDir;
  late TextEditingController _musicDir;
  late TextEditingController _ffmpeg;
  late TextEditingController _ffprobe;
  late TextEditingController _mkvextract;
  late TextEditingController _subtileOcr;
  late TextEditingController _tmdbToken;
  late TextEditingController _llmUrl;
  late TextEditingController _llmKey;
  late TextEditingController _llmModel;
  late TextEditingController _audioLangs;
  late TextEditingController _subtitleTrackLangs;
  bool _autoName = false;
  bool _batchAssign = false;

  // null = not yet checked; true = found; false = not found
  final _binaryFound = <String, bool>{};

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _videoDir    = TextEditingController(text: s.videoDir  ?? '');
    _musicDir    = TextEditingController(text: s.musicDir  ?? '');
    _ffmpeg      = TextEditingController(text: s.ffmpeg);
    _ffprobe     = TextEditingController(text: s.ffprobe);
    _mkvextract  = TextEditingController(text: s.mkvextract ?? '');
    _subtileOcr  = TextEditingController(text: s.subtileOcr ?? '');
    _tmdbToken          = TextEditingController(text: s.tmdbToken ?? '');
    _llmUrl             = TextEditingController(text: s.llmUrl ?? '');
    _llmKey             = TextEditingController(text: s.llmKey ?? '');
    _llmModel           = TextEditingController(text: s.llmModel ?? '');
    _audioLangs         = TextEditingController(text: s.audioLangs ?? '');
    _subtitleTrackLangs = TextEditingController(text: s.subtitleTrackLangs ?? '');
    _autoName           = s.autoName;
    _batchAssign        = s.batchAssign;
    for (final c in [_tmdbToken, _llmUrl, _llmKey, _llmModel, _mkvextract, _subtileOcr]) {
      c.addListener(_onFieldChanged);
    }
    _checkBinaries();
  }

  void _onFieldChanged() => setState(() {});

  Future<void> _checkBinaries() async {
    final checks = <String, String>{
      'ffmpeg':      _ffmpeg.text.trim().isEmpty      ? 'ffmpeg'      : _ffmpeg.text.trim(),
      'ffprobe':     _ffprobe.text.trim().isEmpty     ? 'ffprobe'     : _ffprobe.text.trim(),
      'mkvextract':  _mkvextract.text.trim().isEmpty  ? 'mkvextract'  : _mkvextract.text.trim(),
      'subtile-ocr': _subtileOcr.text.trim().isEmpty  ? 'subtile-ocr' : _subtileOcr.text.trim(),
    };
    for (final e in checks.entries) {
      final found = await _binaryExists(e.value);
      if (mounted) setState(() => _binaryFound[e.key] = found);
    }
  }

  Future<bool> _binaryExists(String nameOrPath) async {
    if (nameOrPath.contains('/')) return File(nameOrPath).existsSync();
    final result = await Process.run('which', [nameOrPath]);
    return result.exitCode == 0;
  }

  @override
  void dispose() {
    for (final c in [_tmdbToken, _llmUrl, _llmKey, _llmModel, _mkvextract, _subtileOcr]) {
      c.removeListener(_onFieldChanged);
    }
    for (final c in [_videoDir, _musicDir, _ffmpeg, _ffprobe, _mkvextract, _subtileOcr,
                     _tmdbToken, _llmUrl, _llmKey, _llmModel,
                     _audioLangs, _subtitleTrackLangs]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final s = Settings(
      videoDir:           _videoDir.text.trim().isEmpty           ? null : _videoDir.text.trim(),
      musicDir:           _musicDir.text.trim().isEmpty           ? null : _musicDir.text.trim(),
      ffmpeg:             _ffmpeg.text.trim().isEmpty             ? null : _ffmpeg.text.trim(),
      ffprobe:            _ffprobe.text.trim().isEmpty            ? null : _ffprobe.text.trim(),
      mkvextract:         _mkvextract.text.trim().isEmpty         ? null : _mkvextract.text.trim(),
      subtileOcr:         _subtileOcr.text.trim().isEmpty         ? null : _subtileOcr.text.trim(),
      tmdbToken:          _tmdbToken.text.trim().isEmpty          ? null : _tmdbToken.text.trim(),
      llmUrl:             _llmUrl.text.trim().isEmpty             ? null : _llmUrl.text.trim(),
      llmKey:             _llmKey.text.trim().isEmpty             ? null : _llmKey.text.trim(),
      llmModel:           _llmModel.text.trim().isEmpty           ? null : _llmModel.text.trim(),
      autoName:           _autoName,
      batchAssign:        _batchAssign,
      audioLangs:         _audioLangs.text.trim().isEmpty         ? null : _audioLangs.text.trim(),
      subtitleTrackLangs: _subtitleTrackLangs.text.trim().isEmpty ? null : _subtitleTrackLangs.text.trim(),
    );
    ref.read(settingsProvider.notifier).save(s);
    _checkBinaries();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  List<_WarningItem> _computeWarnings() {
    final warnings = <_WarningItem>[];

    if (_binaryFound['ffmpeg'] == false) {
      final name = _ffmpeg.text.trim().isEmpty ? 'ffmpeg' : _ffmpeg.text.trim();
      warnings.add(_WarningItem(
        icon: Icons.videocam_off_outlined,
        title: 'Ripping unavailable',
        detail: '"$name" not found on this system',
      ));
    }
    if (_binaryFound['ffprobe'] == false) {
      final name = _ffprobe.text.trim().isEmpty ? 'ffprobe' : _ffprobe.text.trim();
      warnings.add(_WarningItem(
        icon: Icons.search_off_outlined,
        title: 'Disc scanning affected',
        detail: '"$name" not found on this system',
      ));
    }

    // Subtitle extraction
    final subMissing = <String>[];
    if (_binaryFound['mkvextract'] == false) {
      final name = _mkvextract.text.trim().isEmpty ? 'mkvextract' : _mkvextract.text.trim();
      subMissing.add('"$name" not found');
    }
    if (_binaryFound['subtile-ocr'] == false) {
      final name = _subtileOcr.text.trim().isEmpty ? 'subtile-ocr' : _subtileOcr.text.trim();
      subMissing.add('"$name" not found');
    }
    if (subMissing.isNotEmpty) {
      warnings.add(_WarningItem(
        icon: Icons.subtitles_off_outlined,
        title: 'Subtitle extraction unavailable',
        detail: subMissing.join(' · '),
      ));
    }

    // Auto-naming
    final autoMissing = <String>[];
    if (_tmdbToken.text.trim().isEmpty) autoMissing.add('TMDB token');
    if (_llmUrl.text.trim().isEmpty) autoMissing.add('LLM URL');
    if (_llmModel.text.trim().isEmpty) autoMissing.add('LLM model');
    if (subMissing.isNotEmpty) autoMissing.add('subtitle tools (see above)');
    if (autoMissing.isNotEmpty) {
      warnings.add(_WarningItem(
        icon: Icons.auto_awesome_outlined,
        title: 'Auto-naming unavailable',
        detail: 'Missing: ${autoMissing.join(', ')}',
      ));
    }

    return warnings;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(title: 'Output', children: [
          _FolderField(
            label: 'Video directory',
            hint: xdgUserDir('VIDEOS', fallback: r'$HOME/Videos'),
            controller: _videoDir,
            onPick: () async {
              final path = await FilePicker.platform.getDirectoryPath(
                dialogTitle: 'Select video output directory',
              );
              if (path != null) setState(() => _videoDir.text = path);
            },
          ),
          _FolderField(
            label: 'Music directory',
            hint: xdgUserDir('MUSIC', fallback: r'$HOME/Music'),
            controller: _musicDir,
            onPick: () async {
              final path = await FilePicker.platform.getDirectoryPath(
                dialogTitle: 'Select music output directory',
              );
              if (path != null) setState(() => _musicDir.text = path);
            },
          ),
        ]),
        _Section(title: 'Paths', children: [
          _TextField(label: 'ffmpeg', controller: _ffmpeg, hint: 'optional (default: ffmpeg)'),
          _TextField(label: 'ffprobe', controller: _ffprobe, hint: 'optional (default: ffprobe)'),
          _TextField(label: 'mkvextract', controller: _mkvextract, hint: 'optional (default: mkvextract)'),
          _TextField(label: 'subtile-ocr', controller: _subtileOcr, hint: 'optional (default: subtile-ocr)'),
        ]),
        _Section(title: 'Tracks', children: [
          _TextField(
            label: 'Audio languages',
            controller: _audioLangs,
            hint: 'e.g. nl, en — empty = all',
          ),
          _TextField(
            label: 'Subtitle languages',
            controller: _subtitleTrackLangs,
            hint: 'e.g. nl, en — empty = all',
          ),
        ]),
        _Section(title: 'LLM / Auto-naming', children: [
          _TextField(label: 'TMDB API token', controller: _tmdbToken,
            hint: 'optional', obscure: true),
          _TextField(label: 'LLM base URL', controller: _llmUrl,
            hint: 'e.g. http://localhost:11434/v1'),
          _TextField(label: 'LLM API key', controller: _llmKey,
            hint: 'optional (default: ollama)', obscure: true),
          _TextField(label: 'LLM model', controller: _llmModel,
            hint: 'e.g. gpt-4o or llama3'),
          SwitchListTile(
            title: const Text('Auto-name all titles with LLM'),
            subtitle: const Text('Requires TMDB token, LLM, mkvextract and subtile-ocr'),
            value: _autoName,
            onChanged: (v) => setState(() => _autoName = v),
          ),
          SwitchListTile(
            title: const Text('Batch assignment'),
            subtitle: const Text('Match all episodes in one LLM call (better with large models)'),
            value: _batchAssign,
            onChanged: _autoName ? (v) => setState(() => _batchAssign = v) : null,
          ),
        ]),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _save,
          child: const Text('Save settings'),
        ),
        const SizedBox(height: 8),
        Text(
          'Config file: ~/.config/disc-buddy/config.json',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        _WarningsSection(warnings: _computeWarnings()),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _WarningItem {
  final IconData icon;
  final String title;
  final String detail;
  const _WarningItem({required this.icon, required this.title, required this.detail});
}

class _WarningsSection extends StatelessWidget {
  final List<_WarningItem> warnings;
  const _WarningsSection({required this.warnings});

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 8),
          child: Text(
            'Warnings',
            style: textTheme.titleSmall?.copyWith(color: _kWarningColor),
          ),
        ),
        Card(
          color: _kWarningColor.withValues(alpha: 0.1),
          child: Column(
            children: [
              for (int i = 0; i < warnings.length; i++) ...[
                if (i > 0) Divider(height: 1, color: _kWarningColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: Icon(warnings[i].icon, color: _kWarningColor, size: 22),
                  title: Text(warnings[i].title),
                  subtitle: Text(warnings[i].detail,
                      style: textTheme.bodySmall?.copyWith(
                          color: _kWarningColor.withValues(alpha: 0.8))),
                  dense: true,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            )),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

class _TextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  const _TextField({required this.label, required this.controller, this.hint, this.obscure = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _FolderField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final VoidCallback onPick;
  final String? hint;
  const _FolderField({required this.label, required this.controller, required this.onPick, this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: 'Browse',
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}
