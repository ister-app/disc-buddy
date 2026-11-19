import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers/prompt_provider.dart';

/// Shows the questions in [promptQueueProvider] as dialogs, one at a time,
/// on top of [child].
class PromptHost extends ConsumerStatefulWidget {
  final Widget child;
  const PromptHost({super.key, required this.child});

  @override
  ConsumerState<PromptHost> createState() => _PromptHostState();
}

class _PromptHostState extends ConsumerState<PromptHost> {
  bool _showing = false;

  Future<void> _pump() async {
    if (_showing || !mounted) return;
    final queue = ref.read(promptQueueProvider);
    if (queue.isEmpty) return;
    final request = queue.first;
    _showing = true;
    Object? answer;
    try {
      answer = await showDialog<Object?>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PromptDialog(request: request),
      );
    } finally {
      _showing = false;
    }
    if (!mounted) return;
    // Resolving shrinks the queue, which re-enters _pump for the next one.
    ref.read(promptQueueProvider.notifier).resolve(request, answer);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(promptQueueProvider, (_, _) => _pump());
    return widget.child;
  }
}

class _PromptDialog extends StatelessWidget {
  final PromptRequest request;
  const _PromptDialog({required this.request});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = request.options;
    return AlertDialog(
      title: Text(request.question, style: theme.textTheme.titleMedium),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (request.context.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  request.context.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (options != null)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (ctx, i) => ListTile(
                    dense: true,
                    selected: i == request.defaultIndex,
                    leading: Text('${i + 1}'),
                    title: Text(options[i]),
                    onTap: () => Navigator.of(ctx).pop(i),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: options != null
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Skip'),
              ),
              if (request.defaultIndex != null)
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(request.defaultIndex),
                  child: Text('Use ${request.defaultIndex! + 1}'),
                ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('No'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Yes'),
              ),
            ],
    );
  }
}
