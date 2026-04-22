import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy/src/cli/menu.dart';
import 'package:disc_buddy/src/cli/title_selector.dart';
import 'package:disc_buddy/src/device/disc_type_detector.dart';
import 'package:disc_buddy/src/naming/auto_namer.dart';
import 'package:disc_buddy/src/naming/llm_client.dart';
import 'package:disc_buddy/src/naming/tmdb_client.dart';
import 'package:disc_buddy/src/rippers/audiocd_ripper.dart';
import 'package:disc_buddy/src/subtitles/subtitle_extractor.dart';
import 'package:disc_buddy/src/utils/mount.dart';
import 'package:disc_buddy/src/utils/sanitize.dart';
import 'package:disc_buddy/src/utils/config_loader.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config',  abbr: 'c', help: 'Path to config file (default: ${ConfigLoader.defaultPath})')
    ..addOption('input',   abbr: 'i',
        help: 'Optical drive (e.g. /dev/sr0), ISO image, MKV file, or directory of video files',
        defaultsTo: Platform.environment['DISC_ISO'] ?? Platform.environment['DISC_DEVICE'])
    ..addOption('output',  abbr: 'o', help: 'Output directory',
        defaultsTo: null)
    ..addOption('ffmpeg',       help: 'Path to ffmpeg',       defaultsTo: null)
    ..addOption('ffprobe',      help: 'Path to ffprobe',      defaultsTo: null)
    ..addOption('mkvextract',   help: 'Path to mkvextract')
    ..addOption('subtile-ocr',  help: 'Path to subtile-ocr')
    ..addOption('tmdb-token',   help: 'The Movie Database API read access token')
    ..addOption('llm-url',      help: 'OpenAI-compatible LLM base URL (e.g. http://localhost:11434/v1)')
    ..addOption('llm-key',      help: 'LLM API key (default: "ollama" for local)')
    ..addOption('llm-model',    help: 'LLM model name (e.g. gpt-4o, llama3)')
    ..addOption('name',    abbr: 'n', help: 'Film or series title hint for auto-naming')
    ..addOption('season',             help: 'Season number hint for auto-naming (implies series)')
    ..addFlag('force',        abbr: 'f', negatable: false,
        help: 'Overwrite existing files; skip language prompts')
    ..addFlag('auto-name',    abbr: 'a', negatable: false,
        help: 'Automatically use LLM auto-naming for all titles (skips rename prompt)')
    ..addFlag('batch-assign', defaultsTo: null,
        help: 'Send all subtitle excerpts in one LLM call for episode matching '
              '(better accuracy with large models; ask if omitted)')
    ..addOption('subtitle-langs',
        help: 'Comma-separated subtitle languages to extract (e.g. en,nl). '
              'Omit to be asked interactively; use "all" or empty to extract everything.')
    ..addFlag('loop',         abbr: 'l', negatable: false,
        help: 'After each rip, eject and wait for the next disc automatically')
    ..addFlag('help',      abbr: 'h', negatable: false, help: 'Show help');

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }

  if (args['help'] as bool) {
    stdout.writeln('Usage: disc-buddy [options]');
    stdout.writeln('Config:    ${ConfigLoader.defaultPath}');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final config = await ConfigLoader.load(path: args['config'] as String?);

  String cfgStr(String key, String fallback) =>
      (args[key] as String?) ?? (config[key] as String?) ?? fallback;
  String? cfgOpt(String key) =>
      (args[key] as String?) ?? (config[key] as String?);

  // --- Verify ffmpeg binaries ---
  final ffmpegBin  = cfgStr('ffmpeg',  'ffmpeg');
  final ffprobeBin = cfgStr('ffprobe', 'ffprobe');
  for (final bin in [ffmpegBin, ffprobeBin]) {
    final which = await Process.run('which', [bin]);
    if (which.exitCode != 0) {
      stderr.writeln('Error: "$bin" not found in PATH.');
      exit(1);
    }
  }

  // --- Detect optional subtitle tools ---
  String? mkvextractBin = cfgOpt('mkvextract');
  if (mkvextractBin != null) {
    if (!File(mkvextractBin).existsSync()) {
      stderr.writeln('Error: mkvextract not found at "$mkvextractBin".');
      exit(1);
    }
  } else if (File('/usr/bin/mkvextract').existsSync()) {
    mkvextractBin = '/usr/bin/mkvextract';
  }

  String? subtileOcrBin = cfgOpt('subtile-ocr');
  if (subtileOcrBin != null) {
    if (!File(subtileOcrBin).existsSync()) {
      stderr.writeln('Error: subtile-ocr not found at "$subtileOcrBin".');
      exit(1);
    }
  } else if (File('/usr/bin/subtile-ocr').existsSync()) {
    subtileOcrBin = '/usr/bin/subtile-ocr';
  }

  final rawInput = args['input'] as String? ?? '';

  // Validate -i target before late-final declarations.
  if (rawInput.isNotEmpty) {
    if (_isBlockDevice(rawInput)) {
      // Optical drives are block-device nodes; regular file checks don't apply.
      // Fail fast if the drive node itself does not exist (e.g. /dev/sr2 on a
      // machine with only two drives).
      if (!File(rawInput).existsSync()) {
        stderr.writeln('Error: drive not found: $rawInput');
        exit(1);
      }
    } else if (!Directory(rawInput).existsSync() && !File(rawInput).existsSync()) {
      stderr.writeln('Error: file or directory not found: $rawInput');
      exit(1);
    }
  }

  // --- Select source (drive, ISO image, MKV file, or video directory) ---
  final bool isIso;
  final bool isMkv;
  final bool isDir;
  final String device;

  if (rawInput.isNotEmpty) {
    if (Directory(rawInput).existsSync()) {
      isDir  = true;
      isMkv  = false;
      isIso  = false;
      device = rawInput;
    } else if (_isBlockDevice(rawInput)) {
      isDir  = false;
      isMkv  = false;
      isIso  = false;
      device = rawInput;
    } else {
      isDir  = false;
      isMkv  = rawInput.toLowerCase().endsWith('.mkv');
      isIso  = !isMkv;
      device = rawInput;
    }
  } else {
    final drive = await Menu.selectDrive();
    isDir  = false;
    isMkv  = false;
    isIso  = false;
    device = drive.device;
  }

  final outputDir = cfgStr('output',
      Platform.environment['OUTDIR'] ?? p.join(Directory.current.path, 'output'));
  final opts = RipOptions(
    device:     (isMkv || isDir) ? null : device,
    outputDir:  outputDir,
    ffmpeg:     ffmpegBin,
    ffprobe:    ffprobeBin,
    force:      args['force']     as bool,
    autoName:   args['auto-name'] as bool,
    loop:       args['loop']      as bool,
    mkvextract: mkvextractBin,
    subtileOcr: subtileOcrBin,
    tmdbToken:  cfgOpt('tmdb-token'),
    llmUrl:     cfgOpt('llm-url'),
    llmKey:     cfgOpt('llm-key'),
    llmModel:   cfgOpt('llm-model'),
    titleHint:   cfgOpt('name'),
    seasonHint:  _parseSeasons(cfgOpt('season')),
    batchAssign:    args['batch-assign'] as bool?,
    subtitleLangs:  _parseSubtitleLangs(cfgOpt('subtitle-langs')),
  );

  if (isMkv) {
    await _processMkv(opts, device);
    return;
  }
  if (isDir) {
    await _processDirectory(opts, device);
    return;
  }

  // --- Detect disc type and rip ---
  if (isIso) {
    // ISO: one mount cycle covers type detection + scan + rip.
    await withMountedDisc<void>(device, (mountPath) async {
      final discType = DiscTypeDetector.detectFromMountPoint(mountPath);
      final discTypeStr = switch (discType) {
        DiscType.audioCD => 'audiocd',
        DiscType.dvd     => 'dvd',
        DiscType.bluray  => 'bluray',
        DiscType.unknown => 'unknown',
      };
      stdout.writeln('Disc type: $discTypeStr');
      stdout.writeln('ISO:       $device');
      stdout.writeln('Output:    $outputDir');
      stdout.writeln('ffmpeg:    $ffmpegBin');
      stdout.writeln('');
      switch (discType) {
        case DiscType.audioCD:
          await _ripAudioCD(opts);
        case DiscType.dvd:
          await _ripVideoDisc(DVDRipper(opts),
            autoSelect:    autoSelectDvd,
            opts:          opts,
            mountPath:     mountPath,
            errorContext:  'DVD',
            prepareTitles: deduplicateDvdTitles,
          );
        case DiscType.bluray:
          await _ripVideoDisc(BlurayRipper(opts),
            autoSelect:   autoSelectBluray,
            opts:         opts,
            mountPath:    mountPath,
            errorContext: 'Blu-ray',
          );
        case DiscType.unknown:
          stderr.writeln('Unknown disc type — cannot rip.');
          exit(1);
      }
    }, errorContext: 'disc');
    return;
  }

  // Block device: loop to support "eject and load next disc" (answer 'r').
  // On the first run with an interactive-menu drive the disc is already present,
  // so _waitForDisc returns immediately.  On subsequent iterations (afterEject)
  // the function first waits for the tray to empty, then waits for a new disc.
  var looping = false;
  while (true) {
    if (rawInput.isNotEmpty || looping) await _waitForDisc(device, afterEject: looping);

    // Detect without mounting; one mount cycle covers scan + rip.
    final discType    = await DiscTypeDetector.detect(device);
    final discTypeStr = switch (discType) {
      DiscType.audioCD => 'audiocd',
      DiscType.dvd     => 'dvd',
      DiscType.bluray  => 'bluray',
      DiscType.unknown => 'unknown',
    };

    stdout.writeln('Disc type: $discTypeStr');
    stdout.writeln('Device:    $device');
    stdout.writeln('Output:    $outputDir');
    stdout.writeln('ffmpeg:    $ffmpegBin');
    stdout.writeln('');

    bool continueLoop;
    switch (discType) {
      case DiscType.audioCD:
        continueLoop = await _ripAudioCD(opts);
      case DiscType.dvd:
        continueLoop = await _ripVideoDisc(DVDRipper(opts),
          autoSelect:    autoSelectDvd,
          opts:          opts,
          errorContext:  'DVD',
          prepareTitles: deduplicateDvdTitles,
        );
      case DiscType.bluray:
        continueLoop = await _ripVideoDisc(BlurayRipper(opts),
          autoSelect:   autoSelectBluray,
          opts:         opts,
          errorContext: 'Blu-ray',
        );
      case DiscType.unknown:
        stderr.writeln('Unknown disc type — cannot rip.');
        continueLoop = false;
    }

    if (!continueLoop) break;
    looping = true;
  }
}

// ---------------------------------------------------------------------------
// Generic video-disc ripper (DVD + Blu-ray)
// ---------------------------------------------------------------------------

/// Rips a video disc (DVD or Blu-ray) using a [VideoDiscRipper<T>].
///
/// [autoSelect]    — disc-specific suggestion function (e.g. [autoSelectDvd]).
/// [prepareTitles] — optional pre-processing step applied to the raw title list
///                   before display and selection. DVD passes
///                   [deduplicateDvdTitles]; Blu-ray uses the default identity.
/// [errorContext]  — label used in mount-error messages ("DVD" / "Blu-ray").
Future<bool> _ripVideoDisc<T extends VideoTitle>(
  VideoDiscRipper<T> ripper, {
  required List<T> Function(List<T>) autoSelect,
  required RipOptions opts,
  String? mountPath,
  String errorContext = 'disc',
  List<T> Function(List<T>)? prepareTitles,
}) async {
  final isIso = mountPath != null;

  Future<bool> doWork(String? mp) async {
    final result = await ripper.loadTitles(mountPath: mp);
    if (result == null) exit(1);

    final discTitle = result.discTitle;
    final titles    = prepareTitles != null
        ? prepareTitles(result.titles)
        : result.titles;

    stdout.writeln('Disc:  $discTitle');
    stdout.writeln('Titles found: ${titles.length}');
    stdout.writeln('');
    stdout.writeln('Available titles:');
    for (final t in titles) {
      stdout.writeln(
        '  ${t.displayKey.padLeft(4)}: ${t.durationLabel}'
        '  ${t.audioStreamCount} audio'
        '  ${t.subtitleStreamCount.toString().padLeft(2)} sub'
        '  ${t.chapters.length.toString().padLeft(2)} ch'
        '${t.extraInfo ?? ''}',
      );
    }
    stdout.writeln('');

    final titleMap   = {for (final t in titles) t.displayKey: t};
    final suggestion = autoSelect(titles);
    final suggStr    = suggestion.map((t) => t.displayKey).join(' ');

    final List<T> selected;
    if (opts.force) {
      stdout.writeln('→ Auto-selected: $suggStr');
      selected = suggestion.isNotEmpty
          ? suggestion
          : titles.where((t) => t.isPrimary).toList();
    } else {
      stdout.writeln('Enter titles (comma- or space-separated, e.g.: 1 3.1 7),');
      if (suggStr.isNotEmpty) {
        stdout.writeln('or press Enter for suggestion [$suggStr]:');
      } else {
        stdout.writeln('or press Enter for all titles:');
      }
      final input = Menu.readLine();
      if (input.trim().isEmpty) {
        if (suggStr.isNotEmpty) {
          selected = suggestion;
          stdout.writeln('→ Used suggestion: $suggStr');
        } else {
          selected = titles.where((t) => t.isPrimary).toList();
          stdout.writeln('→ All ${selected.length} titles will be ripped.');
        }
      } else {
        selected = input
            .split(RegExp(r'[,\s]+'))
            .where((k) => k.isNotEmpty)
            .expand((k) {
              if (titleMap.containsKey(k)) return [titleMap[k]!];
              return titles.where((t) => t.matchesKey(k)).toList();
            })
            .toList();
      }
    }

    final namePrefs = _collectNamingPrefs(
      opts,
      discTitle,
      selected.map((t) => (
            filename:     t.filename,
            displayKey:   t.displayKey,
            hasSubtitles: t.hasSubtitles,
          )).toList(),
    );

    final autoNameCount = namePrefs.values.where((v) => v == '?').length;
    final resolvedBatchAssign = _promptBatchAssign(opts, autoNameCount);

    final extractResult = opts.mkvextract != null && opts.subtileOcr != null && !opts.force
        ? _promptExtractSubtitles(opts)
        : (doExtract: false, langs: null as Set<String>?);
    final doExtract = extractResult.doExtract;
    final extractLangs = extractResult.langs;

    // Ask naming hints upfront so no questions interrupt the rip.
    final namingHints = namePrefs.containsValue('?') && !opts.force
        ? await _askNamingHints(opts)
        : null;

    await ripper.rip(discTitle, selected, mountPath: mp);

    final outDir = Directory(p.join(opts.outputDir, sanitizeFilename(discTitle)));
    await _resolveSubtitlesAndNames(
      opts, outDir, discTitle,
      selected.map((t) => (filename: t.filename, displayKey: t.displayKey)).toList(),
      namePrefs,
      doExtract: doExtract,
      extractLangs: extractLangs,
      namingHints: namingHints,
      batchAssign: resolvedBatchAssign,
    );

    await _applyRenames(outDir, discTitle,
        selected.map((t) => t.filename).toList(), namePrefs);

    if (!isIso) {
      final action = _promptEject(opts);
      if (action != _EjectAction.none) await Process.run('eject', [opts.device!]);
      return action == _EjectAction.ejectAndContinue;
    }
    return false; // ISO path — no eject prompt
  } // end doWork

  if (mountPath != null) {
    return await doWork(mountPath);
  } else {
    return await withMountedDisc<bool>(opts.device!, (mp) => doWork(mp),
        errorContext: errorContext) ?? false;
  }
}


// ---------------------------------------------------------------------------
// Audio CD
// ---------------------------------------------------------------------------

Future<bool> _ripAudioCD(RipOptions opts) async {
  final ripper = AudioCDRipper(opts);

  final meta = await ripper.loadMetadata();
  if (meta == null) exit(1);

  stdout.writeln('Album:   ${meta.album}');
  if (meta.artist.isNotEmpty) stdout.writeln('Artist:  ${meta.artist}');
  if (meta.date.isNotEmpty)   stdout.writeln('Year:    ${meta.date}');
  if (meta.discNumber > 0)    stdout.writeln('Disc:    ${meta.discNumber}');
  stdout.writeln('');
  stdout.writeln('Available tracks:');

  for (final track in meta.tracks) {
    final displayArtist = track.artist.isNotEmpty ? track.artist : meta.artist;
    final artistSuffix  =
        displayArtist.isNotEmpty ? '  \u2014 $displayArtist' : '';
    stdout.writeln(
        '  ${track.number.toString().padLeft(2)}: '
        '[${track.durationLabel}]  ${track.title}$artistSuffix');
  }

  final selected = Menu.selectTracks(meta.tracks.length);
  await ripper.rip(meta, selected);

  final action = _promptEject(opts);
  if (action != _EjectAction.none) await Process.run('eject', [opts.device!]);
  return action == _EjectAction.ejectAndContinue;
}

// ---------------------------------------------------------------------------
// Directory of video files
// ---------------------------------------------------------------------------

const _videoExtensions = {
  '.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.m2ts', '.mpg', '.mpeg',
};

/// Lists video files in [dirPath], lets the user choose, then offers subtitle
/// extraction and renaming for each selected file.
Future<void> _processDirectory(RipOptions opts, String dirPath) async {
  final dir = Directory(dirPath);
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => _videoExtensions.contains(p.extension(f.path).toLowerCase()))
      .toList()
    ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  if (files.isEmpty) {
    stderr.writeln('No video files found in $dirPath');
    exit(1);
  }

  stdout.writeln('Directory: $dirPath');
  stdout.writeln('');
  stdout.writeln('Available files:');
  for (var i = 0; i < files.length; i++) {
    stdout.writeln('  ${(i + 1).toString().padLeft(3)}: ${p.basename(files[i].path)}');
  }
  stdout.writeln('');

  // --- Select files ---
  final List<File> selected;
  if (opts.force) {
    selected = files;
    stdout.writeln('→ Auto-selected all ${files.length} files.');
  } else {
    stdout.writeln('Enter file numbers (comma- or space-separated, e.g.: 1 3),');
    stdout.writeln('or press Enter for all:');
    final input = Menu.readLine();
    if (input.trim().isEmpty) {
      selected = files;
      stdout.writeln('→ All ${files.length} files selected.');
    } else {
      selected = input
          .split(RegExp(r'[,\s]+'))
          .where((s) => s.isNotEmpty)
          .map((s) => int.tryParse(s))
          .where((n) => n != null && n >= 1 && n <= files.length)
          .map((n) => files[n! - 1])
          .toList();
    }
  }

  if (selected.isEmpty) {
    stdout.writeln('No files selected.');
    return;
  }

  stdout.writeln('');

  // --- Collect rename preferences (once for all files) ---
  final namePrefs = <String, String>{}; // file path → new stem or '?'
  if (!opts.force) {
    final canAuto  = opts.canAutoName;
    final modeHint = canAuto ? ' [y/?/N]' : ' [y/N]';
    stdout.write('Rename items?$modeHint ');
    final answer = Menu.readLine().trim().toLowerCase();

    if (answer == 'y' || answer == 'j') {
      stdout.writeln('Press Enter to keep the default name.');
      for (final f in selected) {
        final defaultStem = p.basenameWithoutExtension(f.path);
        final autoHint    = canAuto ? ', ? for auto' : '';
        stdout.write('  "${p.basename(f.path)}" [$defaultStem]$autoHint: ');
        final input = Menu.readLine().trim();
        if (input == '?' && canAuto) {
          namePrefs[f.path] = '?';
        } else if (input.isNotEmpty) {
          namePrefs[f.path] = sanitizeFilename(input);
        }
      }
    } else if (answer == '?' && canAuto) {
      for (final f in selected) {
        namePrefs[f.path] = '?';
      }
    }
  }

  final autoNameCount = namePrefs.values.where((v) => v == '?').length;
  final resolvedBatchAssign = _promptBatchAssign(opts, autoNameCount);

  // --- Subtitle extraction (once for all files) ---
  final canExtract = opts.mkvextract != null && opts.subtileOcr != null;
  final extractResult = canExtract && !opts.force
      ? _promptExtractSubtitles(opts)
      : (doExtract: false, langs: null as Set<String>?);
  final doExtract   = extractResult.doExtract;
  final extractLangs = extractResult.langs;

  SubtitleExtractor? extractor;
  if (canExtract && (doExtract || namePrefs.containsValue('?'))) {
    extractor = _buildExtractor(opts);
  }

  AutoNamer? autoNamer;
  if (namePrefs.containsValue('?') && extractor != null) {
    autoNamer = _buildAutoNamer(opts, extractor, batchAssign: resolvedBatchAssign);
  }

  // Ask naming hints upfront so no questions interrupt processing.
  final namingHints = namePrefs.containsValue('?') && !opts.force
      ? await _askNamingHints(opts)
      : null;

  try {
  // --- Step 1: Extract subtitles for all selected files ---
  if (doExtract && extractor != null) {
    for (final file in selected) {
      stdout.writeln('\n── Extracting subtitles: ${file.path}');
      await extractor.extractAll(file, languages: extractLangs);
    }
  }

  // --- Step 2: Batch auto-naming ---
  final resolvedStems = <String, String?>{}; // file.path → resolved stem or null
  if (namePrefs.containsValue('?') && autoNamer != null && extractor != null) {
    final hints = namingHints!;
    final batchItems = <({File file, String discName, List<File> srts})>[];
    for (final file in selected) {
      if (namePrefs[file.path] != '?') continue;
      batchItems.add((
        file:     file,
        discName: p.basenameWithoutExtension(file.path),
        srts:     extractor.findExistingSrts(file),
      ));
    }
    if (batchItems.isNotEmpty) {
      stdout.writeln('\n── Auto-naming ${batchItems.length} file(s)...');
      final results = await autoNamer.nameFilesBatch(
        batchItems,
        titleHint:  hints.title,
        seasonHint: hints.season,
      );
      for (final b in batchItems) {
        resolvedStems[b.file.path] = results[b.file];
      }
    }
  }

  // --- Step 3: Apply renames ---
  for (final file in selected) {
    final discName = p.basenameWithoutExtension(file.path);
    final ext      = p.extension(file.path);
    final outDir   = file.parent;

    var newStem = namePrefs[file.path];
    if (newStem == '?') {
      final resolved = resolvedStems[file.path];
      if (resolved == null) {
        stderr.writeln('   Auto-naming failed for ${file.path} — keeping original name.');
        newStem = null;
      } else {
        newStem = resolved;
      }
    }

    if (newStem != null && newStem != discName) {
      final newFile = File(p.join(outDir.path, '$newStem$ext'));
      if (await newFile.exists()) {
        stderr.writeln('Rename skipped: "${p.basename(newFile.path)}" already exists.');
      } else {
        await file.rename(newFile.path);
        stdout.writeln('Renamed: ${file.path}\n      → ${newFile.path}');
        await for (final entry in outDir.list()) {
          if (entry is! File) continue;
          final base = p.basename(entry.path);
          if (!base.startsWith('$discName.') || !base.endsWith('.srt')) continue;
          final suffix = base.substring(discName.length);
          await entry.rename(p.join(outDir.path, '$newStem$suffix'));
        }
      }
    }
  }
  } finally {
    autoNamer?.close();
  }
}

// ---------------------------------------------------------------------------
// Standalone MKV
// ---------------------------------------------------------------------------

/// Processes a single MKV file: optional subtitle extraction and optional
/// rename (manual or LLM-assisted auto-naming).
Future<void> _processMkv(RipOptions opts, String mkvPath) async {
  final mkvFile  = File(mkvPath);
  final discName = p.basenameWithoutExtension(mkvPath);
  final outDir   = mkvFile.parent;

  stdout.writeln('File:   $mkvPath');
  stdout.writeln('');

  // --- Rename preference ---
  String? newStem; // null = keep, '?' = auto-name, otherwise the new stem

  if (!opts.force) {
    final canAuto  = opts.canAutoName;
    final modeHint = canAuto ? ' [y/?/N]' : ' [y/N]';
    stdout.write('Rename "$discName.mkv"?$modeHint ');
    final answer = Menu.readLine().trim().toLowerCase();

    if (answer == 'y' || answer == 'j') {
      stdout.write('  New name [$discName]: ');
      final input = Menu.readLine().trim();
      if (input.isNotEmpty) newStem = sanitizeFilename(input);
    } else if (answer == '?' && canAuto) {
      newStem = '?';
    }
  }

  // --- Subtitle extraction prompt ---
  final canExtract = opts.mkvextract != null && opts.subtileOcr != null;
  final extractResult = canExtract && !opts.force
      ? _promptExtractSubtitles(opts)
      : (doExtract: false, langs: null as Set<String>?);
  final doExtract    = extractResult.doExtract;
  final extractLangs = extractResult.langs;

  // Ask naming hints before any processing starts.
  final namingHints = newStem == '?' && !opts.force
      ? await _askNamingHints(opts)
      : null;

  SubtitleExtractor? extractor;
  if (canExtract && (doExtract || newStem == '?')) {
    extractor = _buildExtractor(opts);
  }

  if (doExtract && extractor != null) {
    stdout.writeln('\n── Extracting subtitles: $mkvPath');
    await extractor.extractAll(mkvFile, languages: extractLangs);
  }

  // --- Resolve auto-name ---
  if (newStem == '?' && extractor != null) {
    final autoNamer = _buildAutoNamer(opts, extractor);
    try {
      stdout.writeln('\n── Auto-naming: $mkvPath');
      final hints    = namingHints ?? await _askNamingHints(opts);
      final srts     = extractor.findExistingSrts(mkvFile);
      final resolved = await autoNamer.nameFile(mkvFile, discName,
          existingSrts: srts,
          titleHint: hints.title,
          seasonHint: hints.season);
      if (resolved == null) {
        stderr.writeln('   Auto-naming failed — keeping original name.');
        newStem = null;
      } else {
        newStem = resolved;
      }
    } finally {
      autoNamer.close();
    }
  }

  // --- Apply rename ---
  if (newStem != null && newStem != discName) {
    final newMkv = File(p.join(outDir.path, '$newStem.mkv'));
    if (await newMkv.exists()) {
      stderr.writeln('Rename skipped: "$newStem.mkv" already exists.');
    } else {
      await mkvFile.rename(newMkv.path);
      stdout.writeln('Renamed: $mkvPath\n      → ${newMkv.path}');
      await for (final entry in outDir.list()) {
        if (entry is! File) continue;
        final base = p.basename(entry.path);
        if (!base.startsWith('$discName.') || !base.endsWith('.srt')) continue;
        final suffix = base.substring(discName.length);
        await entry.rename(p.join(outDir.path, '$newStem$suffix'));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared post-rip helpers
// ---------------------------------------------------------------------------

/// Asks "Extract subtitles to SRT?" and, on yes, which languages to extract.
/// If [subtitleLangs] is already set (from CLI/config), skips the language
/// question — but still asks whether to extract at all.
/// Returns (doExtract: false, langs: null) when declined.
({bool doExtract, Set<String>? langs}) _promptExtractSubtitles(
    RipOptions opts) {
  if (!Menu.confirm('Extract subtitles to SRT? [y/N] ')) {
    return (doExtract: false, langs: null);
  }
  if (opts.subtitleLangs != null) {
    final desc = opts.subtitleLangs!.isEmpty
        ? 'all'
        : opts.subtitleLangs!.join(', ');
    stdout.writeln('   Languages: $desc (from --subtitle-langs)');
    return (
      doExtract: true,
      langs: opts.subtitleLangs!.isEmpty ? null : opts.subtitleLangs,
    );
  }
  stdout.write('   Languages? (e.g. en,fr — Enter for all): ');
  final input = Menu.readLine().trim().toLowerCase();
  if (input.isEmpty) return (doExtract: true, langs: null);
  final langs = input
      .split(RegExp(r'[,\s]+'))
      .where((s) => s.isNotEmpty)
      .toSet();
  return (doExtract: true, langs: langs.isEmpty ? null : langs);
}

/// Asks the user for title/season hints when auto-naming is triggered,
/// unless the hints were already provided via CLI args.
///
/// Returns a record with the resolved hints (either from CLI or from
/// interactive input). Either field may be null, meaning "let the LLM decide".
Future<({String? title, List<int>? season})> _askNamingHints(RipOptions opts) async {
  final cliTitle  = opts.titleHint;
  final cliSeason = opts.seasonHint;

  // Both already known — nothing to ask.
  if (cliTitle != null && cliSeason != null) {
    return (title: cliTitle, season: cliSeason);
  }

  if (cliTitle != null) {
    // Title known, season unknown.
    stdout.write('   Season(s)? (e.g. 4 or 5,6 for series, Enter for movie, ? for auto): ');
    final input = Menu.readLine().trim();
    final seasons = _parseSeasons(input);
    return (title: cliTitle, season: seasons);
  }

  if (cliSeason != null) {
    // Season known, title unknown.
    stdout.write('   Series name? (or ? for full auto): ');
    final input = Menu.readLine().trim();
    if (input.isEmpty || input == '?') return (title: null, season: cliSeason);
    return (title: input, season: cliSeason);
  }

  // Nothing known — ask for title first, then optionally season(s).
  stdout.write('   Film/series name? (or ? / Enter for full auto): ');
  final nameInput = Menu.readLine().trim();
  if (nameInput.isEmpty || nameInput == '?') {
    return (title: null, season: null);
  }

  stdout.write('   Season(s)? (e.g. 4 or 5,6 for series, Enter for movie, ? for auto): ');
  final seasonInput = Menu.readLine().trim();
  final seasons = _parseSeasons(seasonInput);
  return (title: nameInput, season: seasons);
}

/// Extracts subtitles and resolves `'?'` auto-name entries in [namePrefs]
/// for disc-ripped titles. Modifies [namePrefs] in place.
Future<void> _resolveSubtitlesAndNames(
  RipOptions opts,
  Directory outDir,
  String discTitle,
  List<({String filename, String displayKey})> titles,
  Map<String, String> namePrefs, {
  required bool doExtract,
  Set<String>? extractLangs,
  ({String? title, List<int>? season})? namingHints,
  bool? batchAssign,
}) async {
  if (!doExtract && !namePrefs.containsValue('?')) return;
  if (opts.mkvextract == null || opts.subtileOcr == null) return;

  final extractor = _buildExtractor(opts);

  if (doExtract) {
    for (final t in titles) {
      final f = File(p.join(outDir.path, '${sanitizeFilename(discTitle)}-${t.filename}'));
      if (await f.exists()) {
        stdout.writeln('\n── Extracting subtitles: ${f.path}');
        await extractor.extractAll(f, languages: extractLangs);
      }
    }
  }

  if (namePrefs.containsValue('?')) {
    final autoNamer = _buildAutoNamer(opts, extractor, batchAssign: batchAssign);
    // Hints were collected before ripping started; non-null is an invariant here.
    final hints = namingHints!;
    try {
      // Collect all titles that need auto-naming and batch them together.
      final batchItems = <({String filename, String displayKey, File file, List<File> srts})>[];
      for (final t in titles) {
        if (namePrefs[t.filename] != '?') continue;
        final f = File(p.join(outDir.path, '${sanitizeFilename(discTitle)}-${t.filename}'));
        if (!await f.exists()) continue;
        batchItems.add((
          filename:   t.filename,
          displayKey: t.displayKey,
          file:       f,
          srts:       extractor.findExistingSrts(f),
        ));
      }

      if (batchItems.isNotEmpty) {
        stdout.writeln('\n── Auto-naming ${batchItems.length} title(s)...');
        final results = await autoNamer.nameFilesBatch(
          batchItems.map((b) => (file: b.file, discName: discTitle, srts: b.srts)).toList(),
          titleHint:  hints.title,
          seasonHint: hints.season,
        );
        for (final b in batchItems) {
          final resolved = results[b.file];
          if (resolved == null) {
            final fallback = _defaultStem(discTitle, b.filename);
            stderr.writeln('   Auto-naming failed for ${b.displayKey} — keeping default: $fallback');
            namePrefs[b.filename] = fallback;
          } else {
            namePrefs[b.filename] = resolved;
          }
        }
      }
    } finally {
      autoNamer.close();
    }
  }
}

SubtitleExtractor _buildExtractor(RipOptions opts) => SubtitleExtractor(
      ffmpeg:     opts.ffmpeg,
      ffprobe:    opts.ffprobe,
      mkvextract: opts.mkvextract!,
      subtileOcr: opts.subtileOcr!,
    );

AutoNamer _buildAutoNamer(
  RipOptions opts,
  SubtitleExtractor extractor, {
  bool? batchAssign,
}) =>
    AutoNamer(
      extractor: extractor,
      tmdb: TmdbClient(token: opts.tmdbToken!),
      llm: LlmClient(
        baseUrl: opts.llmUrl!,
        apiKey:  opts.llmKey ?? 'ollama',
        model:   opts.llmModel!,
      ),
      force: opts.force,
      batchAssign: batchAssign ?? opts.batchAssign,
    );

/// Asks the "Use batch assignment?" question upfront (before ripping starts)
/// so it doesn't interrupt processing later. Only asked when [autoNameCount]
/// > 1 and no CLI override is set.
bool? _promptBatchAssign(RipOptions opts, int autoNameCount) {
  if (opts.batchAssign != null) return opts.batchAssign;
  if (opts.force || autoNameCount <= 1) return opts.batchAssign;
  stdout.write(
    '   Use batch assignment? (sends all excerpts in one LLM call, '
    'works better with large models) [y/N] ',
  );
  final input = Menu.readLine().trim().toLowerCase();
  return input == 'y' || input == 'yes';
}

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------

/// Builds the default output file stem for a title.
String _defaultStem(String discTitle, String titleFilename) {
  final stem = titleFilename.replaceFirst(RegExp(r'\.mkv$'), '');
  return '${sanitizeFilename(discTitle)}-$stem';
}

/// Asks the user how they want to name the selected titles and returns a map
/// from [filename] → desired stem (or `'?'` for auto-naming).
///
/// An empty map means "use default names for all titles".
Map<String, String> _collectNamingPrefs(
  RipOptions opts,
  String discTitle,
  List<({String filename, String displayKey, bool hasSubtitles})> titles,
) {
  final prefs = <String, String>{};
  if (opts.force || titles.isEmpty) return prefs;

  final anyHasSubtitles = titles.any((t) => t.hasSubtitles);
  final canAuto = opts.canAutoName && anyHasSubtitles;

  if (opts.autoName && canAuto) {
    for (final t in titles) {
      prefs[t.filename] = t.hasSubtitles ? '?' : _defaultStem(discTitle, t.filename);
    }
    return prefs;
  }

  final modeHint = canAuto ? ' [y/?/N]' : ' [y/N]';
  stdout.write('\nRename items?$modeHint ');
  final answer = Menu.readLine().trim().toLowerCase();

  if (answer == 'y' || answer == 'j') {
    stdout.writeln('Press Enter to keep the default name.');
    for (final t in titles) {
      final defaultStem = _defaultStem(discTitle, t.filename);
      final autoHint    =
          (opts.canAutoName && t.hasSubtitles) ? ', ? for auto' : '';
      stdout.write('  "${t.displayKey}" [$defaultStem]$autoHint: ');
      final input = Menu.readLine().trim();
      if (input.isEmpty) {
        // keep default — no entry needed
      } else if (input == '?' && opts.canAutoName && t.hasSubtitles) {
        prefs[t.filename] = '?';
      } else {
        prefs[t.filename] = sanitizeFilename(input);
      }
    }
  } else if (answer == '?' && canAuto) {
    for (final t in titles) {
      prefs[t.filename] = t.hasSubtitles ? '?' : _defaultStem(discTitle, t.filename);
    }
  }

  return prefs;
}

/// Renames MKV files (and associated SRT files) in [outDir] according to
/// [namePrefs]. Entries whose value equals the default stem are skipped.
Future<void> _applyRenames(
  Directory outDir,
  String discTitle,
  List<String> filenames,
  Map<String, String> namePrefs,
) async {
  for (final filename in filenames) {
    final newStem = namePrefs[filename];
    if (newStem == null || newStem == '?') continue;

    final defaultStem = _defaultStem(discTitle, filename);
    if (newStem == defaultStem) continue;

    final oldMkv = File(p.join(outDir.path, '$defaultStem.mkv'));
    final newMkv = File(p.join(outDir.path, '$newStem.mkv'));

    if (!await oldMkv.exists()) continue;
    if (await newMkv.exists()) {
      stderr.writeln('   Rename skipped: "$newStem.mkv" already exists.');
      continue;
    }

    await oldMkv.rename(newMkv.path);
    stdout.writeln('Renamed: ${oldMkv.path}\n      → ${newMkv.path}');

    await for (final entry in outDir.list()) {
      if (entry is! File) continue;
      final base = p.basename(entry.path);
      if (!base.startsWith('$defaultStem.') || !base.endsWith('.srt')) continue;
      final suffix = base.substring(defaultStem.length);
      await entry.rename(p.join(outDir.path, '$newStem$suffix'));
    }
  }
}

enum _EjectAction { none, ejectOnly, ejectAndContinue }

/// Three-way eject prompt shown after every successful rip.
///
///   y / j  → eject disc and stop
///   r      → eject disc and load next (restart for the same drive)
///   N      → don't eject
///
/// When [opts.loop] is set the prompt is skipped and `ejectAndContinue` is
/// returned automatically.
_EjectAction _promptEject(RipOptions opts) {
  if (opts.loop) {
    stdout.writeln('\nEject disc? [y/r/N]  (r = load next disc): r');
    return _EjectAction.ejectAndContinue;
  }
  stdout.write('\nEject disc? [y/r/N]  (r = load next disc): ');
  final answer = Menu.readLine().trim().toLowerCase();
  return switch (answer) {
    'y' || 'j' => _EjectAction.ejectOnly,
    'r'        => _EjectAction.ejectAndContinue,
    _          => _EjectAction.none,
  };
}

/// Parses a season string into a list of season numbers.
///
/// Accepts comma- or space-separated integers, e.g. `"5"`, `"5,6"`, `"5 6"`.
/// Returns null when the input is empty, `?`, or contains no valid integers.
/// Parses `--subtitle-langs` value. Returns null (ask) if omitted,
/// empty set (all) for "all"/empty, or the set of 2-letter codes.
Set<String>? _parseSubtitleLangs(String? input) {
  if (input == null) return null;
  final trimmed = input.trim().toLowerCase();
  if (trimmed.isEmpty || trimmed == 'all') return const {};
  return trimmed.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toSet();
}

List<int>? _parseSeasons(String? input) {
  if (input == null || input.trim().isEmpty || input.trim() == '?') return null;
  final nums = input
      .split(RegExp(r'[,\s]+'))
      .map(int.tryParse)
      .whereType<int>()
      .toList();
  return nums.isEmpty ? null : nums;
}

/// Returns true if [path] refers to a Linux block/character device.
/// On this tool's target platform (Linux) all optical drives live under /dev/.
bool _isBlockDevice(String path) => path.startsWith('/dev/');

/// Waits until [device] contains a readable disc.
///
/// When [afterEject] is true (looping mode after an eject), first waits for
/// the drive tray to empty — preventing the just-ejected disc from being
/// mistaken for a new one — then waits for the next disc to be inserted.
///
/// Subscribes to `udevadm monitor --udev --subsystem-match=block` for
/// instant notification on disc changes. Falls back to 2-second polling
/// when udevadm is unavailable.
Future<void> _waitForDisc(String device, {bool afterEject = false}) async {
  // Start one udevadm monitor for the entire function.  Wrapping its stdout
  // as a broadcast stream lets Phase 1 and Phase 2 subscribe sequentially
  // without re-opening the underlying process pipe (which would fail because
  // Dart reuses file descriptors, making the new pipe look already-subscribed).
  // When all listeners unsubscribe, asBroadcastStream() *pauses* (not cancels)
  // the underlying subscription, so Phase 2 can resume it.
  Process? udev;
  Stream<String>? events;
  try {
    udev = await Process.start(
      'udevadm', ['monitor', '--udev', '--subsystem-match=block'],
    );
    events = udev.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
  } catch (_) {}

  Future<void> waitUntil(bool Function(DiscType) condition, String message) async {
    if (condition(await DiscTypeDetector.detect(device))) return;
    stdout.write(message);
    final evts = events; // local non-nullable alias for type promotion
    if (evts != null) {
      // Re-check after subscribing to close the race window between the
      // initial detect call and the subscription going live.
      if (!condition(await DiscTypeDetector.detect(device))) {
        await for (final _ in evts) {
          if (condition(await DiscTypeDetector.detect(device))) break;
        }
      }
    } else {
      while (!condition(await DiscTypeDetector.detect(device))) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    stdout.writeln(' done.');
  }

  try {
    if (afterEject) {
      // Phase 1: wait for the tray to empty (disc gone).
      await waitUntil(
        (t) => t == DiscType.unknown,
        'Waiting for disc to eject from $device...',
      );
    }
    // Phase 2: wait for a new disc to be inserted and recognised.
    await waitUntil(
      (t) => t != DiscType.unknown,
      'Waiting for disc in $device...',
    );
  } finally {
    udev?.kill();
  }
}
