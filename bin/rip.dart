import 'dart:io';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy/src/cli/menu.dart';
import 'package:disc_buddy/src/cli/title_selector.dart';
import 'package:disc_buddy/src/device/disc_type_detector.dart';
import 'package:disc_buddy/src/rippers/audiocd_ripper.dart';
import 'package:disc_buddy/src/utils/mount.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('device',  abbr: 'd', help: 'Optical device (e.g. /dev/sr0)',
        defaultsTo: Platform.environment['DISC_DEVICE'])
    ..addOption('iso',     abbr: 'i', help: 'ISO image file path',
        defaultsTo: Platform.environment['DISC_ISO'])
    ..addOption('output',  abbr: 'o', help: 'Output directory',
        defaultsTo: Platform.environment['OUTDIR'] ??
            p.join(Directory.current.path, 'output'))
    ..addOption('ffmpeg',  help: 'Path to ffmpeg',  defaultsTo: 'ffmpeg')
    ..addOption('ffprobe', help: 'Path to ffprobe', defaultsTo: 'ffprobe')
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
    stdout.writeln(parser.usage);
    exit(0);
  }

  // --- Verify ffmpeg binaries ---
  final ffmpegBin  = args['ffmpeg']  as String;
  final ffprobeBin = args['ffprobe'] as String;
  for (final bin in [ffmpegBin, ffprobeBin]) {
    final which = await Process.run('which', [bin]);
    if (which.exitCode != 0) {
      stderr.writeln('Error: "$bin" not found in PATH.');
      exit(1);
    }
  }

  final rawDevice = args['device'] as String? ?? '';
  final rawIso    = args['iso']    as String? ?? '';

  if (rawDevice.isNotEmpty && rawIso.isNotEmpty) {
    stderr.writeln('Error: --device and --iso are mutually exclusive.');
    exit(1);
  }

  // --- Select source (drive or ISO) ---
  final bool isIso;
  final String device;

  if (rawIso.isNotEmpty) {
    // ISO file given explicitly.
    if (!File(rawIso).existsSync()) {
      stderr.writeln('Error: ISO file not found: $rawIso');
      exit(1);
    }
    isIso  = true;
    device = rawIso;
  } else if (rawDevice.isNotEmpty) {
    isIso  = false;
    device = rawDevice;
  } else {
    // Interactive drive selection.
    final drive = await Menu.selectDrive();
    isIso  = false;
    device = drive.device;
  }

  final outputDir = args['output'] as String;
  final opts = RipOptions(
    device: device,
    outputDir: outputDir,
    ffmpeg: ffmpegBin,
    ffprobe: ffprobeBin,
    force: args['force'] as bool,
  );

  // --- Detect disc type ---
  final DiscType discType;
  if (isIso) {
    // For ISO files, detect by inspecting directory structure after mounting.
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
    final angleStr = title.totalAngles > 1
        ? '  (angle ${title.pgcIndex + 1}/${title.totalAngles})'
        : '';
    final nc = title.chapters.length;
    stdout.writeln(
      '  ${title.displayKey.padLeft(4)}: ${title.durationLabel}'
      '  $na audio  ${ns.toString().padLeft(2)} sub'
      '  ${nc.toString().padLeft(2)} ch$angleStr',
    );
  }

  stdout.writeln('');

  final titleMap  = {for (final t in titles) t.displayKey: t};
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
            final t = titles.where(
              (t) => t.vtsNumber.toString() == k && t.pgcIndex == 0,
            ).toList();
            return t;
          })
          .toList();
    }
  }

  await ripper.rip(discTitle, selected);

  if (!isIso && Menu.confirm('\nEject disc? [y/N] ')) {
    await Process.run('eject', [opts.device!]);
  }
}

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
          .expand((k) {
            if (titleMap.containsKey(k)) return [titleMap[k]!];
            return <BlurayTitle>[];
          })
          .toList();
    }
  }

  await ripper.rip(discTitle, selected);

  if (!isIso && Menu.confirm('\nEject disc? [y/N] ')) {
    await Process.run('eject', [opts.device!]);
  }
}

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
    final artistSuffix =
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
