import 'package:disc_buddy/disc_buddy.dart';

sealed class RipState {}

class RipIdle extends RipState {}

/// Per-title configuration set in the "Configure tracks" screen.
class TitleConfig {
  final String? customName;
  final Set<int>? audioIndices;      // null = include all
  final Set<int>? subtitleIndices;   // null = include all
  /// Overrides per track position (0-based); null = keep original language.
  final Map<int, String>? audioLangOverrides;
  final Map<int, String>? subtitleLangOverrides;

  const TitleConfig({
    this.customName,
    this.audioIndices,
    this.subtitleIndices,
    this.audioLangOverrides,
    this.subtitleLangOverrides,
  });
}

class RipTitleSelection extends RipState {
  final String discTitle;
  final List<VideoTitle> titles;
  final Set<String> selectedKeys;
  final Map<String, TitleConfig> configs;  // keyed by displayKey

  RipTitleSelection({
    required this.discTitle,
    required this.titles,
    required this.selectedKeys,
    this.configs = const {},
  });
  RipTitleSelection copyWith({
    Set<String>? selectedKeys,
    Map<String, TitleConfig>? configs,
  }) => RipTitleSelection(
    discTitle: discTitle,
    titles: titles,
    selectedKeys: selectedKeys ?? this.selectedKeys,
    configs: configs ?? this.configs,
  );
}

class RipNamingStep extends RipState {
  final String discTitle;
  final List<VideoTitle> selectedTitles;
  final Map<String, TitleConfig> configs;
  final String? nameHint;
  final List<int> seasons;
  RipNamingStep({
    required this.discTitle,
    required this.selectedTitles,
    this.configs = const {},
    this.nameHint,
    this.seasons = const [],
  });
}

class RipSubtitleStep extends RipState {
  final String discTitle;
  final List<VideoTitle> selectedTitles;
  final Map<String, TitleConfig> configs;
  final String? nameHint;
  final List<int> seasons;
  final bool extractSubtitles;
  final String subtitleLangs;
  /// null = use settings value; non-null = override settings autoName.
  final bool? autoName;
  /// null = use settings value; non-null = override settings batchAssign.
  final bool? batchAssign;
  RipSubtitleStep({
    required this.discTitle,
    required this.selectedTitles,
    this.configs = const {},
    this.nameHint,
    this.seasons = const [],
    this.extractSubtitles = false,
    this.subtitleLangs = '',
    this.autoName,
    this.batchAssign,
  });
}

class RipInProgress extends RipState {
  final String discTitle;
  final List<VideoTitle> selectedTitles;
  final int currentIndex;
  final Duration elapsed;
  final double speed;
  final List<String> log;
  final bool cancelling;
  RipInProgress({
    required this.discTitle,
    required this.selectedTitles,
    this.currentIndex = 0,
    this.elapsed = Duration.zero,
    this.speed = 0,
    this.log = const [],
    this.cancelling = false,
  });
  RipInProgress copyWith({
    int? currentIndex,
    Duration? elapsed,
    double? speed,
    List<String>? log,
    bool? cancelling,
  }) => RipInProgress(
    discTitle: discTitle,
    selectedTitles: selectedTitles,
    currentIndex: currentIndex ?? this.currentIndex,
    elapsed: elapsed ?? this.elapsed,
    speed: speed ?? this.speed,
    log: log ?? this.log,
    cancelling: cancelling ?? this.cancelling,
  );

  double get progressFraction {
    if (selectedTitles.isEmpty) return 0;
    final totalSecs = selectedTitles.fold<int>(0, (s, t) => s + t.duration.inSeconds);
    if (totalSecs == 0) return 0;
    final doneSecs = selectedTitles.take(currentIndex).fold<int>(0, (s, t) => s + t.duration.inSeconds);
    return ((doneSecs + elapsed.inSeconds) / totalSecs).clamp(0.0, 1.0);
  }

  double get currentTitleFraction {
    if (currentIndex >= selectedTitles.length) return 1.0;
    final titleSecs = selectedTitles[currentIndex].duration.inSeconds;
    if (titleSecs == 0) return 0;
    return (elapsed.inSeconds / titleSecs).clamp(0.0, 1.0);
  }
}

class RipAudioCdProgress extends RipState {
  final DiscMetadata metadata;
  final List<int> selectedTracks;
  final int currentTrack;
  final Duration elapsed;
  final double speed;
  final List<String> log;
  RipAudioCdProgress({
    required this.metadata,
    required this.selectedTracks,
    this.currentTrack = 0,
    this.elapsed = Duration.zero,
    this.speed = 0,
    this.log = const [],
  });
  RipAudioCdProgress copyWith({
    int? currentTrack,
    Duration? elapsed,
    double? speed,
    List<String>? log,
  }) => RipAudioCdProgress(
    metadata: metadata,
    selectedTracks: selectedTracks,
    currentTrack: currentTrack ?? this.currentTrack,
    elapsed: elapsed ?? this.elapsed,
    speed: speed ?? this.speed,
    log: log ?? this.log,
  );
}

class MkvProcessing extends RipState {
  final String path;
  final List<String> log;
  MkvProcessing({required this.path, this.log = const []});
  MkvProcessing copyWith({List<String>? log}) =>
      MkvProcessing(path: path, log: log ?? this.log);
}

class RipCompleted extends RipState {
  final List<String> outputFiles;
  RipCompleted(this.outputFiles);
}

class RipError extends RipState {
  final String message;
  RipError(this.message);
}
