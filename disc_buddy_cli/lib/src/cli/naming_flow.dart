import 'dart:io';

import 'package:disc_buddy/disc_buddy.dart';
import 'package:path/path.dart' as p;

import 'options_builder.dart' show parseSeasons;
import 'rename.dart';
import 'tool_builders.dart';

/// Title/season hints for the auto-namer; null fields mean "let the LLM decide".
typedef NamingHints = ({String? title, List<int>? season});

/// Result of the "Extract subtitles?" question.
typedef ExtractChoice = ({bool doExtract, Set<String>? langs});

const ExtractChoice noExtract = (doExtract: false, langs: null);

/// A title or file as the naming prompts see it.
typedef NameableItem = ({String filename, String displayKey, bool hasSubtitles});

/// Asks "Extract subtitles to SRT?" and, on yes, which languages to extract.
/// If [RipOptions.subtitleLangs] is already set (from CLI/config), skips the
/// language question — but still asks whether to extract at all.
/// Returns [noExtract] when declined.
Future<ExtractChoice> promptExtractSubtitles(
  RipOptions opts,
  Prompter prompter, {
  LogCallback? onLog,
}) async {
  if (!await prompter.confirm('Extract subtitles to SRT? [y/N] ')) {
    return noExtract;
  }
  if (opts.subtitleLangs != null) {
    final desc = opts.subtitleLangs!.isEmpty
        ? 'all'
        : opts.subtitleLangs!.join(', ');
    emitLog(onLog, '   Languages: $desc (from --subtitle-langs)');
    return (
      doExtract: true,
      langs: opts.subtitleLangs!.isEmpty ? null : opts.subtitleLangs,
    );
  }
  final input = (await prompter.readLine(
          '   Languages? (e.g. en,fr — Enter for all): '))
      .trim()
      .toLowerCase();
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
/// Returns the resolved hints (either from CLI or from interactive input).
/// Either field may be null, meaning "let the LLM decide".
Future<NamingHints> askNamingHints(RipOptions opts, Prompter prompter) async {
  final cliTitle  = opts.titleHint;
  final cliSeason = opts.seasonHint;

  // Both already known — nothing to ask.
  if (cliTitle != null && cliSeason != null) {
    return (title: cliTitle, season: cliSeason);
  }

  const seasonQ =
      '   Season(s)? (e.g. 4 or 5,6 for series, Enter for movie, ? for auto): ';

  if (cliTitle != null) {
    // Title known, season unknown.
    final input = (await prompter.readLine(seasonQ)).trim();
    return (title: cliTitle, season: parseSeasons(input));
  }

  if (cliSeason != null) {
    // Season known, title unknown.
    final input =
        (await prompter.readLine('   Series name? (or ? for full auto): ')).trim();
    if (input.isEmpty || input == '?') return (title: null, season: cliSeason);
    return (title: input, season: cliSeason);
  }

  // Nothing known — ask for title first, then optionally season(s).
  final nameInput = (await prompter.readLine(
          '   Film/series name? (or ? / Enter for full auto): '))
      .trim();
  if (nameInput.isEmpty || nameInput == '?') {
    return (title: null, season: null);
  }

  final seasonInput = (await prompter.readLine(seasonQ)).trim();
  return (title: nameInput, season: parseSeasons(seasonInput));
}

/// Hints for a run: nothing asked under `--force` (CLI/config hints are used
/// as they are), otherwise [askNamingHints]. Null when nothing is auto-named.
Future<NamingHints?> resolveNamingHints(
  RipOptions opts,
  Prompter prompter, {
  required bool anyAutoName,
}) async {
  if (!anyAutoName) return null;
  if (opts.force) return (title: opts.titleHint, season: opts.seasonHint);
  return askNamingHints(opts, prompter);
}

/// Asks the "Use batch assignment?" question upfront (before ripping starts)
/// so it doesn't interrupt processing later. Only asked when [autoNameCount]
/// > 1 and no CLI override is set.
Future<bool?> promptBatchAssign(
  RipOptions opts,
  int autoNameCount,
  Prompter prompter,
) async {
  if (opts.batchAssign != null) return opts.batchAssign;
  if (opts.force || autoNameCount <= 1) return opts.batchAssign;
  return prompter.confirm(
    '   Use batch assignment? (sends all excerpts in one LLM call, '
    'works better with large models) [y/N] ',
  );
}

/// Asks the user how they want to name the selected titles and returns a map
/// from `filename` → desired stem (or `'?'` for auto-naming).
///
/// An empty map means "use default names for all titles". [defaultStemOf]
/// gives the stem a title gets when the user keeps the default; disc rips
/// use [defaultStem], directory mode uses the file's own stem.
Future<Map<String, String>> collectNamingPrefs(
  RipOptions opts,
  List<NameableItem> titles,
  Prompter prompter, {
  required String Function(String filename) defaultStemOf,
  LogCallback? onLog,
}) async {
  final prefs = <String, String>{};
  if (opts.force || titles.isEmpty) return prefs;

  // With the whisper fallback available, titles without subtitles are also
  // auto-nameable (transcription kicks in when subtitle extraction fails).
  bool nameable(NameableItem t) => t.hasSubtitles || opts.canTranscribe;
  final anyNameable = titles.any(nameable);
  final canAuto = opts.canAutoName && anyNameable;

  void autoAll() {
    for (final t in titles) {
      prefs[t.filename] = nameable(t) ? '?' : defaultStemOf(t.filename);
    }
  }

  if (opts.autoName && canAuto) {
    autoAll();
    return prefs;
  }

  final modeHint = canAuto ? ' [y/?/N]' : ' [y/N]';
  final answer =
      (await prompter.readLine('\nRename items?$modeHint ')).trim().toLowerCase();

  if (answer == 'y' || answer == 'j') {
    emitLog(onLog, 'Press Enter to keep the default name.');
    for (final t in titles) {
      final def = defaultStemOf(t.filename);
      final autoHint =
          (opts.canAutoName && nameable(t)) ? ', ? for auto' : '';
      final input =
          (await prompter.readLine('  "${t.displayKey}" [$def]$autoHint: '))
              .trim();
      if (input.isEmpty) {
        // keep default — no entry needed
      } else if (input == '?' && opts.canAutoName && nameable(t)) {
        prefs[t.filename] = '?';
      } else {
        prefs[t.filename] = sanitizeFilename(input);
      }
    }
  } else if (answer == '?' && canAuto) {
    autoAll();
  }

  return prefs;
}

/// Extracts subtitles and resolves `'?'` auto-name entries in [namePrefs]
/// for disc-ripped titles. Modifies [namePrefs] in place.
Future<void> resolveSubtitlesAndNames(
  RipOptions opts,
  Directory outDir,
  String discTitle,
  List<({String filename, String displayKey})> titles,
  Map<String, String> namePrefs, {
  required bool doExtract,
  Set<String>? extractLangs,
  NamingHints? namingHints,
  bool? batchAssign,
  LogCallback? onLog,
  ExtractorFactory extractorFactory = buildExtractor,
  AutoNamerFactory autoNamerFactory = buildAutoNamer,
}) async {
  final wantExtract = doExtract && opts.canOcrSubtitles;
  final wantNaming = namePrefs.containsValue('?') && opts.canAutoName;
  if (!wantExtract && !wantNaming) return;

  final extractor = extractorFactory(opts);
  File outFile(String filename) =>
      File(p.join(outDir.path, '${sanitizeFilename(discTitle)}-$filename'));

  if (wantExtract) {
    for (final t in titles) {
      final f = outFile(t.filename);
      if (await f.exists()) {
        emitLog(onLog, '\n── Extracting subtitles: ${f.path}');
        await extractor.extractAll(f, languages: extractLangs);
      }
    }
  }

  if (wantNaming) {
    final autoNamer = autoNamerFactory(opts, extractor, batchAssign: batchAssign);
    // Hints were collected before ripping started; non-null is an invariant here.
    final hints = namingHints!;
    try {
      // Collect all titles that need auto-naming and batch them together.
      final batchItems = <({String filename, String displayKey, File file, List<File> srts})>[];
      for (final t in titles) {
        if (namePrefs[t.filename] != '?') continue;
        final f = outFile(t.filename);
        if (!await f.exists()) continue;
        batchItems.add((
          filename:   t.filename,
          displayKey: t.displayKey,
          file:       f,
          srts:       extractor.findExistingSrts(f),
        ));
      }

      if (batchItems.isNotEmpty) {
        emitLog(onLog, '\n── Auto-naming ${batchItems.length} title(s)...');
        final results = await autoNamer.nameFilesBatch(
          batchItems.map((b) => (file: b.file, discName: discTitle, srts: b.srts)).toList(),
          titleHint:  hints.title,
          seasonHint: hints.season,
        );
        for (final b in batchItems) {
          final resolved = results[b.file];
          if (resolved == null) {
            final fallback = defaultStem(discTitle, b.filename);
            emitLog(onLog,
                '   Auto-naming failed for ${b.displayKey} — keeping default: $fallback',
                isError: true);
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
