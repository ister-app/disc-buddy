import 'dart:io';
import 'dart:isolate';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../models/disc_content.dart';
import '../models/settings.dart';
import 'settings_provider.dart';

/// Loads disc content for a given device path.
/// Returns null if no disc is present or content is empty.
final discTitlesProvider = FutureProvider.family<DiscContent?, String>((ref, devicePath) async {
  // read (not watch): settings only needed once — watching causes a rebuild
  // each time settings load from disk, triggering a double disc scan.
  final settings = ref.read(settingsProvider);
  // Run in a background isolate so blocking FFI (SG_IO ioctl, dvdread) never
  // freezes the UI thread.
  return Isolate.run(() => _loadContent(devicePath, settings));
});

/// Scans [devicePath] and attaches everything the scan logged to the result.
/// A scan that finds nothing still returns an [EmptyDisc], so its log (the
/// reason nothing was found) reaches the UI.
Future<DiscContent?> _loadContent(String devicePath, Settings settings) async {
  final scanLog = <String>[];
  void log(String msg, {bool isError = false}) {
    if (msg.isEmpty) return;
    scanLog.add(isError ? '[ERR] $msg' : msg);
  }

  final content = await _scan(devicePath, settings, log) ?? EmptyDisc();
  return content..scanLog = scanLog;
}

Future<DiscContent?> _scan(
    String devicePath, Settings settings, LogCallback log) async {
  final options = settings.toRipOptions(device: devicePath);

  // Directory of video files.
  if (Directory(devicePath).existsSync()) {
    return _loadDirectory(devicePath);
  }

  // Standalone MKV — no disc scan needed.
  if (devicePath.toLowerCase().endsWith('.mkv')) {
    return MkvContent(devicePath);
  }

  // For ISO files, we need to mount first.
  if (devicePath.toLowerCase().endsWith('.iso')) {
    return _loadIsoContent(devicePath, options, log);
  }

  // Optical drive: never touch the device unless a disc is actually loaded.
  // Everything below opens the device node in blocking mode — dd for the
  // fingerprint, mount and libdvdread for the scan — and the kernel pulls an
  // open tray shut as soon as that happens. Without this guard a rescan
  // triggered right after ejecting (the disc-change watcher fires on exactly
  // that status change) closes the drive again a second after it opened.
  final tray = readDriveStatus(devicePath);
  if (tray == kCdsTrayOpen ||
      tray == kCdsNoDisc ||
      tray == kCdsDriveNotReady) {
    return EmptyDisc();
  }

  // Detect disc type for optical drives.
  final discType = await DiscTypeDetector.detect(devicePath);
  // Capture the disc identity alongside the scan so the pre-rip guard can
  // detect a swap between scanning and ripping.
  final fingerprint = discType == DiscType.unknown
      ? null
      : await readDiscFingerprint(devicePath, discType: discType);
  return switch (discType) {
    DiscType.audioCD => _loadAudioCD(options, fingerprint, log),
    DiscType.dvd => _loadVideoDisc(options, DiscType.dvd, fingerprint, log),
    DiscType.bluray =>
      _loadVideoDisc(options, DiscType.bluray, fingerprint, log),
    _ => EmptyDisc(),
  };
}

Future<DiscContent?> _loadAudioCD(
    RipOptions options, String? fingerprint, LogCallback log) async {
  final ripper = AudioCDRipper(options, onLog: log);
  final meta = await ripper.loadMetadata();
  if (meta == null) return null;
  return AudioCdContent(meta, fingerprint: fingerprint);
}

Future<DiscContent?> _loadVideoDisc(
    RipOptions options, DiscType type, String? fingerprint,
    LogCallback log) async {
  if (type == DiscType.dvd) {
    final ripper = DVDRipper(options, onLog: log);
    final result = await ripper.loadTitles();
    if (result == null) return null;
    return _buildDvdContent(result.discTitle, result.titles,
        fingerprint: fingerprint);
  } else {
    final ripper = BlurayRipper(options, onLog: log);
    final result = await ripper.loadTitles();
    if (result == null) return null;
    return _buildBlurayContent(result.discTitle, result.titles,
        fingerprint: fingerprint);
  }
}

Future<DiscContent?> _loadIsoContent(
    String isoPath, RipOptions options, LogCallback log) async {
  final result = await withMountedDisc<DiscContent?>(isoPath, (mountPath) async {
    final type = DiscTypeDetector.detectFromMountPoint(mountPath);
    return switch (type) {
      DiscType.dvd =>
        _loadVideoDiscFromMount(options, mountPath, DiscType.dvd, log),
      DiscType.bluray =>
        _loadVideoDiscFromMount(options, mountPath, DiscType.bluray, log),
      _ => null,
    };
  }, onLog: log);
  return result;
}

Future<DiscContent?> _loadVideoDiscFromMount(RipOptions options,
    String mountPath, DiscType type, LogCallback log) async {
  if (type == DiscType.dvd) {
    final ripper = DVDRipper(options, onLog: log);
    final result = await ripper.loadTitles(mountPath: mountPath);
    if (result == null) return null;
    return _buildDvdContent(result.discTitle, result.titles);
  } else {
    final ripper = BlurayRipper(options, onLog: log);
    final result = await ripper.loadTitles(mountPath: mountPath);
    if (result == null) return null;
    return _buildBlurayContent(result.discTitle, result.titles);
  }
}

VideoDiscContent _buildDvdContent(String discTitle, List<DvdTitle> raw,
    {String? fingerprint}) {
  final deduped = deduplicateDvdTitles(raw);
  final suggestion = autoSelectDvd(deduped);
  return VideoDiscContent(
    discTitle: discTitle,
    titles: deduped,
    suggestion: suggestion.map((t) => t.displayKey).toSet(),
    minorKeys: minorTitleKeys(deduped, suggestion),
    discType: DiscType.dvd,
    fingerprint: fingerprint,
  );
}

VideoDiscContent _buildBlurayContent(String discTitle, List<BlurayTitle> raw,
    {String? fingerprint}) {
  final suggestion = autoSelectBluray(raw);
  return VideoDiscContent(
    discTitle: discTitle,
    titles: raw,
    suggestion: suggestion.map((t) => t.displayKey).toSet(),
    discType: DiscType.bluray,
    fingerprint: fingerprint,
  );
}

DiscContent? _loadDirectory(String dirPath) {
  final files = Directory(dirPath)
      .listSync()
      .whereType<File>()
      .where((f) => videoExtensions.contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  if (files.isEmpty) return null;
  return DirContent(dirPath: dirPath, files: files);
}
