import 'dart:io';
import 'dart:isolate';
import 'package:disc_buddy/disc_buddy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../models/disc_content.dart';
import '../models/rip_state.dart';
import '../models/settings.dart';
import 'disc_titles_provider.dart';
import 'prompt_provider.dart';
import 'settings_provider.dart';

/// Runs the disc-swap check in a short-lived isolate (the audio path uses a
/// blocking SG_IO ioctl). Top-level so the Isolate.run closure captures only
/// these sendable parameters — inside a RipStateNotifier method it would
/// capture `this`, whose ReceivePort cannot cross an isolate boundary.
Future<void> _verifyDiscInIsolate(
    String device, String fingerprint, DiscType discType) {
  return Isolate.run(
      () => verifyDiscUnchanged(device, fingerprint, discType: discType));
}

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
  final List<String> failed; // display keys of titles that did not rip
  _RipDone(this.files, this.failed);
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
  final Set<String>? overwrite;

  const _RipJob({
    required this.port,
    required this.discType,
    required this.discTitle,
    required this.selectedTitles,
    required this.configs,
    required this.options,
    required this.mountPath,
    this.overwrite,
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
    pgcCount: t.pgcCount,
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

/// The choices of the naming and subtitle steps, kept so that loop mode rips
/// the next disc of a set the same way as the one the user configured.
typedef _RipChoices = ({
  String? nameHint,
  List<int> seasons,
  bool extractSubtitles,
  String subtitleLangs,
  bool? autoName,
  bool? batchAssign,
});

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
  final failedKeys = <String>{};
  // Left alone because the output exists and nobody agreed to replace it
  // (loop mode: no overwrite dialog). Not this job's files either.
  final skippedKeys = <String>{};

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
        if (title is! DvdTitle) throw StateError('Expected DvdTitle but got ${title.runtimeType}');
        final ripper = DVDRipper(titleOptions, onLog: log, onProgress: onProgress, onFfmpegProcess: trackProcess);
        final dvd = _applyDvdLangOverrides(title, aOver, sOver);
        await ripper.rip(job.discTitle, [dvd],
            mountPath: job.mountPath, overwrite: job.overwrite);
        failedKeys.addAll(ripper.failedTitleKeys);
        skippedKeys.addAll(ripper.skippedTitleKeys);
      } else if (job.discType == DiscType.bluray) {
        if (title is! BlurayTitle) throw StateError('Expected BlurayTitle but got ${title.runtimeType}');
        final ripper = BlurayRipper(titleOptions, onLog: log, onProgress: onProgress, onFfmpegProcess: trackProcess);
        final blu = _applyBlurayLangOverrides(title, aOver, sOver);
        await ripper.rip(job.discTitle, [blu],
            mountPath: job.mountPath, overwrite: job.overwrite);
        failedKeys.addAll(ripper.failedTitleKeys);
        skippedKeys.addAll(ripper.skippedTitleKeys);
      }

    }

    // Report this job's own outputs (not every MKV that happens to be in the
    // directory): the main isolate extracts subtitles from, names and
    // renames exactly these.
    // A failed re-rip leaves the previous file in place, so "exists" alone
    // would hand that stale file to the post-processing as if it were new.
    final files = [
      for (final title in job.selectedTitles)
        if (!failedKeys.contains(title.displayKey) &&
            !skippedKeys.contains(title.displayKey) &&
            File(videoTitleOutputPath(job.options.outputDir, job.discTitle, title))
                .existsSync())
          videoTitleOutputPath(job.options.outputDir, job.discTitle, title),
    ];
    if (failedKeys.isNotEmpty) {
      port.send(_RipLog(
          '${failedKeys.length} of ${job.selectedTitles.length} title(s) were '
          'not ripped: ${failedKeys.join(', ')}',
          isError: true));
    }

    port.send(_RipDone(files, [
      ...failedKeys,
      for (final k in skippedKeys) '$k (output already exists)',
    ]));
  } catch (e) {
    port.send(_RipFail(e.toString()));
  }

  Isolate.exit();
}

class RipStateNotifier extends Notifier<RipState> {
  final String devicePath;
  SendPort? _cancelPort;
  Isolate? _spawnedIsolate;
  ReceivePort? _activeReceivePort;

  /// Video rips are numbered so a cancel can be tied to the rip it was meant
  /// for: the Cancel button is live from the moment the state turns to
  /// RipInProgress, well before the isolate (and its cancel port) exists.
  int _jobSeq = 0;
  int _cancelledJob = 0;

  /// `.part` files the running video rip may leave behind when it is killed.
  List<String> _jobParts = const [];
  AudioCDRipper? _audioRipper;
  _RipChoices? _lastChoices;
  bool _disposed = false;

  RipStateNotifier(this.devicePath);

  @override
  RipState build() {
    // The provider can be disposed mid-rip (e.g. the drive is removed and its
    // entry disappears). Writing `state` on a disposed Notifier throws, so any
    // write after an async gap or from an isolate callback must go through
    // [_emit], which drops the write once disposed.
    ref.onDispose(() => _disposed = true);
    return RipIdle();
  }

  /// Guarded state write — a no-op after the notifier has been disposed.
  void _emit(RipState s) {
    if (_disposed) return;
    state = s;
  }

  // Cap retained log lines so a multi-hour rip doesn't grow the buffer (and the
  // O(n) per-append copy into state) without bound.
  static const _maxLogLines = 2000;
  static void _capLog(List<String> logs) {
    if (logs.length > _maxLogLines) {
      logs.removeRange(0, logs.length - _maxLogLines);
    }
  }

  Settings get _settings => ref.read(settingsProvider);

  /// What the scan of this disc logged; a rip log starts with it so metadata
  /// lookups and scan warnings sit next to the rip they led to.
  List<String> get _scanLog =>
      ref.read(discTitlesProvider(devicePath)).value?.scanLog ?? const [];

  void startTitleSelection(String discTitle, List<VideoTitle> titles, Set<String> autoSelected,
      {String? fingerprint}) {
    state = RipTitleSelection(
      discTitle: discTitle,
      titles: titles,
      selectedKeys: autoSelected,
      scanFingerprint: fingerprint,
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

  /// Selects [keys], or every title when omitted.  The caller passes the keys
  /// it currently shows, so "All" never selects a collapsed minor clip.
  void selectAll([Iterable<String>? keys]) {
    final s = state;
    if (s is! RipTitleSelection) return;
    state = s.copyWith(
        selectedKeys: (keys ?? s.titles.map((t) => t.displayKey)).toSet());
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
    state = RipNamingStep(discTitle: s.discTitle, selectedTitles: selected, configs: s.configs,
        scanFingerprint: s.scanFingerprint);
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
      scanFingerprint: s.scanFingerprint,
    );
  }

  void skipSubtitles({Set<String>? overwrite}) {
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
      overwrite: overwrite,
      scanFingerprint: s.scanFingerprint,
    );
  }

  void startRipFromSubtitleStep(
      {required bool extract, required String langs, Set<String>? overwrite}) {
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
      autoName: s.autoName,
      batchAssign: s.batchAssign,
      overwrite: overwrite,
      scanFingerprint: s.scanFingerprint,
    );
  }

  void startRipDirect(String discTitle, List<VideoTitle> selected,
      {String? fingerprint}) {
    // Loop mode starts here without the naming/subtitle steps: the next
    // disc of a set gets the choices made for the previous one.
    final last = _lastChoices;
    _startRip(
      discTitle: discTitle,
      selectedTitles: selected,
      configs: const {},
      nameHint: last?.nameHint,
      seasons: last?.seasons ?? const [],
      extractSubtitles: last?.extractSubtitles ?? false,
      subtitleLangs: last?.subtitleLangs ?? '',
      autoName: last?.autoName,
      batchAssign: last?.batchAssign,
      scanFingerprint: fingerprint,
    );
  }

  Future<void> startAudioCdRip(
    DiscMetadata metadata,
    List<int> tracks, {
    Set<String>? overwrite,
    String? scanFingerprint,
  }) async {
    // Guard: refuse if the disc was swapped between scan and rip.
    if (devicePath.startsWith('/dev/') && scanFingerprint != null) {
      try {
        await _verifyDiscInIsolate(
            devicePath, scanFingerprint, DiscType.audioCD);
      } on DiscChangedException catch (e) {
        _discMismatch(e);
        return;
      }
    }

    final logs = <String>[..._scanLog];
    state = RipAudioCdProgress(
        metadata: metadata, selectedTracks: tracks, log: List.from(logs));

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
        _capLog(logs);
        final s = state;
        if (s is RipAudioCdProgress) {
          // "── Ripping: track N → …" signals a new track starting.
          final m = RegExp(r'Ripping: track (\d+)').firstMatch(msg);
          if (m != null) {
            final nr  = int.tryParse(m.group(1)!) ?? -1;
            final idx = tracks.indexOf(nr);
            _emit(s.copyWith(
              currentTrack: idx >= 0 ? idx : s.currentTrack,
              elapsed: Duration.zero,
              speed: 0,
              log: List.from(logs),
            ));
          } else {
            _emit(s.copyWith(log: List.from(logs)));
          }
        }
      },
      onProgress: (prog) {
        final s = state;
        if (s is RipAudioCdProgress) {
          _emit(s.copyWith(elapsed: prog.elapsed, speed: prog.speed));
        }
      },
    );

    _audioRipper = ripper;
    try {
      await ripper.rip(metadata, tracks, overwrite: overwrite);
      final failed = [for (final nr in ripper.failedTracks) 'track $nr'];
      if (ripper.cancelled) {
        // Finished tracks stay on disk; the interrupted one was cleaned up.
        if (state is RipAudioCdProgress) _emit(RipIdle());
      } else if (failed.isEmpty &&
          ref.read(loopEnabledProvider(devicePath)) &&
          devicePath.startsWith('/dev/')) {
        await Process.run('eject', [devicePath]);
        _emit(LoopWaiting(lastOutputFiles: [], log: List.from(logs)));
      } else {
        _emit(RipCompleted([], log: List.from(logs), failed: failed));
      }
    } catch (e) {
      _emit(RipError(e.toString()));
    } finally {
      if (identical(_audioRipper, ripper)) _audioRipper = null;
    }
  }

  /// Copies a standalone MKV into the video directory and post-processes
  /// the copy. With [autoName] the copy keeps the source's name until the
  /// namer has identified it, and [newName]/[seasons] are hints for the
  /// namer; without it [newName] is simply the new file name.
  Future<void> startMkvProcess({
    required String mkvPath,
    String? newName,
    required bool extractSubtitles,
    required String subtitleLangs,
    bool autoName = false,
    List<int> seasons = const [],
  }) async {
    final logs = <String>[];

    void appendLog(String msg, {bool isError = false}) {
      if (msg.isEmpty) return;
      logs.add(isError ? '[ERR] $msg' : msg);
      _capLog(logs);
      final s = state;
      if (s is MkvProcessing) {
        _emit(s.copyWith(log: List.from(logs)));
      }
    }

    state = MkvProcessing(path: mkvPath);

    try {
      final settings = _settings;
      final srcFile = File(mkvPath);
      final typed = newName?.trim() ?? '';
      final stem = !autoName && typed.isNotEmpty
          ? sanitizeFilename(typed)
          : p.basenameWithoutExtension(mkvPath);
      final destPath = p.join(settings.effectiveOutputDir, '$stem.mkv');
      final destFile = File(destPath);

      if (!p.equals(mkvPath, destPath)) {
        // File.copy replaces an existing file without asking.
        final sameCopy = autoName &&
            await destFile.exists() &&
            await destFile.length() == await srcFile.length();
        if (sameCopy) {
          // Left by an earlier attempt whose naming did not succeed.
          appendLog('Using the existing copy $destPath.');
        } else if (await destFile.exists()) {
          _emit(RipError(autoName
              ? '$destPath already exists — remove it, or turn Auto name '
                  'off and choose another name.'
              : '$destPath already exists — choose another name.'));
          return;
        }
        await destFile.parent.create(recursive: true);
        appendLog('Copying to $destPath...');
        await srcFile.copy(destPath);
        appendLog('Done.');
      }

      final outputs = await _postProcess(
        files: [destPath],
        log: appendLog,
        extractSubtitles: extractSubtitles,
        subtitleLangs: subtitleLangs,
        autoName: autoName,
        nameHint: autoName && typed.isNotEmpty ? typed : null,
        seasons: seasons,
      );
      _emit(RipCompleted(outputs, log: List.from(logs)));
    } catch (e) {
      _emit(RipError(e.toString()));
    }
  }

  Future<void> startDirProcess({
    required List<String> filePaths,
    required bool extractSubtitles,
    required String subtitleLangs,
    Map<String, String> fileNames = const {},
    bool autoName = false,
    bool batchAssign = false,
    bool splitStories = false,
    String? nameHint,
    List<int> seasons = const [],
  }) async {
    if (filePaths.isEmpty) return;
    final logs = <String>[];

    void appendLog(String msg, {bool isError = false}) {
      if (msg.isEmpty) return;
      logs.add(isError ? '[ERR] $msg' : msg);
      _capLog(logs);
      final s = state;
      if (s is MkvProcessing) _emit(s.copyWith(log: List.from(logs)));
    }

    state = MkvProcessing(path: filePaths.first);

    try {
      final outputFiles = await _postProcess(
        files: filePaths,
        log: appendLog,
        extractSubtitles: extractSubtitles,
        subtitleLangs: subtitleLangs,
        autoName: autoName,
        batchAssign: batchAssign,
        splitStories: splitStories,
        nameHint: nameHint,
        seasons: seasons,
        stems: fileNames,
      );
      _emit(RipCompleted(outputFiles, log: List.from(logs)));
    } catch (e) {
      _emit(RipError(e.toString()));
    }
  }

  /// Subtitle extraction, auto-naming and renaming for files that are
  /// already on disk — directory mode, and the tail of a disc rip.
  ///
  /// [stems] maps a path to the name the user typed for it; such a file is
  /// renamed to that and never auto-named. A rename may replace an existing
  /// file only when that file's path is in [replaceTargets] (the user ticked
  /// it in the overwrite dialog) and this run did not just produce it; any
  /// other rename onto an existing file is refused. [discName] is what the namer
  /// falls back to as a title hint (defaults to each file's own stem).
  /// Subtitles are extracted first so the namer reuses them and the rename
  /// takes the SRT sidecars along. Returns the final paths in [files] order.
  ///
  /// With [splitStories] every file to auto-name is first cut in two at the
  /// black frame nearest its middle (`StorySplitter`) and the halves are
  /// named separately; `applySplitNames` then decides whether the halves
  /// replace the file or it stays whole — the CLI's `--split-stories`.
  Future<List<String>> _postProcess({
    required List<String> files,
    required LogCallback log,
    required bool extractSubtitles,
    required String subtitleLangs,
    required bool autoName,
    bool batchAssign = false,
    bool splitStories = false,
    String? nameHint,
    List<int> seasons = const [],
    Map<String, String> stems = const {},
    Set<String> replaceTargets = const {},
    String? discName,
  }) async {
    final options = _settings.toRipOptions(device: devicePath);

    // The namer's questions (a tie between candidates, an episode the LLM
    // could not place) go to a dialog. A loop rip runs unattended and must
    // not wait for one, so it keeps the defaults.
    final recent = <String>[];
    final userLog = log;
    log = (String msg, {bool isError = false}) {
      if (msg.trim().isNotEmpty) {
        recent.add(msg.trim());
        if (recent.length > 4) recent.removeAt(0);
      }
      userLog(msg, isError: isError);
    };
    final unattended = ref.read(loopEnabledProvider(devicePath));
    final Prompter prompter = unattended
        ? const NonInteractivePrompter()
        : DialogPrompter(ref.read(promptQueueProvider.notifier),
            context: () => List.of(recent));

    // Availability as the panels show it: a configured path, or the default
    // command on PATH. (RipOptions.canOcrSubtitles only knows configured
    // paths, so tools found on PATH would be offered and then never run.)
    final ocrOk = ref.read(subtitleToolsAvailableProvider);
    final whisperOk = ref.read(whisperAvailableProvider);
    final wantExtract = extractSubtitles && ocrOk;
    if (extractSubtitles && !wantExtract) {
      log('Subtitle extraction skipped: mkvextract and subtile-ocr were not '
          'found (see Settings).', isError: true);
    }
    final wantNaming = autoName &&
        options.tmdbToken != null &&
        options.llmUrl != null &&
        options.llmModel != null &&
        (ocrOk || whisperOk);
    if (autoName && !wantNaming) {
      log('Auto-naming skipped: it needs a TMDB token, an LLM URL and model, '
          'and either the subtitle OCR tools or whisper (see Settings).',
          isError: true);
    }

    // path → new stem
    final resolved = <String, String>{
      for (final e in stems.entries)
        if (e.value.trim().isNotEmpty) e.key: sanitizeFilename(e.value.trim()),
    };
    final toName = wantNaming
        ? files.where((f) => !resolved.containsKey(f)).toList()
        : const <String>[];

    // source path → its two halves
    final splits = <String, StorySplit>{};
    // path of a half → the stem the namer gave it
    final halfStems = <String, String?>{};

    if (wantExtract || toName.isNotEmpty) {
      if (splitStories) {
        final splitter = StorySplitter(
            ffmpeg: options.ffmpeg, ffprobe: options.ffprobe, onLog: log);
        for (final path in toName) {
          log('Splitting stories: ${p.basename(path)}');
          final split = await splitter.split(File(path));
          if (split != null) splits[path] = split;
        }
      }

      final extractor = SubtitleExtractor(
        ffmpeg: options.ffmpeg,
        ffprobe: options.ffprobe,
        // May run without the OCR tools (whisper-only auto-naming).
        mkvextract: options.mkvextract ?? 'mkvextract',
        subtileOcr: options.subtileOcr ?? 'subtile-ocr',
        onLog: log,
      );

      if (wantExtract) {
        final langs = subtitleLangs.trim().isEmpty
            ? null
            : subtitleLangs.trim().split(RegExp(r'[,\s]+')).toSet();
        // A split file's subtitles are extracted per story: the stories
        // are what remains when the split is kept.
        for (final path in files) {
          final split = splits[path];
          for (final f in split == null
              ? [File(path)]
              : [split.first, split.second]) {
            log('Extracting subtitles: ${p.basename(f.path)}');
            await extractor.extractAll(f, languages: langs);
          }
        }
      }

      if (toName.isNotEmpty) {
        log('Auto-naming ${toName.length} file(s)...');
        final namer = AutoNamer(
          extractor: extractor,
          transcriber: whisperOk
              ? Transcriber(
                  ffmpeg: options.ffmpeg,
                  ffprobe: options.ffprobe,
                  whisperCli: options.whisper ?? 'whisper-cli',
                  whisperModel: options.whisperModel!,
                  language: options.transcribeLanguage,
                  onLog: log,
                )
              : null,
          tmdb: TmdbClient(token: options.tmdbToken!, onLog: log),
          llm: LlmClient(
            baseUrl: options.llmUrl!,
            apiKey: options.llmKey ?? '',
            model: options.llmModel!,
            onLog: log,
          ),
          prompter: prompter,
          batchAssign: batchAssign,
          onLog: log,
        );
        try {
          final results = await namer.nameFilesBatch(
            [
              for (final path in toName)
                for (final f in splits[path] == null
                    ? [File(path)]
                    : [splits[path]!.first, splits[path]!.second])
                  (
                    file: f,
                    discName: nameHint ??
                        discName ??
                        p.basenameWithoutExtension(path),
                    srts: extractor.findExistingSrts(f),
                  ),
            ],
            titleHint: nameHint,
            seasonHint: seasons.isNotEmpty ? seasons : null,
            splitFrom: {
              for (final split in splits.values) ...{
                split.first: split.source,
                split.second: split.source,
              },
            },
          );
          for (final e in results.entries) {
            final stem = e.value;
            if (!toName.contains(e.key.path)) {
              halfStems[e.key.path] = stem; // one half of a split file
            } else if (stem != null) {
              resolved[e.key.path] = stem;
            }
          }
        } catch (e) {
          log('Auto-naming failed: $e', isError: true);
        } finally {
          namer.close();
        }
      }
    }

    // Park every split source first: a story's new name may be the current
    // name of another source that is still waiting its turn.
    for (final path in splits.keys.toList()) {
      splits[path] = await parkSource(splits[path]!);
    }
    final unsettled = <String>[];

    final out = <String>[];
    for (final path in files) {
      final split = splits[path];
      if (split != null) {
        final first = halfStems[split.first.path];
        final second = halfStems[split.second.path];
        final settled = await applySplitNames(split, first, second,
            originalStem: p.basenameWithoutExtension(path), onLog: log);
        if (!settled) {
          unsettled.add(path);
          out.add(path);
        } else {
          final ext = p.extension(path);
          out.addAll({
            p.join(p.dirname(path), '$first$ext'),
            p.join(p.dirname(path), '$second$ext'),
          });
        }
        continue;
      }
      final stem = resolved[path];
      if (stem != null) {
        final target =
            File(p.join(p.dirname(path), '$stem${p.extension(path)}'));
        final approved =
            replaceTargets.any((t) => p.equals(t, target.path));
        final ours = out.any((o) => p.equals(o, target.path));
        if (approved &&
            !ours &&
            !p.equals(target.path, path) &&
            await target.exists()) {
          log('Replacing ${target.path}');
          await target.delete();
        }
      }
      // renameWithSidecars refuses to overwrite an existing file and keeps
      // the extension; the file stays where it is when the rename is refused.
      final renamed = stem != null &&
          await renameWithSidecars(File(path), stem, onLog: log);
      out.add(renamed
          ? p.join(p.dirname(path), '$stem${p.extension(path)}')
          : path);
    }
    // Only now give unsettled sources their own name back, so it could not
    // block a story that wanted it.
    for (final path in unsettled) {
      await unparkSource(splits[path]!,
          originalStem: p.basenameWithoutExtension(path), onLog: log);
    }
    return out;
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
    Set<String>? overwrite,
    String? scanFingerprint,
  }) {
    _lastChoices = (
      nameHint: nameHint,
      seasons: seasons,
      extractSubtitles: extractSubtitles,
      subtitleLangs: subtitleLangs,
      autoName: autoName,
      batchAssign: batchAssign,
    );
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
      overwrite: overwrite,
      scanFingerprint: scanFingerprint,
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
    Set<String>? overwrite,
    String? scanFingerprint,
  }) async {
    final logs = <String>[..._scanLog];

    void appendLog(String msg, {bool isError = false}) {
      if (msg.isEmpty) return;
      logs.add(isError ? '[ERR] $msg' : msg);
      _capLog(logs);
      final s = state;
      if (s is RipInProgress) _emit(s.copyWith(log: List.from(logs)));
    }

    final options = _settings.toRipOptions(device: devicePath).copyWithHints(
      autoName: autoName,
      batchAssign: batchAssign,
      titleHint: autoName != false ? nameHint : null,
      seasonHint: autoName != false && seasons.isNotEmpty ? seasons : null,
    );

    final job = ++_jobSeq;
    // True once this rip was cancelled, or replaced by a newer one.
    bool abandoned() => _cancelledJob >= job || _jobSeq != job;
    _cancelPort = null;
    _spawnedIsolate = null;
    _jobParts = [
      for (final t in selectedTitles)
        partPath(videoTitleOutputPath(options.outputDir, discTitle, t)),
    ];

    final receivePort = ReceivePort();
    _activeReceivePort = receivePort;

    var failedTitles = const <String>[];

    // Completes with this job's output files, or null when it was cancelled.
    Future<List<String>?> runInIsolate(DiscType discType,
        {String? mountPath}) async {
      // Cancelled while the disc was still being detected, verified or
      // mounted: do not start a rip nobody is watching.
      if (abandoned()) {
        receivePort.close();
        return null;
      }
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
          overwrite: overwrite,
        ),
      );

      await for (final msg in receivePort) {
        switch (msg) {
          case _RipCancelPort(:final port):
            _cancelPort = port;
            // A cancel that arrived before the isolate could listen.
            if (abandoned()) port.send(null);
          case _RipCancelled():
            // Isolate confirmed cancellation: close port and return to idle.
            receivePort.close();
            await _deleteParts(_jobParts);
            if (_jobSeq == job && state is RipInProgress) _emit(RipIdle());
            return null;
          case _RipLog(:final text, :final isError):
            appendLog(text, isError: isError);
          case _RipProgress(:final elapsed, :final speed):
            final s = state;
            if (s is RipInProgress) _emit(s.copyWith(elapsed: elapsed, speed: speed));
          case _RipTitleIndex(:final index):
            final s = state;
            if (s is RipInProgress) {
              _emit(s.copyWith(currentIndex: index, elapsed: Duration.zero, speed: 0));
            }
          case _RipDone(:final files, :final failed):
            failedTitles = failed;
            receivePort.close();
            return files;
          case _RipFail(:final error):
            receivePort.close();
            throw Exception(error);
        }
      }
      return null; // port closed by the cancel fallback
    }

    List<String>? files;
    try {
      if (devicePath.toLowerCase().endsWith('.iso')) {
        files = await withMountedDisc(devicePath, (mountPath) async {
          final discType = DiscTypeDetector.detectFromMountPoint(mountPath);
          return runInIsolate(discType, mountPath: mountPath);
        });
      } else {
        final discType = await DiscTypeDetector.detect(devicePath);
        // Guard: the titles being ripped were parsed at scan time — refuse if
        // the disc has been swapped since (their cell/playlist data would be
        // applied to the wrong disc).
        if (devicePath.startsWith('/dev/') && scanFingerprint != null) {
          try {
            await _verifyDiscInIsolate(devicePath, scanFingerprint, discType);
          } on DiscChangedException catch (e) {
            receivePort.close();
            if (!abandoned()) _discMismatch(e);
            return;
          }
        }
        files = await runInIsolate(discType);
      }
    } catch (e) {
      receivePort.close();
      if (!abandoned()) _emit(RipError(e.toString()));
      return;
    }
    // Cancelled — or the notifier moved on (reset, disposed) meanwhile.
    final ripped = state;
    if (files == null || abandoned() || ripped is! RipInProgress) return;

    // The disc is done; what follows only touches the files on disk, so the
    // drive is free and there is nothing left to cancel.
    _emit(ripped.copyWith(finishing: true, cancelling: false));
    // rip-phase path → the name the user typed for that title
    final customStems = <String, String>{
      for (final t in selectedTitles)
        if (configs[t.displayKey]?.customName?.trim().isNotEmpty == true)
          videoTitleOutputPath(options.outputDir, discTitle, t):
              configs[t.displayKey]!.customName!,
    };
    var outputs = files;
    try {
      outputs = await _postProcess(
        files: outputs,
        log: appendLog,
        extractSubtitles: extractSubtitles,
        subtitleLangs: subtitleLangs,
        autoName: options.autoName,
        batchAssign: batchAssign ?? false,
        nameHint: options.titleHint,
        seasons: options.seasonHint ?? const [],
        stems: customStems,
        // The overwrite dialog adds every file the user ticked to the set,
        // rip-phase paths and custom-name targets alike; only those may be
        // replaced by a rename.
        replaceTargets: overwrite ?? const {},
        discName: discTitle,
      );
    } catch (e) {
      // The rip itself succeeded; a failing extra must not hide that.
      appendLog('Post-processing failed: $e', isError: true);
    }

    // A loop must not eject a disc that did not rip and carry on: it stops
    // here, with the disc still in the drive and the failure on screen.
    if (failedTitles.isEmpty &&
        ref.read(loopEnabledProvider(devicePath)) &&
        devicePath.startsWith('/dev/')) {
      try {
        await Process.run('eject', [devicePath]);
      } catch (e) {
        appendLog('Could not eject $devicePath: $e', isError: true);
      }
      _emit(LoopWaiting(lastOutputFiles: outputs, log: List.from(logs)));
    } else {
      _emit(RipCompleted(outputs,
          log: List.from(logs), failed: failedTitles));
    }
  }

  void cancel() {
    final s = state;
    if (s is RipAudioCdProgress) {
      // The audio rip runs in this isolate (only the sector reads are
      // off-thread), so the ripper can be told directly; startAudioCdRip
      // returns to idle once rip() has unwound.
      state = s.copyWith(cancelling: true);
      _audioRipper?.cancel();
      return;
    }
    if (s is RipInProgress) {
      if (s.finishing) return; // nothing left to cancel
      state = s.copyWith(cancelling: true);
      final job = _jobSeq;
      _cancelledJob = job;
      // No port yet when the isolate has not started; _runRip then sees the
      // cancelled job and either never spawns it or cancels it on arrival.
      _cancelPort?.send(null);
      // Fallback: if the isolate is blocked in synchronous FFI (e.g. DVDReadBlocks)
      // the cancel message can't be processed. Force-kill after 3 seconds.
      Future.delayed(const Duration(seconds: 3), () {
        if (_disposed) return;
        // Only for the job that was cancelled: a new rip started within the
        // 3 s window must not be killed or reset to idle.
        if (_jobSeq != job) return;
        final now = state;
        // Past the rip (post-processing) there is no isolate left to kill.
        if (now is! RipInProgress || now.finishing) return;
        _spawnedIsolate?.kill(priority: Isolate.immediate);
        _activeReceivePort?.close();
        // A killed isolate never runs the ripper's own part-file cleanup.
        _deleteParts(_jobParts);
        _emit(RipIdle());
      });
    }
  }

  /// Removes the half-written outputs of a cancelled rip. The isolate is
  /// stopped with `Isolate.exit`/kill, which skips the `finally` that would
  /// have deleted them — and a Blu-ray part file is tens of gigabytes.
  Future<void> _deleteParts(List<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Best effort; the next rip of this title removes a stale part too.
      }
    }
  }

  bool _loopScanRunning = false;

  /// Loop mode: scans the disc now in the drive and rips it with the
  /// suggested titles (video) or all tracks (audio). Lives here rather than
  /// in the detail panel, so a loop keeps going while another drive is on
  /// screen. No-op unless this drive is waiting for its next disc.
  Future<void> startLoopDisc() async {
    if (_loopScanRunning || state is! LoopWaiting) return;
    _loopScanRunning = true;
    try {
      ref.invalidate(discTitlesProvider(devicePath));
      final content = await ref.read(discTitlesProvider(devicePath).future);
      if (_disposed || state is! LoopWaiting) return;
      // The scan is over: a disc mismatch found by the rip's own pre-check
      // calls back into this method and must be able to scan again.
      _loopScanRunning = false;
      if (content is VideoDiscContent) {
        startRipDirect(
          content.discTitle,
          [
            for (final t in content.titles)
              if (content.suggestion.contains(t.displayKey)) t,
          ],
          fingerprint: content.fingerprint,
        );
      } else if (content is AudioCdContent) {
        await startAudioCdRip(
          content.metadata,
          [for (var i = 1; i <= content.metadata.tracks.length; i++) i],
          scanFingerprint: content.fingerprint,
        );
      }
      // Anything else (unreadable or empty disc): keep waiting.
    } catch (_) {
      // A failed scan leaves the loop waiting for the next disc.
    } finally {
      _loopScanRunning = false;
    }
  }

  /// The disc in the drive is not the one that was scanned. An attended rip
  /// shows that and offers a rescan; a loop just scans the new disc.
  void _discMismatch(DiscChangedException e) {
    if (ref.read(loopEnabledProvider(devicePath))) {
      _emit(LoopWaiting(lastOutputFiles: const []));
      startLoopDisc();
    } else {
      _emit(RipDiscMismatch(expected: e.expected, actual: e.actual));
    }
  }

  void toggleLoop() {
    ref.read(loopEnabledProvider(devicePath).notifier).toggle();
  }

  void stopLoop() {
    ref.read(loopEnabledProvider(devicePath).notifier).disable();
    final s = state;
    if (s is LoopWaiting) state = RipCompleted(s.lastOutputFiles, log: s.log);
  }

  void reset() {
    _cancelPort = null;
    _spawnedIsolate = null;
    _activeReceivePort = null;
    _audioRipper = null;
    state = RipIdle();
  }
}

class _LoopEnabledNotifier extends Notifier<bool> {
  final String devicePath;
  _LoopEnabledNotifier(this.devicePath);

  @override
  bool build() => false;

  void toggle() => state = !state;
  void disable() => state = false;
}

final loopEnabledProvider =
    NotifierProvider.family<_LoopEnabledNotifier, bool, String>(
  (devicePath) => _LoopEnabledNotifier(devicePath),
);

final ripStateProvider = NotifierProvider.family<RipStateNotifier, RipState, String>(
  (device) => RipStateNotifier(device),
);
