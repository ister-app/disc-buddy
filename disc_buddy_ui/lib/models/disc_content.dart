import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart';

sealed class DiscContent {}

class EmptyDisc extends DiscContent {}

class AudioCdContent extends DiscContent {
  final DiscMetadata metadata;

  /// Disc identity at scan time (see readDiscFingerprint); null for
  /// unfingerprintable discs — the pre-rip swap guard is skipped then.
  final String? fingerprint;
  AudioCdContent(this.metadata, {this.fingerprint});
}

class VideoDiscContent extends DiscContent {
  final String discTitle;
  final List<VideoTitle> titles;
  final Set<String> suggestion;
  final DiscType discType;

  /// Display keys of minor clips (see [minorTitleKeys]), collapsed behind the
  /// "Show all" button.  They stay in [titles] and remain selectable.
  final Set<String> minorKeys;

  /// Disc identity at scan time (see readDiscFingerprint); null for ISO
  /// inputs and unfingerprintable discs — the pre-rip swap guard is skipped.
  final String? fingerprint;
  VideoDiscContent({
    required this.discTitle,
    required this.titles,
    required this.suggestion,
    required this.discType,
    this.minorKeys = const {},
    this.fingerprint,
  });
}

class MkvContent extends DiscContent {
  final String path;
  MkvContent(this.path);
}

class DirContent extends DiscContent {
  final String dirPath;
  final List<File> files;
  DirContent({required this.dirPath, required this.files});
}

/// A virtual entry added by the user (ISO file, MKV file, or directory).
sealed class VirtualEntry {}
class IsoEntry extends VirtualEntry {
  final String path;
  IsoEntry(this.path);
  @override String toString() => path;
}
class MkvEntry extends VirtualEntry {
  final String path;
  MkvEntry(this.path);
  @override String toString() => path;
}
class DirEntry extends VirtualEntry {
  final String path;
  DirEntry(this.path);
  @override String toString() => path;
}
