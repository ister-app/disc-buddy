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
    ..addOption('device',  abbr: 'd', help: 'Optical device (e.g. /dev/sr0)',
        defaultsTo: Platform.environment['DISC_DEVICE'])
    ..addOption('iso',     abbr: 'i', help: 'ISO image, MKV file, or directory of video files',
        defaultsTo: Platform.environment['DISC_ISO'])
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
    ..addFlag('force',   abbr: 'f', negatable: false,
        help: 'Overwrite existing files; skip language prompts')
    ..addFlag('help',    abbr: 'h', negatable: false, help: 'Show help');

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

  final rawDevice = args['device'] as String? ?? '';
  final rawIso    = args['iso']    as String? ?? '';

  if (rawDevice.isNotEmpty && rawIso.isNotEmpty) {
    stderr.writeln('Error: --device and --iso are mutually exclusive.');
    exit(1);
  }

  // Validate -i target before late-final declarations.
  if (rawIso.isNotEmpty &&
      !Directory(rawIso).existsSync() &&
      !File(rawIso).existsSync()) {
    stderr.writeln('Error: file or directory not found: $rawIso');
    exit(1);
  }

  // --- Select source (drive, ISO image, MKV file, or video directory) ---
  final bool isIso;
  final bool isMkv;
  final bool isDir;
  final String device;

  if (rawIso.isNotEmpty) {
    if (Directory(rawIso).existsSync()) {
      isDir  = true;
      isMkv  = false;
      isIso  = false;
      device = rawIso;
    } else {
      isDir  = false;
      isMkv  = rawIso.toLowerCase().endsWith('.mkv');
      isIso  = !isMkv;
      device = rawIso;
    }
  } else if (rawDevice.isNotEmpty) {
    isDir  = false;
    isMkv  = false;
    isIso  = false;
    device = rawDevice;
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
    force:      args['force'] as bool,
    mkvextract: mkvextractBin,
    subtileOcr: subtileOcrBin,
    tmdbToken:  cfgOpt('tmdb-token'),
    llmUrl:     cfgOpt('llm-url'),
    llmKey:     cfgOpt('llm-key'),
    llmModel:   cfgOpt('llm-model'),
    titleHint:  cfgOpt('name'),
    seasonHint: int.tryParse(cfgOpt('season') ?? ''),
  );

  if (isMkv) {
    await _processMkv(opts, device);
    return;
  }
  if (isDir) {
    await _processDirectory(opts, device);
    return;
  }

  // --- Detect disc type ---
  final DiscType discType;
  if (isIso) {
    discType = await withMountedDisc<DiscType>(
          device,
          (mp) async => DiscTypeDetector.detectFromMountPoint(mp),
        ) ??
        DiscType.unknown;
  } else {
    discType = await DiscTypeDetector.detect(device);
  }

  final discTypeStr = switch (discType) {
    DiscType.audioCD => 'audiocd',
    DiscType.dvd     => 'dvd',
    DiscType.bluray  => 'bluray',
    DiscType.unknown => 'unknown',
  };

  stdout.writeln('Disc type: $discTypeStr');
  stdout.writeln(isIso ? 'ISO:       $device' : 'Device:    $device');
  stdout.writeln('Output:    $outputDir');
  stdout.writeln('ffmpeg:    $ffmpegBin');
  stdout.writeln('');

  switch (discType) {
    case DiscType.audioCD:
      await _ripAudioCD(opts);
    case DiscType.dvd:
      await _ripDVD(opts, isIso: isIso);
    case DiscType.bluray:
      await _ripBluray(opts, isIso: isIso);
    case DiscType.unknown:
      stderr.writeln('Unknown disc type — cannot rip.');
      exit(1);
  }
}

// ---------------------------------------------------------------------------
// DVD
// ---------------------------------------------------------------------------

Future<void> _ripDVD(RipOptions opts, {bool isIso = false}) async {
  final ripper = DVDRipper(opts);

  final result = await ripper.loadTitles();
  if (result == null) exit(1);

  final discTitle = result.discTitle;
  final titles    = result.titles;

  stdout.writeln('Disc:  $discTitle');
  stdout.writeln('Titles found (VIDEO_TS): ${titles.map((t) => t.vtsNumber).toSet().length}');
  stdout.writeln('');
  stdout.writeln('Available titles:');

  for (final title in titles) {
    final na       = title.audioTracks.length;
    final ns       = title.subtitleTracks.length;
    final nc       = title.chapters.length;
    final angleStr = title.totalAngles > 1
        ? '  (angle ${title.pgcIndex + 1}/${title.totalAngles})'
        : '';
    stdout.writeln(
      '  ${title.displayKey.padLeft(4)}: ${title.durationLabel}'
      '  $na audio  ${ns.toString().padLeft(2)} sub'
      '  ${nc.toString().padLeft(2)} ch$angleStr',
    );
  }

  stdout.writeln('');

  final titleMap   = {for (final t in titles) t.displayKey: t};
  final suggestion = autoSelectDvd(titles);
  final suggStr    = suggestion.map((t) => t.displayKey).join(' ');

  final List<DvdTitle> selected;
  if (opts.force) {
    stdout.writeln('→ Auto-selected: $suggStr');
    selected = suggestion.isNotEmpty
        ? suggestion
        : titles.where((t) => t.pgcIndex == 0).toList();
  } else {
    stdout.writeln('Enter titles (comma- or space-separated, e.g.: 1 3.1 7),');
    if (suggStr.isNotEmpty) {
      stdout.writeln('or press Enter for suggestion [$suggStr]:');
    } else {
      stdout.writeln('or press Enter for all titles (angle 1):');
    }
    final input = Menu.readLine();
    if (input.trim().isEmpty) {
      if (suggStr.isNotEmpty) {
        selected = suggestion;
        stdout.writeln('→ Used suggestion: $suggStr');
      } else {
        selected = titles.where((t) => t.pgcIndex == 0).toList();
        stdout.writeln('→ All ${selected.length} titles will be ripped (angle 1).');
      }
    } else {
      selected = input
          .split(RegExp(r'[,\s]+'))
          .where((k) => k.isNotEmpty)
          .expand((k) {
            if (titleMap.containsKey(k)) return [titleMap[k]!];
            return titles.where(
              (t) => t.vtsNumber.toString() == k && t.pgcIndex == 0,
            ).toList();
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
          hasSubtitles: t.subtitleTracks.isNotEmpty,
        )).toList(),
  );

  final doExtract = opts.mkvextract != null && opts.subtileOcr != null && !opts.force
      ? Menu.confirm('Extract subtitles to SRT after ripping? [y/N] ')
      : false;

  await ripper.rip(discTitle, selected);

  final outDir = Directory(p.join(opts.outputDir, sanitizeFilename(discTitle)));
  await _resolveSubtitlesAndNames(
    opts, outDir, discTitle,
    selected.map((t) => (filename: t.filename, displayKey: t.displayKey)).toList(),
    namePrefs,
    doExtract: doExtract,
  );

  await _applyRenames(outDir, discTitle,
      selected.map((t) => t.filename).toList(), namePrefs);

  if (!isIso && Menu.confirm('\nEject disc? [y/N] ')) {
    await Process.run('eject', [opts.device!]);
  }
}

// ---------------------------------------------------------------------------
// Blu-ray
// ---------------------------------------------------------------------------

Future<void> _ripBluray(RipOptions opts, {bool isIso = false}) async {
  final ripper = BlurayRipper(opts);

  final result = await ripper.loadTitles();
  if (result == null) exit(1);

  final discTitle = result.discTitle;
  final titles    = result.titles;

  stdout.writeln('Disc:  $discTitle');
  stdout.writeln('Titles found: ${titles.length}');
  stdout.writeln('');
  stdout.writeln('Available titles:');

  for (final title in titles) {
    final na = title.audioCount;
    final ns = title.subtitleCount;
    final nc = title.chapters.length;
    stdout.writeln(
      '  ${title.index.toString().padLeft(3)}: ${title.durationLabel}'
      '  $na audio  ${ns.toString().padLeft(2)} sub'
      '  ${nc.toString().padLeft(2)} ch'
      '  [${title.playlist}]',
    );
  }

  stdout.writeln('');

  final titleMap   = {for (final t in titles) t.index.toString(): t};
  final suggestion = autoSelectBluray(titles);
  final suggStr    = suggestion.map((t) => t.index.toString()).join(' ');

  final List<BlurayTitle> selected;
  if (opts.force) {
    stdout.writeln('→ Auto-selected: $suggStr');
    selected = suggestion.isNotEmpty ? suggestion : titles.toList();
  } else {
    stdout.writeln('Enter titles (comma- or space-separated, e.g.: 1 3),');
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
        selected = titles.toList();
        stdout.writeln('→ All ${selected.length} titles will be ripped.');
      }
    } else {
      selected = input
          .split(RegExp(r'[,\s]+'))
          .where((k) => k.isNotEmpty)
          .expand((k) => titleMap.containsKey(k) ? [titleMap[k]!] : <BlurayTitle>[])
          .toList();
    }
  }

  final namePrefs = _collectNamingPrefs(
    opts,
    discTitle,
    selected.map((t) => (
          filename:     t.filename,
          displayKey:   t.index.toString(),
          hasSubtitles: t.subtitleCount > 0,
        )).toList(),
  );

  final doExtract = opts.mkvextract != null && opts.subtileOcr != null && !opts.force
      ? Menu.confirm('Extract subtitles to SRT after ripping? [y/N] ')
      : false;

  await ripper.rip(discTitle, selected);

  final outDir = Directory(p.join(opts.outputDir, sanitizeFilename(discTitle)));
  await _resolveSubtitlesAndNames(
    opts, outDir, discTitle,
    selected.map((t) => (filename: t.filename, displayKey: t.index.toString())).toList(),
    namePrefs,
    doExtract: doExtract,
  );

  await _applyRenames(outDir, discTitle,
      selected.map((t) => t.filename).toList(), namePrefs);

  if (!isIso && Menu.confirm('\nEject disc? [y/N] ')) {
    await Process.run('eject', [opts.device!]);
  }
}

// ---------------------------------------------------------------------------
// Audio CD
// ---------------------------------------------------------------------------

Future<void> _ripAudioCD(RipOptions opts) async {
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

  if (Menu.confirm('\nEject disc? [y/N] ')) {
    await Process.run('eject', [opts.device!]);
  }
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

  // --- Subtitle extraction (once for all files) ---
  final canExtract = opts.mkvextract != null && opts.subtileOcr != null;
  final doExtract  = canExtract && !opts.force
      ? Menu.confirm('Extract subtitles to SRT? [y/N] ')
      : false;

  SubtitleExtractor? extractor;
  if (canExtract && (doExtract || namePrefs.containsValue('?'))) {
    extractor = _buildExtractor(opts);
  }

  AutoNamer? autoNamer;
  if (namePrefs.containsValue('?') && extractor != null) {
    autoNamer = _buildAutoNamer(opts, extractor);
  }

  try {
  // --- Process each file ---
  for (final file in selected) {
    final discName = p.basenameWithoutExtension(file.path);
    final ext      = p.extension(file.path);
    final outDir   = file.parent;

    if (doExtract && extractor != null) {
      stdout.writeln('\n── Extracting subtitles: ${file.path}');
      await extractor.extractAll(file);
    }

    var newStem = namePrefs[file.path];

    if (newStem == '?' && autoNamer != null && extractor != null) {
      stdout.writeln('\n── Auto-naming: ${file.path}');
      final hints    = await _askNamingHints(opts);
      final srts     = extractor.findExistingSrts(file);
      final resolved = await autoNamer.nameFile(file, discName,
          existingSrts: srts,
          titleHint: hints.title,
          seasonHint: hints.season);
      if (resolved == null) {
        stderr.writeln('   Auto-naming failed — keeping original name.');
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
  final doExtract  = canExtract && !opts.force
      ? Menu.confirm('Extract subtitles to SRT? [y/N] ')
      : false;

  SubtitleExtractor? extractor;
  if (canExtract && (doExtract || newStem == '?')) {
    extractor = _buildExtractor(opts);
  }

  if (doExtract && extractor != null) {
    stdout.writeln('\n── Extracting subtitles: $mkvPath');
    await extractor.extractAll(mkvFile);
  }

  // --- Resolve auto-name ---
  if (newStem == '?' && extractor != null) {
    final autoNamer = _buildAutoNamer(opts, extractor);
    try {
      stdout.writeln('\n── Auto-naming: $mkvPath');
      final hints    = await _askNamingHints(opts);
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

/// Asks the user for title/season hints when auto-naming is triggered,
/// unless the hints were already provided via CLI args.
///
/// Returns a record with the resolved hints (either from CLI or from
/// interactive input). Either field may be null, meaning "let the LLM decide".
Future<({String? title, int? season})> _askNamingHints(RipOptions opts) async {
  final cliTitle  = opts.titleHint;
  final cliSeason = opts.seasonHint;

  // Both already known — nothing to ask.
  if (cliTitle != null && cliSeason != null) {
    return (title: cliTitle, season: cliSeason);
  }

  if (cliTitle != null) {
    // Title known, season unknown.
    stdout.write('   Season? (number for series, Enter for movie, ? for auto): ');
    final input = Menu.readLine().trim();
    final season = int.tryParse(input);
    return (title: cliTitle, season: season); // null when Enter or ? entered
  }

  if (cliSeason != null) {
    // Season known, title unknown.
    stdout.write('   Series name? (or ? for full auto): ');
    final input = Menu.readLine().trim();
    if (input.isEmpty || input == '?') return (title: null, season: cliSeason);
    return (title: input, season: cliSeason);
  }

  // Nothing known — ask for title first, then optionally season.
  stdout.write('   Film/series name? (or ? / Enter for full auto): ');
  final nameInput = Menu.readLine().trim();
  if (nameInput.isEmpty || nameInput == '?') {
    return (title: null, season: null);
  }

  stdout.write('   Season? (number for series, Enter for movie, ? for auto): ');
  final seasonInput = Menu.readLine().trim();
  final season = int.tryParse(seasonInput); // null when Enter or ? entered
  return (title: nameInput, season: season);
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
}) async {
  if (!doExtract && !namePrefs.containsValue('?')) return;
  if (opts.mkvextract == null || opts.subtileOcr == null) return;

  final extractor = _buildExtractor(opts);

  if (doExtract) {
    for (final t in titles) {
      final f = File(p.join(outDir.path, '${sanitizeFilename(discTitle)}-${t.filename}'));
      if (await f.exists()) {
        stdout.writeln('\n── Extracting subtitles: ${f.path}');
        await extractor.extractAll(f);
      }
    }
  }

  if (namePrefs.containsValue('?')) {
    final autoNamer = _buildAutoNamer(opts, extractor);
    try {
    for (final t in titles) {
      if (namePrefs[t.filename] != '?') continue;
      final f = File(p.join(outDir.path, '${sanitizeFilename(discTitle)}-${t.filename}'));
      if (!await f.exists()) continue;
      final srts = extractor.findExistingSrts(f);
      stdout.writeln('\n── Auto-naming: ${t.displayKey}');
      final hints    = await _askNamingHints(opts);
      final resolved = await autoNamer.nameFile(f, discTitle,
          existingSrts: srts,
          titleHint: hints.title,
          seasonHint: hints.season);
      if (resolved == null) {
        final fallback = _defaultStem(discTitle, t.filename);
        stderr.writeln('   Auto-naming failed — keeping default: $fallback');
        namePrefs[t.filename] = fallback;
      } else {
        namePrefs[t.filename] = resolved;
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

AutoNamer _buildAutoNamer(RipOptions opts, SubtitleExtractor extractor) =>
    AutoNamer(
      extractor: extractor,
      tmdb: TmdbClient(token: opts.tmdbToken!),
      llm: LlmClient(
        baseUrl: opts.llmUrl!,
        apiKey:  opts.llmKey ?? 'ollama',
        model:   opts.llmModel!,
      ),
    );

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
