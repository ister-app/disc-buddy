import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy_cli/src/cli/directory_mode.dart';
import 'package:disc_buddy_cli/src/cli/menu.dart';
import 'package:disc_buddy_cli/src/cli/naming_flow.dart';
import 'package:disc_buddy_cli/src/cli/options_builder.dart';
import 'package:disc_buddy_cli/src/cli/rename.dart';
import 'package:disc_buddy_cli/src/cli/version.dart';

/// Thrown to abort the current rip from inside a `withMountedDisc` callback.
/// Unlike `exit()` — which terminates the VM immediately and skips `finally`
/// blocks, leaking the temporary ISO mount and loop device — throwing lets the
/// mount cleanup run before `main` turns it into a non-zero exit.
class _RipAborted implements Exception {
  final String? message;
  const _RipAborted([this.message]);
}

/// ffmpeg process of the rip in progress, so Ctrl+C can stop it gracefully.
Process? _activeFfmpeg;
void _trackFfmpeg(Process p) => _activeFfmpeg = p;

/// On Ctrl+C: SIGTERM ffmpeg so the ripper's `.part` cleanup runs, then exit.
/// Watching SIGINT disables the VM's default handler, hence the explicit exit.
void _installSigintHandler() {
  ProcessSignal.sigint.watch().listen((_) {
    stderr.writeln('\nInterrupted — stopping ffmpeg and cleaning up...');
    _activeFfmpeg?.kill(ProcessSignal.sigterm);
    Future.delayed(const Duration(seconds: 3), () => exit(130));
  });
}

Future<void> main(List<String> arguments) async {
  _installSigintHandler();
  final parser = buildArgParser();

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    exit(1);
  }

  if (args['version'] as bool) {
    stdout.writeln('disc-buddy $buildVersion');
    exit(0);
  }
  if (args['help'] as bool) {
    stdout.writeln('Usage: disc-buddy [options]');
    stdout.writeln('Config:    ${ConfigLoader.defaultPath}');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final config = await ConfigLoader.load(path: args['config'] as String?);

  final CliOptions cli;
  try {
    cli = await resolveCliOptions(
      args,
      config,
      selectDrive: () async => (await Menu.selectDrive()).device,
    );
  } on CliOptionsError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final opts   = cli.rip;
  final device = cli.device;

  if (cli.isMkv) {
    await processMkv(opts, device, prompter: Menu.prompter);
    return;
  }
  if (cli.isDir) {
    if (!await processDirectory(opts, device, prompter: Menu.prompter)) exit(1);
    return;
  }

  // --- Detect disc type and rip ---
  // try/catch so a _RipAborted thrown from inside withMountedDisc unwinds
  // through the mount cleanup (finally) before we exit.
  try {
  if (cli.isIso) {
    // ISO: one mount cycle covers type detection + scan + rip.
    await withMountedDisc<void>(device, (mountPath) async {
      final discType = DiscTypeDetector.detectFromMountPoint(mountPath);
      stdout.writeln('Disc type: ${_discTypeLabel(discType)}');
      stdout.writeln('ISO:       $device');
      stdout.writeln('Output:    ${cli.outputDir}');
      stdout.writeln('ffmpeg:    ${opts.ffmpeg}');
      stdout.writeln('');
      switch (discType) {
        case DiscType.audioCD:
          await _ripAudioCD(opts.copyWithOutputDir(cli.musicOutputDir));
        case DiscType.dvd:
          await _ripVideoDisc(DVDRipper(opts, prompter: Menu.prompter, onFfmpegProcess: _trackFfmpeg),
            autoSelect:    autoSelectDvd,
            opts:          opts,
            mountPath:     mountPath,
            errorContext:  'DVD',
            prepareTitles: deduplicateDvdTitles,
          );
        case DiscType.bluray:
          await _ripVideoDisc(BlurayRipper(opts, prompter: Menu.prompter, onFfmpegProcess: _trackFfmpeg),
            autoSelect:   autoSelectBluray,
            opts:         opts,
            mountPath:    mountPath,
            errorContext: 'Blu-ray',
          );
        case DiscType.unknown:
          throw const _RipAborted('Unknown disc type — cannot rip.');
      }
    }, errorContext: 'disc');
    return;
  }

  // Block device: loop to support "eject and load next disc" (answer 'r').
  // On the first run with an interactive-menu drive the disc is already present,
  // so _waitForDisc returns immediately.  On subsequent iterations (afterEject)
  // the function first waits for the tray to empty, then waits for a new disc.
  var looping  = false;
  var skipWait = false; // set after a disc-swap rescan: the new disc is present
  while (true) {
    if (!skipWait && (cli.inputGiven || looping)) {
      await _waitForDisc(device, afterEject: looping);
    }
    skipWait = false;

    // Detect without mounting; one mount cycle covers scan + rip.
    final discType = await DiscTypeDetector.detect(device);

    final effectiveOutput =
        discType == DiscType.audioCD ? cli.musicOutputDir : cli.outputDir;
    stdout.writeln('Disc type: ${_discTypeLabel(discType)}');
    stdout.writeln('Device:    $device');
    stdout.writeln('Output:    $effectiveOutput');
    stdout.writeln('ffmpeg:    ${opts.ffmpeg}');
    stdout.writeln('');

    bool continueLoop;
    try {
      switch (discType) {
        case DiscType.audioCD:
          continueLoop = await _ripAudioCD(opts.copyWithOutputDir(cli.musicOutputDir));
        case DiscType.dvd:
          continueLoop = await _ripVideoDisc(DVDRipper(opts, prompter: Menu.prompter, onFfmpegProcess: _trackFfmpeg),
            autoSelect:    autoSelectDvd,
            opts:          opts,
            errorContext:  'DVD',
            prepareTitles: deduplicateDvdTitles,
          );
        case DiscType.bluray:
          continueLoop = await _ripVideoDisc(BlurayRipper(opts, prompter: Menu.prompter, onFfmpegProcess: _trackFfmpeg),
            autoSelect:   autoSelectBluray,
            opts:         opts,
            errorContext: 'Blu-ray',
          );
        case DiscType.unknown:
          stderr.writeln('Unknown disc type — cannot rip.');
          continueLoop = false;
      }
    } on DiscChangedException {
      // The exception unwound through withMountedDisc, so the stale mount is
      // already cleaned up; re-detect the disc that is now in the drive.
      stderr.writeln('Error: the disc in the drive is not the disc that was '
          'scanned — it was swapped during selection. Rescanning...');
      stderr.writeln('');
      skipWait = true;
      continue;
    }

    if (!continueLoop) break;
    looping = true;
  }
  } on _RipAborted catch (e) {
    if (e.message != null) stderr.writeln('Error: ${e.message}');
    exit(1);
  }
}

String _discTypeLabel(DiscType t) => switch (t) {
      DiscType.audioCD => 'audiocd',
      DiscType.dvd     => 'dvd',
      DiscType.bluray  => 'bluray',
      DiscType.unknown => 'unknown',
    };

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
    // Fingerprint the disc before scanning so a swap during the interactive
    // prompts can be detected right before the rip starts.
    String? scanFp;
    if (!isIso && (opts.device?.startsWith('/dev/') ?? false)) {
      scanFp = await readDiscFingerprint(opts.device!);
      if (scanFp == null) {
        stderr.writeln('Warning: disc has no readable identity — '
            'swap protection unavailable.');
      }
    }

    final result = await ripper.loadTitles(mountPath: mp);
    if (result == null) throw const _RipAborted();

    final discTitle = result.discTitle;
    final titles    = prepareTitles != null
        ? prepareTitles(result.titles)
        : result.titles;

    final suggestion = autoSelect(titles);

    // Minor clips are listed only on request, but stay selectable by key.
    final minorKeys = minorTitleKeys(titles, suggestion);
    final listed    = titles.where((t) => !minorKeys.contains(t.displayKey));

    stdout.writeln('Disc:  $discTitle');
    stdout.writeln('Titles found: ${listed.length}'
        '${minorKeys.isEmpty ? '' : ' (+${minorKeys.length} under '
            '${minorTitleDuration.inSeconds} s, not listed)'}');
    stdout.writeln('');
    stdout.writeln('Available titles:');
    for (final t in listed) {
      final subLabel = switch (t) {
        DvdTitle(:final mayHaveCc) when mayHaveCc => '  CC',
        _ => '  ${t.subtitleStreamCount.toString().padLeft(2)} sub',
      };
      stdout.writeln(
        '  ${t.displayKey.padLeft(4)}: ${t.durationLabel}'
        '  ${t.audioStreamCount} audio'
        '$subLabel'
        '  ${t.chapters.length.toString().padLeft(2)} ch'
        '${t.extraInfo ?? ''}',
      );
    }
    stdout.writeln('');

    final titleMap   = {for (final t in titles) t.displayKey: t};
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

    final namePrefs = await collectNamingPrefs(
      opts,
      selected.map((t) => (
            filename:     t.filename,
            displayKey:   t.displayKey,
            hasSubtitles: t.hasSubtitles,
          )).toList(),
      Menu.prompter,
      defaultStemOf: (filename) => defaultStem(discTitle, filename),
    );

    final autoNameCount = namePrefs.values.where((v) => v == '?').length;
    final resolvedBatchAssign =
        await promptBatchAssign(opts, autoNameCount, Menu.prompter);

    final extractChoice = opts.canOcrSubtitles && !opts.force
        ? await promptExtractSubtitles(opts, Menu.prompter)
        : noExtract;

    // Ask naming hints upfront so no questions interrupt the rip.
    final namingHints = namePrefs.containsValue('?') && !opts.force
        ? await askNamingHints(opts, Menu.prompter)
        : null;

    // Guard: refuse if the disc was swapped during the prompts above.
    if (scanFp != null) await verifyDiscUnchanged(opts.device!, scanFp);

    await ripper.rip(discTitle, selected, mountPath: mp);

    final outDir = Directory(p.join(opts.outputDir, sanitizeFilename(discTitle)));
    await resolveSubtitlesAndNames(
      opts, outDir, discTitle,
      selected.map((t) => (filename: t.filename, displayKey: t.displayKey)).toList(),
      namePrefs,
      doExtract: extractChoice.doExtract,
      extractLangs: extractChoice.langs,
      namingHints: namingHints,
      batchAssign: resolvedBatchAssign,
    );

    await applyRenames(outDir, discTitle,
        selected.map((t) => t.filename).toList(), namePrefs);

    if (!isIso) {
      final action = await _promptEject(opts);
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
  final ripper = AudioCDRipper(opts, prompter: Menu.prompter, onFfmpegProcess: _trackFfmpeg);

  String? scanFp;
  if (opts.device?.startsWith('/dev/') ?? false) {
    scanFp = await readDiscFingerprint(opts.device!, discType: DiscType.audioCD);
  }

  final meta = await ripper.loadMetadata();
  if (meta == null) throw const _RipAborted();

  stdout.writeln('Album:   ${meta.album}');
  if (meta.artist.isNotEmpty) stdout.writeln('Artist:  ${meta.artist}');
  if (meta.date.isNotEmpty)   stdout.writeln('Year:    ${meta.date}');
  if (meta.discNumber > 0)    stdout.writeln('Disc:    ${meta.discNumber}');
  stdout.writeln('');
  stdout.writeln('Available tracks:');

  for (final track in meta.tracks) {
    final displayArtist = track.artist.isNotEmpty ? track.artist : meta.artist;
    final artistSuffix  =
        displayArtist.isNotEmpty ? '  — $displayArtist' : '';
    stdout.writeln(
        '  ${track.number.toString().padLeft(2)}: '
        '[${track.durationLabel}]  ${track.title}$artistSuffix');
  }

  final selected = Menu.selectTracks(meta.tracks.length);

  // Guard: refuse if the disc was swapped during track selection.
  if (scanFp != null) {
    await verifyDiscUnchanged(opts.device!, scanFp, discType: DiscType.audioCD);
  }

  await ripper.rip(meta, selected);

  final action = await _promptEject(opts);
  if (action != _EjectAction.none) await Process.run('eject', [opts.device!]);
  return action == _EjectAction.ejectAndContinue;
}

// ---------------------------------------------------------------------------
// Eject + disc waiting
// ---------------------------------------------------------------------------

enum _EjectAction { none, ejectOnly, ejectAndContinue }

/// Three-way eject prompt shown after every successful rip.
///
///   y / j  → eject disc and stop
///   r      → eject disc and load next (restart for the same drive)
///   N      → don't eject
///
/// When [opts.loop] is set the prompt is skipped and `ejectAndContinue` is
/// returned automatically.
Future<_EjectAction> _promptEject(RipOptions opts) async {
  if (opts.loop) {
    stdout.writeln('\nEject disc? [y/r/N]  (r = load next disc): r');
    return _EjectAction.ejectAndContinue;
  }
  final answer = (await Menu.prompter
          .readLine('\nEject disc? [y/r/N]  (r = load next disc): '))
      .trim()
      .toLowerCase();
  return switch (answer) {
    'y' || 'j' => _EjectAction.ejectOnly,
    'r'        => _EjectAction.ejectAndContinue,
    _          => _EjectAction.none,
  };
}

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
