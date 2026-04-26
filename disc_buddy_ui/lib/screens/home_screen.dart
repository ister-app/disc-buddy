import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/drive_list_provider.dart';
import '../widgets/drive_detail_panel.dart';
import '../widgets/drive_list_panel.dart';
import 'settings_screen.dart';

const double _kNarrowBreakpoint = 600;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _kNarrowBreakpoint;
        if (isWide) {
          return _WideLayout(onSettings: _openSettings);
        } else {
          return _NarrowLayout(onSettings: _openSettings);
        }
      },
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }
}

class _WideLayout extends ConsumerWidget {
  final void Function(BuildContext) onSettings;
  const _WideLayout({required this.onSettings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedDriveEntryProvider);
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 300,
            child: DriveListPanel(
              onSettings: () => onSettings(context),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? _EmptyDetailPlaceholder()
                : DriveDetailPanel(entry: selected),
          ),
        ],
      ),
    );
  }
}

class _NarrowLayout extends ConsumerStatefulWidget {
  final void Function(BuildContext) onSettings;
  const _NarrowLayout({required this.onSettings});

  @override
  ConsumerState<_NarrowLayout> createState() => _NarrowLayoutState();
}

class _NarrowLayoutState extends ConsumerState<_NarrowLayout> {
  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedDriveEntryProvider);

    if (selected != null) {
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: () => ref.read(selectedDriveProvider.notifier).state = null,
          ),
          title: Text(selected.displayName),
          titleTextStyle: Theme.of(context).textTheme.titleMedium,
        ),
        body: DriveDetailPanel(entry: selected),
      );
    }

    return Scaffold(
      body: DriveListPanel(
        onSettings: () => widget.onSettings(context),
      ),
    );
  }
}

class _EmptyDetailPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.album_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'Select a drive',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
