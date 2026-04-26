import 'dart:io';
import 'package:disc_buddy/disc_buddy.dart';

sealed class DiscContent {}

class EmptyDisc extends DiscContent {}

class AudioCdContent extends DiscContent {
  final DiscMetadata metadata;
  AudioCdContent(this.metadata);
}

class VideoDiscContent extends DiscContent {
  final String discTitle;
  final List<VideoTitle> titles;
  final Set<String> suggestion;
  final DiscType discType;
  VideoDiscContent({
    required this.discTitle,
    required this.titles,
    required this.suggestion,
    required this.discType,
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
