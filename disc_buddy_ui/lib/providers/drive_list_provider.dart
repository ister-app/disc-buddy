import 'dart:async';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/disc_content.dart';

/// Combined drive entry: either a real optical drive or a user-added virtual file.
sealed class DriveEntry {
  String get id;
  String get displayName;
}

class RealDriveEntry extends DriveEntry {
  final DriveInfo info;
  RealDriveEntry(this.info);
  @override String get id => info.device;
  @override String get displayName => info.displayModel;
}

class VirtualFileEntry extends DriveEntry {
  final VirtualEntry entry;
  VirtualFileEntry(this.entry);
  @override String get id => entry.toString();
  @override String get displayName => switch (entry) {
    IsoEntry(:final path) => path.split('/').last,
    MkvEntry(:final path) => path.split('/').last,
    DirEntry(:final path) => path.split('/').last,
  };
}

/// Holds user-added virtual file entries (ISOs, MKVs).
class VirtualEntriesNotifier extends Notifier<List<VirtualEntry>> {
  @override
  List<VirtualEntry> build() => [];

  void addIso(String path) {
    if (state.any((e) => e is IsoEntry && e.path == path)) return;
    state = [...state, IsoEntry(path)];
  }

  void addMkv(String path) {
    if (state.any((e) => e is MkvEntry && e.path == path)) return;
    state = [...state, MkvEntry(path)];
  }

  void addDir(String path) {
    if (state.any((e) => e is DirEntry && e.path == path)) return;
    state = [...state, DirEntry(path)];
  }

  void remove(String path) {
    state = state.where((e) => e.toString() != path).toList();
  }
}

final virtualEntriesProvider = NotifierProvider<VirtualEntriesNotifier, List<VirtualEntry>>(
  VirtualEntriesNotifier.new,
);

/// Real drives polled every 2 seconds.
final realDrivesProvider = StreamProvider<List<DriveInfo>>((ref) async* {
  while (true) {
    try {
      final drives = await DriveDetector.detect();
      yield drives;
    } catch (_) {
      yield [];
    }
    await Future.delayed(const Duration(seconds: 2));
  }
});

/// Combined list of all drive entries (real + virtual).
final driveListProvider = Provider<AsyncValue<List<DriveEntry>>>((ref) {
  final realAsync = ref.watch(realDrivesProvider);
  final virtual = ref.watch(virtualEntriesProvider);
  return realAsync.whenData((drives) => [
    ...drives.map(RealDriveEntry.new),
    ...virtual.map(VirtualFileEntry.new),
  ]);
});

class _SelectedDriveNotifier extends Notifier<String?> {
  @override
  String? build() => null;
}

/// ID of the currently selected drive entry.
final selectedDriveProvider = NotifierProvider<_SelectedDriveNotifier, String?>(
  _SelectedDriveNotifier.new,
);

/// Always-fresh entry for the selected drive ID, derived from the live drive list.
final selectedDriveEntryProvider = Provider<DriveEntry?>((ref) {
  final selectedId = ref.watch(selectedDriveProvider);
  if (selectedId == null) return null;
  final entries = ref.watch(driveListProvider).value ?? [];
  for (final e in entries) {
    if (e.id == selectedId) return e;
  }
  return null;
});
