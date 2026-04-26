import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/rip_state.dart';
import '../providers/rip_state_provider.dart';

class RipProgressPanel extends ConsumerWidget {
  final String devicePath;
  final RipState ripState;

  const RipProgressPanel({
    super.key,
    required this.devicePath,
    required this.ripState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ripState) {
      RipInProgress() => _VideoRipProgress(
          ripState: ripState as RipInProgress,
          onCancel: () => ref.read(ripStateProvider(devicePath).notifier).cancel(),
        ),
      RipAudioCdProgress() => _AudioRipProgress(ripState: ripState as RipAudioCdProgress),
      MkvProcessing() => _MkvProgress(ripState: ripState as MkvProcessing),
      _ => const SizedBox.shrink(),
    };
  }
}

class _VideoRipProgress extends StatelessWidget {
  final RipInProgress ripState;
  final VoidCallback? onCancel;
  const _VideoRipProgress({required this.ripState, this.onCancel});

  @override
  Widget build(BuildContext context) {
    final titles = ripState.selectedTitles;
    final idx = ripState.currentIndex;
    final current = idx < titles.length ? titles[idx] : null;
    final titlePct = (ripState.currentTitleFraction * 100).toStringAsFixed(0);
    final totalPct = (ripState.progressFraction * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('Ripping: ${ripState.discTitle}',
                  style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (ripState.cancelling)
                  Text('Stopping…',
                    style: TextStyle(color: Theme.of(context).colorScheme.error))
                else
                  TextButton.icon(
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('Cancel'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: onCancel,
                  ),
              ]),
              const SizedBox(height: 10),
              // Per-title progress
              if (current != null) ...[
                Row(children: [
                  Text(
                    'Title ${idx + 1}/${titles.length} · ${current.displayKey}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  Text(
                    '$titlePct%  ${_formatElapsed(ripState.elapsed)}  ${ripState.speed.toStringAsFixed(1)}x',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: ripState.currentTitleFraction),
                const SizedBox(height: 10),
              ],
              // Total progress
              Row(children: [
                Text('Total', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                Text('$totalPct%',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  )),
              ]),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: ripState.progressFraction),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _LogView(log: ripState.log)),
      ],
    );
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _AudioRipProgress extends StatelessWidget {
  final RipAudioCdProgress ripState;
  const _AudioRipProgress({required this.ripState});

  @override
  Widget build(BuildContext context) {
    final total = ripState.selectedTracks.length;
    final idx   = ripState.currentTrack;

    final currentNr = idx < ripState.selectedTracks.length
        ? ripState.selectedTracks[idx]
        : null;
    final currentInfo = _findTrack(ripState.metadata.tracks, currentNr);

    final trackSecs    = currentInfo?.duration ?? 0;
    final trackFrac    = trackSecs > 0
        ? (ripState.elapsed.inMilliseconds / (trackSecs * 1000)).clamp(0.0, 1.0)
        : null;
    final overallFrac  = total > 0
        ? ((idx + (trackFrac ?? 0)) / total).clamp(0.0, 1.0)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ripping: ${ripState.metadata.album}',
                  style: Theme.of(context).textTheme.titleLarge),
              Text(ripState.metadata.artist,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 10),
              if (currentInfo != null) ...[
                Row(children: [
                  Expanded(
                    child: Text(
                      'Track ${idx + 1}/$total · ${currentInfo.title}',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_fmt(ripState.elapsed)}  ${ripState.speed.toStringAsFixed(1)}x',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ]),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: trackFrac),
                const SizedBox(height: 10),
              ],
              Row(children: [
                Text('Total', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                Text(
                  '${((overallFrac ?? 0) * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ]),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: overallFrac),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _LogView(log: ripState.log)),
      ],
    );
  }

  static dynamic _findTrack(List<dynamic> tracks, int? nr) {
    if (nr == null) return null;
    for (final t in tracks) {
      if (t.number == nr) return t;
    }
    return null;
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _MkvProgress extends StatelessWidget {
  final MkvProcessing ripState;
  const _MkvProgress({required this.ripState});

  @override
  Widget build(BuildContext context) {
    final filename = ripState.path.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Processing: $filename',
                style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _LogView(log: ripState.log)),
      ],
    );
  }
}

class _LogView extends StatefulWidget {
  final List<String> log;
  const _LogView({required this.log});

  @override
  State<_LogView> createState() => _LogViewState();
}

class _LogViewState extends State<_LogView> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(_LogView old) {
    super.didUpdateWidget(old);
    if (widget.log.length != old.log.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: widget.log.length,
      itemBuilder: (context, i) => Text(
        widget.log[i],
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: widget.log[i].startsWith('[ERR]')
              ? Theme.of(context).colorScheme.error
              : null,
        ),
      ),
    );
  }
}
