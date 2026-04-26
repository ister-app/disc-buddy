import 'dart:io';
import 'dart:isolate';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../models/rip_state.dart';
import '../models/settings.dart';
import 'settings_provider.dart';

// ---------------------------------------------------------------------------
// Isolate message types (all fields must be sendable between isolates)
// ---------------------------------------------------------------------------

sealed class _RipMsg {}

class _RipLog extends _RipMsg {
  final String text;
  final bool isError;
  _RipLog(this.text, {this.isError = false});
}

class _RipProgress extends _RipMsg {
  final Duration elapsed;
  final double speed;
  _RipProgress(this.elapsed, this.speed);
}

class _RipTitleIndex extends _RipMsg {
  final int index;
  _RipTitleIndex(this.index);
}

class _RipDone extends _RipMsg {
  final List<String> files;
  _RipDone(this.files);
}

class _RipFail extends _RipMsg {
  final String error;
  _RipFail(this.error);
}

class _RipCancelPort extends _RipMsg {
  final SendPort port;
  _RipCancelPort(this.port);
}

class _RipCancelled extends _RipMsg {}

class _RipJob {
  final SendPort port;
  final DiscType discType;
  final String discTitle;
  final List<VideoTitle> selectedTitles;
  final Map<String, TitleConfig> configs;
  final RipOptions options;
  final String? mountPath;

  const _RipJob({
    required this.port,
    required this.discType,
    required this.discTitle,
    required this.selectedTitles,
    required this.configs,
    required this.options,
    required this.mountPath,
  });
}

DvdTitle _applyDvdLangOverrides(
  DvdTitle t,
  Map<int, String>? audioOver,
  Map<int, String>? subOver,
) {
  if ((audioOver == null || audioOver.isEmpty) &&
      (subOver == null || subOver.isEmpty)) {
    return t;
  }
  final newAudio = [
    for (var i = 0; i < t.audioTracks.length; i++)
      () {
        final a = t.audioTracks[i];
        final lang = audioOver?[i];
        return lang != null
            ? AudioTrack(index: a.index, streamId: a.streamId, language: lang, codec: a.codec, channels: a.channels)
            : a;
      }(),
  ];
  final newSubs = [
    for (var i = 0; i < t.subtitleTracks.length; i++)
      () {
        final s = t.subtitleTracks[i];
        final lang = subOver?[i];
        return lang != null
            ? SubtitleTrack(index: s.index, streamId: s.streamId, language: lang)
            : s;
      }(),
  ];
  return DvdTitle(
    vtsNumber: t.vtsNumber,
    pgcIndex: t.pgcIndex,
    totalAngles: t.totalAngles,
    duration: t.duration,
    audioTracks: newAudio,
    subtitleTracks: newSubs,
    cells: t.cells,
    chapters: t.chapters,
    clut: t.clut,
    videoHeight: t.videoHeight,
  );
}

BlurayTitle _applyBlurayLangOverrides(
  BlurayTitle t,
  Map<int, String>? audioOver,
  Map<int, String>? subOver,
) {
  if ((audioOver == null || audioOver.isEmpty) &&
      (subOver == null || subOver.isEmpty)) {
    return t;
  }
  final newAudioLangs = [
    for (var i = 0; i < t.audioLangs.length; i++)
      audioOver?[i] ?? t.audioLangs[i],
  ];
  final newSubLangs = [
    for (var i = 0; i < t.subtitleLangs.length; i++)
      subOver?[i] ?? t.subtitleLangs[i],
  ];
  return BlurayTitle(
    index: t.index,
    playlist: t.playlist,
    duration: t.duration,
    audioCount: t.audioCount,
    subtitleCount: t.subtitleCount,
    audioLangs: newAudioLangs,
    subtitleLangs: newSubLangs,
    chapters: t.chapters,
    clipNames: t.clipNames,
    lpcmAudioIndices: t.lpcmAudioIndices,
    audioTitles: t.audioTitles,
    hasHevc: t.hasHevc,
  );
}

// Top-level entry point — runs entirely in the background isolate so that
// blocking FFI calls (DVDReadBlocks) never freeze the UI thread.
void _ripIsolateMain(_RipJob job) async {
  final port = job.port;

  // Set up two-way cancel channel: send our receive-port back to the main isolate.
  Process? currentProcess;
  final cancelReceive = ReceivePort();
  port.send(_RipCancelPort(cancelReceive.sendPort));
  cancelReceive.listen((_) {
    currentProcess?.kill(ProcessSignal.sigkill);
    port.send(_RipCancelled());  // tells main side to close the receive port
    Isolate.exit();
  });

  void trackProcess(Process p) => currentProcess = p;

  try {
    for (int i = 0; i < job.selectedTitles.length; i++) {
      port.send(_RipTitleIndex(i));
      final title = job.selectedTitles[i];
      final config = job.configs[title.displayKey];
      final titleOptions = config == null
          ? job.options
          : job.options.copyWithTrackFilter(
              audioTrackIndices: config.audioIndices,
              subtitleTrackIndices: config.subtitleIndices,
            );

      void log(String msg, {bool isError = false}) {
        if (msg.isEmpty) return;
        port.send(_RipLog(msg, isError: isError));
      }

      void onProgress(FfmpegProgress prog) {
        port.send(_RipProgress(prog.elapsed, prog.speed));
      }

      final aOver = config?.audioLangOverrides;
      final sOver = config?.subtitleLangOverrides;

      if (job.discType == DiscType.dvd) {
        final ripper = DVDRipper(titleOptions, onLog: log, onProgress: onProgress, onFfmpegProcess: trackProcess);
        final dvd = _applyDvdLangOverrides(title as DvdTitle, aOver, sOver);
        await ripper.rip(job.discTitle, [dvd], mountPath: job.mountPath);
      } else if (job.discType == DiscType.bluray) {
        final ripper = BlurayRipper(titleOptions, onLog: log, onProgress: onProgress, onFfmpegProcess: trackProcess);
        final blu = _applyBlurayLangOverrides(title as BlurayTitle, aOver, sOver);
        await ripper.rip(job.discTitle, [blu], mountPath: job.mountPath);
      }

      if (config?.customName?.isNotEmpty == true) {
        final outDirPath = p.join(job.options.outputDir, sanitizeFilename(job.discTitle));
        final expectedName = '${sanitizeFilename(job.discTitle)}-${title.filename}';
        final original = File(p.join(outDirPath, expectedName));
        final renamed = File(
          p.join(outDirPath, '${sanitizeFilename(config!.customName!)}.mkv'),
        );
        if (await original.exists()) await original.rename(renamed.path);
      }
    }

    final outDirPath = p.join(job.options.outputDir, sanitizeFilename(job.discTitle));
    final outDir = Directory(outDirPath);
    final files = outDir.existsSync()
        ? outDir.listSync().whereType<File>()
            .where((f) => f.path.endsWith('.mkv'))
            .map((f) => f.path)
            .toList()
        : <String>[];

    port.send(_RipDone(files));
  } catch (e) {
    port.send(_RipFail(e.toString()));
  }

  Isolate.exit();
}

class RipStateNotifier extends StateNotifier<RipState> {
  final String devicePath;
  final Ref _ref;
  SendPort? _cancelPort;
  Isolate? _spawnedIsolate;
  ReceivePort? _activeReceivePort;

  RipStateNotifier(this.devicePath, this._ref) : super(RipIdle());

  Settings get _settings => _ref.read(settingsProvider);

  void startTitleSelection(String discTitle, List<VideoTitle> titles, Set<String> autoSelected) {
    state = RipTitleSelection(
      discTitle: discTitle,
      titles: titles,
      selectedKeys: autoSelected,
    );
  }

  void toggleTitle(String key) {
    final s = state;
    if (s is! RipTitleSelection) return;
    final keys = Set<String>.from(s.selectedKeys);
    if (keys.contains(key)) {
      keys.remove(key);
    } else {
      keys.add(key);
    }
    state = s.copyWith(selectedKeys: keys);
  }

  void resetToAutoSelect(Set<String> autoSelected) {
    final s = state;
    if (s is! RipTitleSelection) return;
    state = s.copyWith(selectedKeys: autoSelected);
  }

  void selectAll() {
    final s = state;
    if (s is! RipTitleSelection) return;
    state = s.copyWith(selectedKeys: s.titles.map((t) => t.displayKey).toSet());
  }

  void deselectAll() {
    final s = state;
    if (s is! RipTitleSelection) return;
    state = s.copyWith(selectedKeys: const {});
  }

  void updateTitleConfig(String displayKey, TitleConfig? config) {
    final s = state;
    if (s is! RipTitleSelection) return;
    final configs = Map<String, TitleConfig>.from(s.configs);
    if (config == null) {
      configs.remove(displayKey);
    } else {
      configs[displayKey] = config;
    }
    state = s.copyWith(configs: configs);
  }

  void proceedToNaming() {
    final s = state;
    if (s is! RipTitleSelection) return;
    final selected = s.titles.where((t) => s.selectedKeys.contains(t.displayKey)).toList();
    if (selected.isEmpty) return;
    state = RipNamingStep(discTitle: s.discTitle, selectedTitles: selected, configs: s.configs);
  }

  void proceedToSubtitles({String? nameHint, List<int> seasons = const [], bool? autoName, bool? batchAssign}) {
    final s = state;
    if (s is! RipNamingStep) return;
    state = RipSubtitleStep(
      discTitle: s.discTitle,
      selectedTitles: s.selectedTitles,
      configs: s.configs,
      nameHint: nameHint,
      seasons: seasons,
      autoName: autoName,
      batchAssign: batchAssign,
    );
  }

  void skipSubtitles() {
    final s = state;
    if (s is! RipSubtitleStep) return;
    _startRip(
      discTitle: s.discTitle,
      selectedTitles: s.selectedTitles,
      configs: s.configs,
      nameHint: s.nameHint,
      seasons: s.seasons,
      extractSubtitles: false,
      subtitleLangs: '',
      autoName: s.autoName,
      batchAssign: s.batchAssign,
    );
  }

  void startRipFromSubtitleStep({required bool extract, required String langs}) {
    final s = state;
    if (s is! RipSubtitleStep) return;
    _startRip(
      discTitle: s.discTitle,
      selectedTitles: s.selectedTitles,
      configs: s.configs,
      nameHint: s.nameHint,
      seasons: s.seasons,
      extractSubtitles: extract,
      subtitleLangs: langs,
      batchAssign: s.batchAssign,
    );
  }

  void startRipDirect(String discTitle, List<VideoTitle> selected) {
    _startRip(
      discTitle: discTitle,
      selectedTitles: selected,
      configs: const {},
      nameHint: null,
      seasons: const [],
      extractSubtitles: false,
      subtitleLangs: '',
    );
  }

  Future<void> startAudioCdRip(DiscMetadata metadata, List<int> tracks) async {
    final logs = <String>[];
    state = RipAudioCdProgress(metadata: metadata, selectedTracks: tracks);

    final settings = _settings;
    final options = settings.toRipOptions(
      device: devicePath,
      outputDir: settings.effectiveMusicDir,
    );
    final ripper = AudioCDRipper(
      options,
      onLog: (msg, {isError = false}) {
        if (msg.isEmpty) return;
        logs.add(msg);
        final s = state;
        if (s is RipAudioCdProgress) {
          // "── Ripping: track N → …" signals a new track starting.
          final m = RegExp(r'Ripping: track (\d+)').firstMatch(msg);
          if (m != null) {
            final nr  = int.tryParse(m.group(1)!) ?? -1;
            final idx = tracks.indexOf(nr);
            state = s.copyWith(
              currentTrack: idx >= 0 ? idx : s.currentTrack,
              elapsed: Duration.zero,
              speed: 0,
              log: List.from(logs),
            );
          } else {
            state = s.copyWith(log: List.from(logs));
          }
        }
      },
      onProgress: (prog) {
        final s = state;
        if (s is RipAudioCdProgress) {
          state = s.copyWith(elapsed: prog.elapsed, speed: prog.speed);
        }
      },
    );

    try {
      await ripper.rip(metadata, tracks);
      state = RipCompleted([]);
    } catch (e) {
      state = RipError(e.toString());
    }
  }

  Future<void> startMkvProcess({
    required String mkvPath,
    String? newName,
    required bool extractSubtitles,
    required String subtitleLangs,
  }) async {
    final logs = <String>[];

    void appendLog(String msg, {bool isError = false}) {
      if (msg.isEmpty) return;
      logs.add(isError ? '[ERR] $msg' : msg);
      final s = state;
      if (s is MkvProcessing) {
        state = s.copyWith(log: List.from(logs));
      }
    }

    state = MkvProcessing(path: mkvPath);

    try {
      final settings = _settings;
      final srcFile = File(mkvPath);
      final stem = newName?.isNotEmpty == true
          ? newName!
          : p.basenameWithoutExtension(mkvPath);
      final destPath = p.join(settings.effectiveOutputDir, '$stem.mkv');
      final destFile = File(destPath);

      if (mkvPath != destPath) {
        appendLog('Copying to $destPath...');
        await srcFile.copy(destPath);
        appendLog('Done.');
      }

      if (extractSubtitles &&
          settings.mkvextract != null &&
          settings.subtileOcr != null) {
        appendLog('Extracting subtitles...');
        final extractor = SubtitleExtractor(
          ffmpeg: settings.ffmpeg ?? 'ffmpeg',
          ffprobe: settings.ffprobe ?? 'ffprobe',
          mkvextract: settings.mkvextract!,
          subtileOcr: settings.subtileOcr!,
          onLog: appendLog,
        );
        final langs = subtitleLangs.trim().isEmpty
            ? null
            : subtitleLangs.split(RegExp(r'[,\s]+')).toSet();
        await extractor.extractAll(destFile, languages: langs);
        appendLog('Subtitle extraction complete.');
      }

      state = RipCompleted([destPath]);
    } catch (e) {
      state = RipError(e.toString());
    }
  }

  Future<void> startDirProcess({
    required List<String> filePaths,
    required bool extractSubtitles,
    required String subtitleLangs,
    Map<String, String> fileNames = const {},
    bool autoName = false,
    bool batchAssign = false,
    String? nameHint,
    List<int> seasons = const [],
  }) async {
    if (filePaths.isEmpty) return;
    final logs = <String>[];

    void appendLog(String msg, {bool isError = false}) {
      if (msg.isEmpty) return;
      logs.add(isError ? '[ERR] $msg' : msg);
      final s = state;
      if (s is MkvProcessing) state = s.copyWith(log: List.from(logs));
    }

    state = MkvProcessing(path: filePaths.first);

    try {
      final settings = _settings;
      final canExtract = extractSubtitles &&
          settings.mkvextract != null &&
          settings.subtileOcr != null;
      final canAutoName = autoName &&
          settings.llmUrl != null &&
          settings.tmdbToken != null;

      SubtitleExtractor? extractor;
      AutoNamer? namer;

      if (canExtract || canAutoName) {
        extractor = SubtitleExtractor(
          ffmpeg: settings.ffmpeg ?? 'ffmpeg',
          ffprobe: settings.ffprobe ?? 'ffprobe',
          mkvextract: settings.mkvextract ?? 'mkvextract',
          subtileOcr: settings.subtileOcr ?? 'subtile-ocr',
          onLog: appendLog,
        );
      }

      if (canAutoName) {
        namer = AutoNamer(
          extractor: extractor!,
          tmdb: TmdbClient(token: settings.tmdbToken!, onLog: appendLog),
          llm: LlmClient(
            baseUrl: settings.llmUrl!,
            apiKey: settings.llmKey ?? '',
            model: settings.llmModel ?? '',
            onLog: appendLog,
          ),
          force: true,
          batchAssign: batchAssign ? true : false,
          onLog: appendLog,
        );
      }

      final langs = subtitleLangs.trim().isEmpty
          ? null
          : subtitleLangs.split(RegExp(r'[,\s]+')).toSet();

      // Phase 1: resolve names — batch all files needing auto-naming in one call.
      final resolvedStems = <String, String?>{};
      for (final path in filePaths) {
        final custom = fileNames[path];
        resolvedStems[path] = (custom != null && custom.trim().isNotEmpty)
            ? custom.trim()
            : null;
      }

      if (canAutoName) {
        final toName = filePaths
            .where((p) => resolvedStems[p] == null)
            .toList();
        if (toName.isNotEmpty) {
          appendLog('Auto-naming ${toName.length} file(s)...');
          try {
            final items = toName.map((path) {
              final basename = path.split('/').last;
              final stem = basename.toLowerCase().endsWith('.mkv')
                  ? basename.substring(0, basename.length - 4)
                  : basename;
              return (file: File(path), discName: nameHint ?? stem, srts: <File>[]);
            }).toList();

            final batchResults = await namer!.nameFilesBatch(
              items,
              titleHint: nameHint,
              seasonHint: seasons.isNotEmpty ? seasons : null,
            );

            for (final entry in batchResults.entries) {
              resolvedStems[entry.key.path] = entry.value;
            }
          } catch (e) {
            appendLog('Auto-naming failed: $e', isError: true);
          }
        }
      }

      // Phase 2: copy files and extract subtitles.
      final outputFiles = <String>[];

      for (final path in filePaths) {
        final resolvedStem = resolvedStems[path];

        File workingFile;
        if (resolvedStem != null) {
          final destPath = p.join(p.dirname(path), '$resolvedStem.mkv');
          if (destPath != path) {
            appendLog('Renaming to $resolvedStem.mkv...');
            await File(path).rename(destPath);
          }
          workingFile = File(destPath);
          outputFiles.add(destPath);
        } else {
          workingFile = File(path);
          outputFiles.add(path);
        }

        if (canExtract) {
          appendLog('Extracting subtitles: ${workingFile.path.split('/').last}');
          await extractor!.extractAll(workingFile, languages: langs);
        }
      }

      namer?.close();
      state = RipCompleted(outputFiles);
    } catch (e) {
      state = RipError(e.toString());
    }
  }

  void _startRip({
    required String discTitle,
    required List<VideoTitle> selectedTitles,
    required Map<String, TitleConfig> configs,
    required String? nameHint,
    required List<int> seasons,
    required bool extractSubtitles,
    required String subtitleLangs,
    bool? autoName,
    bool? batchAssign,
  }) {
    state = RipInProgress(discTitle: discTitle, selectedTitles: selectedTitles);
    _runRip(
      discTitle: discTitle,
      selectedTitles: selectedTitles,
      configs: configs,
      nameHint: nameHint,
      seasons: seasons,
      extractSubtitles: extractSubtitles,
      subtitleLangs: subtitleLangs,
      autoName: autoName,
      batchAssign: batchAssign,
    );
  }

  Future<void> _runRip({
    required String discTitle,
    required List<VideoTitle> selectedTitles,
    required Map<String, TitleConfig> configs,
    required String? nameHint,
    required List<int> seasons,
    required bool extractSubtitles,
    required String subtitleLangs,
    bool? autoName,
    bool? batchAssign,
  }) async {
    final logs = <String>[];

    void appendLog(String msg, {bool isError = false}) {
      if (msg.isEmpty) return;
      logs.add(isError ? '[ERR] $msg' : msg);
      final s = state;
      if (s is RipInProgress) state = s.copyWith(log: List.from(logs));
    }

    final options = _settings.toRipOptions(device: devicePath).copyWithHints(
      autoName: autoName,
      batchAssign: batchAssign,
      titleHint: autoName != false ? nameHint : null,
      seasonHint: autoName != false && seasons.isNotEmpty ? seasons : null,
    );

    final receivePort = ReceivePort();
    _activeReceivePort = receivePort;

    Future<void> runInIsolate(DiscType discType, {String? mountPath}) async {
      _spawnedIsolate = await Isolate.spawn(
        _ripIsolateMain,
        _RipJob(
          port: receivePort.sendPort,
          discType: discType,
          discTitle: discTitle,
          selectedTitles: selectedTitles,
          configs: configs,
          options: options,
          mountPath: mountPath,
        ),
      );

      await for (final msg in receivePort) {
        switch (msg) {
          case _RipCancelPort(:final port):
            _cancelPort = port;
          case _RipCancelled():
            // Isolate confirmed cancellation: close port and return to idle.
            receivePort.close();
            if (state is RipInProgress) state = RipIdle();
            return;
          case _RipLog(:final text, :final isError):
            appendLog(text, isError: isError);
          case _RipProgress(:final elapsed, :final speed):
            final s = state;
            if (s is RipInProgress) state = s.copyWith(elapsed: elapsed, speed: speed);
          case _RipTitleIndex(:final index):
            final s = state;
            if (s is RipInProgress) {
              state = s.copyWith(currentIndex: index, elapsed: Duration.zero, speed: 0);
            }
          case _RipDone(:final files):
            receivePort.close();
            state = RipCompleted(files);
            return;
          case _RipFail(:final error):
            receivePort.close();
            throw Exception(error);
        }
      }
    }

    try {
      if (devicePath.toLowerCase().endsWith('.iso')) {
        await withMountedDisc(devicePath, (mountPath) async {
          final discType = DiscTypeDetector.detectFromMountPoint(mountPath);
          await runInIsolate(discType, mountPath: mountPath);
        });
      } else {
        final discType = await DiscTypeDetector.detect(devicePath);
        await runInIsolate(discType);
      }
    } catch (e) {
      receivePort.close();
      state = RipError(e.toString());
    }
  }

  void cancel() {
    final s = state;
    if (s is RipInProgress) {
      state = s.copyWith(cancelling: true);
      _cancelPort?.send(null);
      // Fallback: if the isolate is blocked in synchronous FFI (e.g. DVDReadBlocks)
      // the cancel message can't be processed. Force-kill after 3 seconds.
      final capturedPort = _activeReceivePort;
      final capturedIsolate = _spawnedIsolate;
      Future.delayed(const Duration(seconds: 3), () {
        if (state is! RipInProgress) return;
        capturedIsolate?.kill(priority: Isolate.immediate);
        capturedPort?.close();
        if (state is RipInProgress) state = RipIdle();
      });
    }
  }

  void reset() {
    _cancelPort = null;
    _spawnedIsolate = null;
    _activeReceivePort = null;
    state = RipIdle();
  }
}

final ripStateProvider = StateNotifierProvider.family<RipStateNotifier, RipState, String>(
  (ref, device) => RipStateNotifier(device, ref),
);
