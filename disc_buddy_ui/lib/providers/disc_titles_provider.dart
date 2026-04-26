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

Future<DiscContent?> _loadContent(String devicePath, Settings settings) async {
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
    return _loadIsoContent(devicePath, options);
  }

  // Detect disc type for optical drives.
  final discType = await DiscTypeDetector.detect(devicePath);
  return switch (discType) {
    DiscType.audioCD => _loadAudioCD(options),
    DiscType.dvd => _loadVideoDisc(options, DiscType.dvd),
    DiscType.bluray => _loadVideoDisc(options, DiscType.bluray),
    _ => EmptyDisc(),
  };
}

Future<DiscContent?> _loadAudioCD(RipOptions options) async {
  final ripper = AudioCDRipper(options);
  final meta = await ripper.loadMetadata();
  if (meta == null) return null;
  return AudioCdContent(meta);
}

Future<DiscContent?> _loadVideoDisc(RipOptions options, DiscType type) async {
  if (type == DiscType.dvd) {
    final ripper = DVDRipper(options);
    final result = await ripper.loadTitles();
    if (result == null) return null;
    return _buildDvdContent(result.discTitle, result.titles);
  } else {
    final ripper = BlurayRipper(options);
    final result = await ripper.loadTitles();
    if (result == null) return null;
    return _buildBlurayContent(result.discTitle, result.titles);
  }
}

Future<DiscContent?> _loadIsoContent(String isoPath, RipOptions options) async {
  final result = await withMountedDisc<DiscContent?>(isoPath, (mountPath) async {
    final type = DiscTypeDetector.detectFromMountPoint(mountPath);
    final optionsWithMount = RipOptions(
      device: isoPath,
      outputDir: options.outputDir,
      ffmpeg: options.ffmpeg,
      ffprobe: options.ffprobe,
      mkvextract: options.mkvextract,
      subtileOcr: options.subtileOcr,
      tmdbToken: options.tmdbToken,
      llmUrl: options.llmUrl,
      llmKey: options.llmKey,
      llmModel: options.llmModel,
      force: true,
    );
    return switch (type) {
      DiscType.dvd => _loadVideoDiscFromMount(optionsWithMount, mountPath, DiscType.dvd),
      DiscType.bluray => _loadVideoDiscFromMount(optionsWithMount, mountPath, DiscType.bluray),
      _ => null,
    };
  });
  return result;
}

Future<DiscContent?> _loadVideoDiscFromMount(RipOptions options, String mountPath, DiscType type) async {
  if (type == DiscType.dvd) {
    final ripper = DVDRipper(options);
    final result = await ripper.loadTitles(mountPath: mountPath);
    if (result == null) return null;
    return _buildDvdContent(result.discTitle, result.titles);
  } else {
    final ripper = BlurayRipper(options);
    final result = await ripper.loadTitles(mountPath: mountPath);
    if (result == null) return null;
    return _buildBlurayContent(result.discTitle, result.titles);
  }
}

VideoDiscContent _buildDvdContent(String discTitle, List<DvdTitle> raw) {
  final deduped = deduplicateDvdTitles(raw);
  final suggestion = autoSelectDvd(deduped);
  final display = filterDisplayDvdTitles(deduped, suggestion);
  return VideoDiscContent(
    discTitle: discTitle,
    titles: display,
    suggestion: suggestion.map((t) => t.displayKey).toSet(),
    discType: DiscType.dvd,
  );
}

VideoDiscContent _buildBlurayContent(String discTitle, List<BlurayTitle> raw) {
  final suggestion = autoSelectBluray(raw);
  return VideoDiscContent(
    discTitle: discTitle,
    titles: raw,
    suggestion: suggestion.map((t) => t.displayKey).toSet(),
    discType: DiscType.bluray,
  );
}

const _videoExtensions = {
  '.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.m2ts', '.mpg', '.mpeg',
};

DiscContent? _loadDirectory(String dirPath) {
  final files = Directory(dirPath)
      .listSync()
      .whereType<File>()
      .where((f) => _videoExtensions.contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  if (files.isEmpty) return null;
  return DirContent(dirPath: dirPath, files: files);
}
