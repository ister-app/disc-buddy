import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;

import 'naming_flow.dart';
import 'rename.dart';
import 'tool_builders.dart';

const videoExtensions = {
  '.mkv', '.mp4', '.avi', '.m4v', '.mov', '.ts', '.m2ts', '.mpg', '.mpeg',
};

/// Video files directly inside [dir], sorted by name.
List<File> listVideoFiles(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((f) => videoExtensions.contains(p.extension(f.path).toLowerCase()))
    .toList()
  ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

/// Picks items by 1-based numbers from a free-text answer such as "1 3,4".
/// Empty input selects everything; out-of-range numbers are ignored.
List<T> selectByNumbers<T>(String input, List<T> items) {
  if (input.trim().isEmpty) return items;
  return input
      .split(RegExp(r'[,\s]+'))
      .where((s) => s.isNotEmpty)
      .map(int.tryParse)
      .where((n) => n != null && n >= 1 && n <= items.length)
      .map((n) => items[n! - 1])
      .toList();
}

/// Lists video files in [dirPath], lets the user choose, then offers subtitle
/// extraction and renaming for each selected file.
///
/// Returns false when the directory holds no video files (the caller turns
/// that into a non-zero exit).
Future<bool> processDirectory(
  RipOptions opts,
  String dirPath, {
  Prompter prompter = const TtyPrompter(),
  LogCallback? onLog,
  ExtractorFactory extractorFactory = buildExtractor,
  AutoNamerFactory autoNamerFactory = buildAutoNamer,
}) async {
  void log(String m, {bool isError = false}) => emitLog(onLog, m, isError: isError);

  final files = listVideoFiles(Directory(dirPath));
  if (files.isEmpty) {
    log('No video files found in $dirPath', isError: true);
    return false;
  }

  log('Directory: $dirPath');
  log('');
  log('Available files:');
  for (var i = 0; i < files.length; i++) {
    log('  ${(i + 1).toString().padLeft(3)}: ${p.basename(files[i].path)}');
  }
  log('');

  // --- Select files ---
  final List<File> selected;
  if (opts.force) {
    selected = files;
    log('→ Auto-selected all ${files.length} files.');
  } else {
    log('Enter file numbers (comma- or space-separated, e.g.: 1 3),');
    log('or press Enter for all:');
    final input = await prompter.readLine('');
    selected = selectByNumbers(input, files);
    if (input.trim().isEmpty) log('→ All ${files.length} files selected.');
  }

  if (selected.isEmpty) {
    log('No files selected.');
    return true;
  }

  log('');

  // --- Collect rename preferences (once for all files) ---
  final namePrefs = await collectNamingPrefs(
    opts,
    [
      for (final f in selected)
        (filename: f.path, displayKey: p.basename(f.path), hasSubtitles: true),
    ],
    prompter,
    defaultStemOf: p.basenameWithoutExtension,
    onLog: onLog,
  );

  final autoNameCount = namePrefs.values.where((v) => v == '?').length;
  final resolvedBatchAssign =
      await promptBatchAssign(opts, autoNameCount, prompter);

  // --- Subtitle extraction (once for all files) ---
  final canExtract = opts.canOcrSubtitles;
  final extractChoice = canExtract && !opts.force
      ? await promptExtractSubtitles(opts, prompter, onLog: onLog)
      : noExtract;

  SubtitleExtractor? extractor;
  if ((canExtract && extractChoice.doExtract) ||
      (namePrefs.containsValue('?') && opts.canAutoName)) {
    extractor = extractorFactory(opts);
  }

  AutoNamer? autoNamer;
  if (namePrefs.containsValue('?') && opts.canAutoName && extractor != null) {
    autoNamer =
        autoNamerFactory(opts, extractor, batchAssign: resolvedBatchAssign);
  }

  // Ask naming hints upfront so no questions interrupt processing.
  final namingHints = await resolveNamingHints(opts, prompter,
      anyAutoName: namePrefs.containsValue('?'));

  try {
    // --- Step 1: Extract subtitles for all selected files ---
    if (extractChoice.doExtract && extractor != null) {
      for (final file in selected) {
        log('\n── Extracting subtitles: ${file.path}');
        await extractor.extractAll(file, languages: extractChoice.langs);
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
        log('\n── Auto-naming ${batchItems.length} file(s)...');
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
      var newStem = namePrefs[file.path];
      if (newStem == '?') {
        newStem = resolvedStems[file.path];
        if (newStem == null) {
          log('   Auto-naming failed for ${file.path} — keeping original name.',
              isError: true);
        }
      }
      if (newStem != null) {
        await renameWithSidecars(file, newStem, onLog: onLog);
      }
    }
  } finally {
    autoNamer?.close();
  }
  return true;
}

/// Processes a single MKV file: optional subtitle extraction and optional
/// rename (manual or LLM-assisted auto-naming).
Future<void> processMkv(
  RipOptions opts,
  String mkvPath, {
  Prompter prompter = const TtyPrompter(),
  LogCallback? onLog,
  ExtractorFactory extractorFactory = buildExtractor,
  AutoNamerFactory autoNamerFactory = buildAutoNamer,
}) async {
  void log(String m, {bool isError = false}) => emitLog(onLog, m, isError: isError);

  final mkvFile  = File(mkvPath);
  final discName = p.basenameWithoutExtension(mkvPath);

  log('File:   $mkvPath');
  log('');

  // --- Rename preference ---
  String? newStem; // null = keep, '?' = auto-name, otherwise the new stem

  if (opts.autoName && opts.canAutoName) {
    newStem = '?';
  } else if (!opts.force) {
    final canAuto  = opts.canAutoName;
    final modeHint = canAuto ? ' [y/?/N]' : ' [y/N]';
    final answer = (await prompter.readLine('Rename "$discName.mkv"?$modeHint '))
        .trim()
        .toLowerCase();

    if (answer == 'y' || answer == 'j') {
      final input =
          (await prompter.readLine('  New name [$discName]: ')).trim();
      if (input.isNotEmpty) newStem = sanitizeFilename(input);
    } else if (answer == '?' && canAuto) {
      newStem = '?';
    }
  }

  // --- Subtitle extraction prompt ---
  final canExtract = opts.canOcrSubtitles;
  final extractChoice = canExtract && !opts.force
      ? await promptExtractSubtitles(opts, prompter, onLog: onLog)
      : noExtract;

  // Ask naming hints before any processing starts.
  final namingHints =
      await resolveNamingHints(opts, prompter, anyAutoName: newStem == '?');

  SubtitleExtractor? extractor;
  if ((canExtract && extractChoice.doExtract) ||
      (newStem == '?' && opts.canAutoName)) {
    extractor = extractorFactory(opts);
  }

  if (extractChoice.doExtract && extractor != null) {
    log('\n── Extracting subtitles: $mkvPath');
    await extractor.extractAll(mkvFile, languages: extractChoice.langs);
  }

  // --- Resolve auto-name ---
  if (newStem == '?' && extractor != null) {
    final autoNamer = autoNamerFactory(opts, extractor);
    try {
      log('\n── Auto-naming: $mkvPath');
      final hints    = namingHints!;
      final srts     = extractor.findExistingSrts(mkvFile);
      newStem = await autoNamer.nameFile(mkvFile, discName,
          existingSrts: srts,
          titleHint: hints.title,
          seasonHint: hints.season);
      if (newStem == null) {
        log('   Auto-naming failed — keeping original name.', isError: true);
      }
    } finally {
      autoNamer.close();
    }
  }

  // --- Apply rename ---
  if (newStem != null) {
    await renameWithSidecars(mkvFile, newStem, onLog: onLog);
  }
}
