import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

/// Real drives, refreshed on udev block-device events (near-instant reaction
/// to disc insert/eject/swap) with a periodic poll as safety net — tray-status
/// ioctl changes don't always emit udev events.
/// DriveDetector.detect() contains synchronous FFI (CDROM_DRIVE_STATUS ioctl)
/// which can block while drives are under heavy I/O. Running in a background
/// isolate keeps the UI thread responsive during ripping.
final realDrivesProvider = StreamProvider<List<DriveInfo>>((ref) {
  final controller = StreamController<List<DriveInfo>>();
  var refreshing = false;
  var pending = false;

  Future<void> refresh() async {
    // Reentrancy guard: coalesce triggers that arrive during a detect.
    if (refreshing) {
      pending = true;
      return;
    }
    refreshing = true;
    try {
      do {
        pending = false;
        try {
          final drives = await Isolate.run(DriveDetector.detect);
          if (!controller.isClosed) controller.add(drives);
        } catch (e) {
          stderr.writeln('DriveDetector error: $e');
          if (!controller.isClosed) controller.add([]);
        }
      } while (pending);
    } finally {
      refreshing = false;
    }
  }

  Process? monitor;
  Timer? debounce;
  Timer? pollTimer;
  () async {
    try {
      monitor = await Process.start(
          'udevadm', ['monitor', '--udev', '--subsystem-match=block']);
      monitor!.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((_) {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 300), refresh);
      });
      unawaited(monitor!.stderr.drain<void>());
    } catch (_) {
      monitor = null; // no udevadm — polling carries the load alone
    }
    pollTimer = Timer.periodic(
        Duration(seconds: monitor != null ? 5 : 2), (_) => refresh());
  }();
  refresh();

  ref.onDispose(() {
    pollTimer?.cancel();
    debounce?.cancel();
    monitor?.kill();
    controller.close();
  });
  return controller.stream;
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

  void select(String? id) => state = id;
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
