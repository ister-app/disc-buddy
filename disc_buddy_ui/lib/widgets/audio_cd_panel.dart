import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/drive_list_provider.dart';
import '../providers/rip_state_provider.dart';
import 'rip_option_widgets.dart';

const _compactTextButton = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
  minimumSize: WidgetStatePropertyAll(Size.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class AudioCdPanel extends ConsumerStatefulWidget {
  final DriveEntry entry;
  final DiscMetadata metadata;

  const AudioCdPanel({
    super.key,
    required this.entry,
    required this.metadata,
  });

  @override
  ConsumerState<AudioCdPanel> createState() => _AudioCdPanelState();
}

class _AudioCdPanelState extends ConsumerState<AudioCdPanel> {
  late Set<int> _selectedTracks;

  // Album-level overrides (null = use original from metadata)
  String? _album;
  String? _artist;
  String? _date;
  int?    _discNumber;
  int?    _totalDiscs;

  // Per-track overrides: trackNumber → (title, artist)
  final Map<int, ({String title, String artist})> _trackOverrides = {};

  @override
  void initState() {
    super.initState();
    _selectedTracks = Set.from(
      List.generate(widget.metadata.tracks.length, (i) => i + 1),
    );
  }

  DiscMetadata get _effectiveMeta {
    final orig = widget.metadata;
    return DiscMetadata(
      album:         _album       ?? orig.album,
      artist:        _artist      ?? orig.artist,
      date:          _date        ?? orig.date,
      discNumber:    _discNumber  ?? orig.discNumber,
      totalDiscs:    _totalDiscs  ?? orig.totalDiscs,
      artistMbid:    orig.artistMbid,
      releaseMbid:   orig.releaseMbid,
      label:         orig.label,
      catalogNumber: orig.catalogNumber,
      tracks: orig.tracks.map((t) {
        final ov = _trackOverrides[t.number];
        if (ov == null) return t;
        return TrackInfo(
          number:          t.number,
          title:           ov.title,
          artist:          ov.artist,
          artistMbid:      t.artistMbid,
          recordingMbid:   t.recordingMbid,
          startTime:       t.startTime,
          endTime:         t.endTime,
        );
      }).toList(),
    );
  }

  bool get _albumEdited =>
      _album != null || _artist != null || _date != null ||
      _discNumber != null || _totalDiscs != null;

  Future<void> _editAlbum() async {
    final orig = widget.metadata;
    final result = await showDialog<_AlbumResult>(
      context: context,
      builder: (_) => _AlbumEditDialog(
        album:       _album      ?? orig.album,
        artist:      _artist     ?? orig.artist,
        date:        _date       ?? orig.date,
        discNumber:  _discNumber ?? orig.discNumber,
        totalDiscs:  _totalDiscs ?? orig.totalDiscs,
      ),
    );
    if (result == null) return;
    setState(() {
      _album      = result.album      != orig.album      ? result.album      : null;
      _artist     = result.artist     != orig.artist     ? result.artist     : null;
      _date       = result.date       != orig.date       ? result.date       : null;
      _discNumber = result.discNumber != orig.discNumber ? result.discNumber : null;
      _totalDiscs = result.totalDiscs != orig.totalDiscs ? result.totalDiscs : null;
    });
  }

  Future<void> _editTrack(TrackInfo track) async {
    final ov = _trackOverrides[track.number];
    final result = await showDialog<_TrackResult>(
      context: context,
      builder: (_) => _TrackEditDialog(
        number:           track.number,
        title:            ov?.title  ?? track.title,
        artist:           ov?.artist ?? track.artist,
        defaultArtist:    widget.metadata.albumArtist,
      ),
    );
    if (result == null) return;
    setState(() {
      if (result is _TrackApply) {
        _trackOverrides[track.number] = (title: result.title, artist: result.artist);
      } else {
        _trackOverrides.remove(track.number);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final orig = widget.metadata;
    final effectiveAlbum      = _album      ?? orig.album;
    final effectiveArtist     = _artist     ?? orig.artist;
    final effectiveDate       = _date       ?? orig.date;
    final effectiveDiscNumber = _discNumber ?? orig.discNumber;
    final effectiveTotalDiscs = _totalDiscs ?? orig.totalDiscs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CdHeader(
          album:       effectiveAlbum,
          artist:      effectiveArtist,
          date:        effectiveDate,
          discNumber:  effectiveDiscNumber,
          totalDiscs:  effectiveTotalDiscs,
          edited:      _albumEdited,
          onEdit:      _editAlbum,
        ),
        const Divider(height: 1),
        const OutputMusicDirRow(),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: orig.tracks.length,
            itemBuilder: (context, i) {
              final track = orig.tracks[i];
              final nr    = track.number;
              final ov    = _trackOverrides[nr];
              final title  = ov?.title  ?? track.title;
              final artist = ov?.artist ?? track.artist;
              final hasOverride = ov != null;
              return CheckboxListTile(
                value: _selectedTracks.contains(nr),
                onChanged: (_) => setState(() {
                  if (_selectedTracks.contains(nr)) {
                    _selectedTracks.remove(nr);
                  } else {
                    _selectedTracks.add(nr);
                  }
                }),
                title: Row(
                  children: [
                    Text(nr.toString().padLeft(2),
                        style: const TextStyle(fontFamily: 'monospace')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: hasOverride
                            ? TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
                subtitle: artist.isNotEmpty && artist != orig.albumArtist
                    ? Text(artist, overflow: TextOverflow.ellipsis)
                    : null,
                secondary: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(track.durationLabel,
                        style: const TextStyle(fontFamily: 'monospace')),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        Icons.tune,
                        size: 18,
                        color: hasOverride
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      tooltip: 'Edit track info',
                      onPressed: () => _editTrack(track),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              TextButton(
                style: _compactTextButton,
                onPressed: () => setState(() {
                  _selectedTracks = Set.from(
                      List.generate(orig.tracks.length, (i) => i + 1));
                }),
                child: const Text('All'),
              ),
              TextButton(
                style: _compactTextButton,
                onPressed: () => setState(() => _selectedTracks = {}),
                child: const Text('None'),
              ),
              const Spacer(),
              FilledButton.icon(
                icon: const Icon(Icons.music_note),
                label: Text('Rip ${_selectedTracks.length}'),
                onPressed: _selectedTracks.isEmpty
                    ? null
                    : () => ref
                        .read(ripStateProvider(widget.entry.id).notifier)
                        .startAudioCdRip(
                          _effectiveMeta,
                          _selectedTracks.toList()..sort(),
                        ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _CdHeader extends StatelessWidget {
  final String album;
  final String artist;
  final String date;
  final int discNumber;
  final int totalDiscs;
  final bool edited;
  final VoidCallback onEdit;

  const _CdHeader({
    required this.album,
    required this.artist,
    required this.date,
    required this.discNumber,
    required this.totalDiscs,
    required this.edited,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final discLabel = discNumber > 0
        ? (totalDiscs > 1 ? 'Disc $discNumber of $totalDiscs' : 'Disc $discNumber')
        : null;
    final meta = [if (date.isNotEmpty) date, ?discLabel].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.album, size: 48,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(album,
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis),
                Text(artist,
                    style: Theme.of(context).textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis),
                if (meta.isNotEmpty)
                  Text(meta, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.edit_outlined,
              size: 20,
              color: edited ? Theme.of(context).colorScheme.primary : null,
            ),
            tooltip: 'Edit album info',
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Album edit dialog
// ---------------------------------------------------------------------------

class _AlbumResult {
  final String album;
  final String artist;
  final String date;
  final int discNumber;
  final int totalDiscs;
  _AlbumResult({
    required this.album,
    required this.artist,
    required this.date,
    required this.discNumber,
    required this.totalDiscs,
  });
}

class _AlbumEditDialog extends StatefulWidget {
  final String album;
  final String artist;
  final String date;
  final int discNumber;
  final int totalDiscs;
  const _AlbumEditDialog({
    required this.album,
    required this.artist,
    required this.date,
    required this.discNumber,
    required this.totalDiscs,
  });

  @override
  State<_AlbumEditDialog> createState() => _AlbumEditDialogState();
}

class _AlbumEditDialogState extends State<_AlbumEditDialog> {
  late final TextEditingController _albumCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _dateCtrl;
  late final TextEditingController _discNumberCtrl;
  late final TextEditingController _totalDiscsCtrl;

  @override
  void initState() {
    super.initState();
    _albumCtrl      = TextEditingController(text: widget.album);
    _artistCtrl     = TextEditingController(text: widget.artist);
    _dateCtrl       = TextEditingController(text: widget.date);
    _discNumberCtrl = TextEditingController(
        text: widget.discNumber > 0 ? widget.discNumber.toString() : '');
    _totalDiscsCtrl = TextEditingController(
        text: widget.totalDiscs > 1 ? widget.totalDiscs.toString() : '');
  }

  @override
  void dispose() {
    _albumCtrl.dispose();
    _artistCtrl.dispose();
    _dateCtrl.dispose();
    _discNumberCtrl.dispose();
    _totalDiscsCtrl.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.pop(
        context,
        _AlbumResult(
          album:      _albumCtrl.text.trim(),
          artist:     _artistCtrl.text.trim(),
          date:       _dateCtrl.text.trim(),
          discNumber: int.tryParse(_discNumberCtrl.text.trim()) ?? 0,
          totalDiscs: int.tryParse(_totalDiscsCtrl.text.trim()) ?? 1,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit album info'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_albumCtrl,  'Album title'),
            const SizedBox(height: 12),
            _field(_artistCtrl, 'Album artist'),
            const SizedBox(height: 12),
            _field(_dateCtrl,   'Year'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _field(_discNumberCtrl, 'Disc number',
                  inputType: TextInputType.number)),
              const SizedBox(width: 12),
              Expanded(child: _field(_totalDiscsCtrl, 'Total discs',
                  inputType: TextInputType.number,
                  onSubmit: (_) => _confirm())),
            ]),
            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    TextInputType? inputType,
    ValueChanged<String>? onSubmit,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: inputType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onSubmitted: onSubmit,
    );
  }
}

// ---------------------------------------------------------------------------
// Track edit dialog
// ---------------------------------------------------------------------------

sealed class _TrackResult {}

class _TrackApply extends _TrackResult {
  final String title;
  final String artist;
  _TrackApply({required this.title, required this.artist});
}

class _TrackReset extends _TrackResult {}

class _TrackEditDialog extends StatefulWidget {
  final int number;
  final String title;
  final String artist;
  final String defaultArtist;

  const _TrackEditDialog({
    required this.number,
    required this.title,
    required this.artist,
    required this.defaultArtist,
  });

  @override
  State<_TrackEditDialog> createState() => _TrackEditDialogState();
}

class _TrackEditDialogState extends State<_TrackEditDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl  = TextEditingController(text: widget.title);
    _artistCtrl = TextEditingController(text: widget.artist);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.pop(
        context,
        _TrackApply(
          title:  _titleCtrl.text.trim(),
          artist: _artistCtrl.text.trim(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Edit track ${widget.number}'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _artistCtrl,
              decoration: InputDecoration(
                labelText: 'Artist',
                hintText: widget.defaultArtist,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _confirm(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
          onPressed: () => Navigator.pop(context, _TrackReset()),
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
              onPressed: _confirm,
              child: const Text('Apply'),
            ),
          ],
        ),
      ],
    );
  }
}
