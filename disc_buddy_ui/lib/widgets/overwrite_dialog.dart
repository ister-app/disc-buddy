import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

const _compactTextButton = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
  minimumSize: WidgetStatePropertyAll(Size.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// Lists existing output files with checkboxes. Pops with the set of paths
/// to overwrite (empty set = skip all), or null when cancelled.
///
/// Shared by the Audio CD and DVD/Blu-ray rip flows.
class OverwriteDialog extends StatefulWidget {
  final List<String> paths;
  const OverwriteDialog({super.key, required this.paths});

  @override
  State<OverwriteDialog> createState() => _OverwriteDialogState();
}

class _OverwriteDialogState extends State<OverwriteDialog> {
  late final Set<String> _overwrite = Set.of(widget.paths);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Files already exist'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Check the files you want to overwrite; '
                'unchecked files will be skipped.'),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.paths.length,
                itemBuilder: (context, i) {
                  final path = widget.paths[i];
                  return CheckboxListTile(
                    value: _overwrite.contains(path),
                    onChanged: (_) => setState(() {
                      if (!_overwrite.remove(path)) _overwrite.add(path);
                    }),
                    title: Text(p.basename(path),
                        overflow: TextOverflow.ellipsis),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  );
                },
              ),
            ),
            Row(
              children: [
                TextButton(
                  style: _compactTextButton,
                  onPressed: () =>
                      setState(() => _overwrite.addAll(widget.paths)),
                  child: const Text('All'),
                ),
                TextButton(
                  style: _compactTextButton,
                  onPressed: () => setState(_overwrite.clear),
                  child: const Text('None'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, Set.of(_overwrite)),
          child: Text(_overwrite.isEmpty
              ? 'Skip all'
              : 'Overwrite ${_overwrite.length}'),
        ),
      ],
    );
  }
}
