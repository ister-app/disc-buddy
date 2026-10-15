import 'dart:io';

import 'package:args/args.dart';
import 'package:disc_buddy/disc_buddy.dart';

import 'version.dart';

/// Thrown for a usage/configuration error that should end the program with
/// a message and a non-zero exit code (the caller decides how to exit).
class CliOptionsError implements Exception {
  const CliOptionsError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything `main` needs after argument/config resolution.
class CliOptions {
  const CliOptions({
    required this.rip,
    required this.device,
    required this.outputDir,
    required this.musicOutputDir,
    required this.isIso,
    required this.isMkv,
    required this.isDir,
    required this.inputGiven,
  });

  final RipOptions rip;
  /// Drive node, ISO path, MKV path or directory path.
  final String device;
  final String outputDir;
  final String musicOutputDir;
  final bool isIso;
  final bool isMkv;
  final bool isDir;
  /// Whether `-i` was given (as opposed to the interactive drive menu).
  final bool inputGiven;
}

ArgParser buildArgParser() => ArgParser()
  ..addOption('config',  abbr: 'c', help: 'Path to config file (default: ${ConfigLoader.defaultPath})')
  ..addOption('input',   abbr: 'i',
      help: 'Optical drive (e.g. /dev/sr0), ISO image, MKV file, or directory of video files',
      defaultsTo: Platform.environment['DISC_ISO'] ?? Platform.environment['DISC_DEVICE'])
  ..addOption('video-output', help: 'Output directory for video discs',
      defaultsTo: null)
  ..addOption('music-output', help: 'Output directory for audio CDs',
      defaultsTo: null)
  ..addOption('ffmpeg',       help: 'Path to ffmpeg',       defaultsTo: null)
  ..addOption('ffprobe',      help: 'Path to ffprobe',      defaultsTo: null)
  ..addOption('mkvextract',   help: 'Path to mkvextract')
  ..addOption('subtile-ocr',  help: 'Path to subtile-ocr')
  ..addOption('tmdb-token',   help: 'The Movie Database API read access token')
  ..addOption('whisper',      help: 'Path to whisper-cli (whisper.cpp) — audio-transcription fallback for auto-naming titles without subtitles')
  ..addOption('whisper-model', help: 'Path to the whisper.cpp ggml model file (e.g. ggml-base.en.bin)')
  ..addOption('transcribe-lang', help: 'Spoken language for whisper transcription (ISO 639-1, e.g. nl). Default: the audio track\'s language tag, else auto-detect per window')
  ..addOption('llm-url',      help: 'OpenAI-compatible LLM base URL (e.g. http://localhost:11434/v1)')
  ..addOption('llm-key',      help: 'LLM API key (default: "ollama" for local)')
  ..addOption('llm-model',    help: 'LLM model name (e.g. gpt-4o, llama3)')
  ..addOption('name',    abbr: 'n', help: 'Film or series title hint for auto-naming')
  ..addOption('season',             help: 'Season number hint for auto-naming (implies series)')
  ..addFlag('force',        abbr: 'f', negatable: false,
      help: 'Overwrite existing files; skip language prompts')
  ..addFlag('auto-name',    abbr: 'a', negatable: false,
      help: 'Automatically use LLM auto-naming for all titles or files (skips rename prompt)')
  ..addFlag('batch-assign', defaultsTo: null,
      help: 'Send all subtitle excerpts in one LLM call for episode matching '
            '(better accuracy with large models; ask if omitted)')
  ..addOption('subtitle-langs',
      help: 'Comma-separated subtitle languages to extract (e.g. en,nl). '
            'Omit to be asked interactively; use "all" or empty to extract everything.')
  ..addFlag('lpcm-flac', negatable: false,
      help: 'Re-encode Blu-ray LPCM audio to FLAC (smaller files, slower). '
            'Default keeps LPCM as raw PCM, which is much faster.')
  ..addFlag('dvd-single-pass', defaultsTo: false,
      help: 'Map DVD streams by id in a single read instead of a pre-scan. '
            'Mainly helps slow optical drives; uses more memory on fast media.')
  ..addFlag('loop',         abbr: 'l', negatable: false,
      help: 'After each rip, eject and wait for the next disc automatically')
  ..addFlag('version',   abbr: 'v', negatable: false, help: 'Show version ($buildVersion)')
  ..addFlag('help',      abbr: 'h', negatable: false, help: 'Show help');

/// Resolves [args] (CLI wins) over [config] into a [CliOptions].
///
/// Side effects are injectable so the resolution can be unit-tested:
/// [env] replaces `Platform.environment`, [binaryExists] replaces the
/// `which` lookup for ffmpeg/ffprobe, [fileExists]/[dirExists] replace the
/// filesystem checks and [selectDrive] replaces the interactive drive menu
/// used when no `-i` is given.
Future<CliOptions> resolveCliOptions(
  ArgResults args,
  Map<String, dynamic> config, {
  Map<String, String>? env,
  Future<bool> Function(String bin)? binaryExists,
  bool Function(String path)? fileExists,
  bool Function(String path)? dirExists,
  Future<String> Function()? selectDrive,
  String Function(String name, {required String fallback})? xdgUserDirLookup,
}) async {
  env ??= Platform.environment;
  binaryExists ??= (bin) async => (await Process.run('which', [bin])).exitCode == 0;
  fileExists ??= (p) => File(p).existsSync();
  dirExists ??= (p) => Directory(p).existsSync();
  final userDir = xdgUserDirLookup ??
      ((name, {required fallback}) => xdgUserDir(name, fallback: fallback));

  String cfgStr(String key, String fallback) =>
      (args[key] as String?) ?? (config[key] as String?) ?? fallback;
  String? cfgOpt(String key) =>
      (args[key] as String?) ?? (config[key] as String?);

  // --- Verify ffmpeg binaries ---
  final ffmpegBin  = cfgStr('ffmpeg',  'ffmpeg');
  final ffprobeBin = cfgStr('ffprobe', 'ffprobe');
  for (final bin in [ffmpegBin, ffprobeBin]) {
    if (!await binaryExists(bin)) {
      throw CliOptionsError('Error: "$bin" not found in PATH.');
    }
  }

  // --- Detect optional tools: explicit path must exist, else /usr/bin probe ---
  String? optionalTool(String key, String label, String usrBin) {
    final explicit = cfgOpt(key);
    if (explicit != null) {
      if (!fileExists!(explicit)) {
        throw CliOptionsError('Error: $label not found at "$explicit".');
      }
      return explicit;
    }
    return fileExists!(usrBin) ? usrBin : null;
  }

  final mkvextractBin = optionalTool('mkvextract', 'mkvextract', '/usr/bin/mkvextract');
  final subtileOcrBin = optionalTool('subtile-ocr', 'subtile-ocr', '/usr/bin/subtile-ocr');
  final whisperBin    = optionalTool('whisper', 'whisper-cli', '/usr/bin/whisper-cli');

  // The ggml model has no conventional install location — explicit path only.
  final whisperModelPath = cfgOpt('whisper-model');
  if (whisperModelPath != null && !fileExists(whisperModelPath)) {
    throw CliOptionsError('Error: whisper model not found at "$whisperModelPath".');
  }

  final rawInput = args['input'] as String? ?? '';

  // Validate -i target.
  if (rawInput.isNotEmpty) {
    if (isBlockDevice(rawInput)) {
      // Optical drives are block-device nodes; regular file checks don't apply.
      if (!fileExists(rawInput)) {
        throw CliOptionsError('Error: drive not found: $rawInput');
      }
    } else if (!dirExists(rawInput) && !fileExists(rawInput)) {
      throw CliOptionsError('Error: file or directory not found: $rawInput');
    }
  }

  // --- Select source (drive, ISO image, MKV file, or video directory) ---
  final bool isIso;
  final bool isMkv;
  final bool isDir;
  final String device;

  if (rawInput.isNotEmpty) {
    if (dirExists(rawInput)) {
      isDir  = true;
      isMkv  = false;
      isIso  = false;
      device = rawInput;
    } else if (isBlockDevice(rawInput)) {
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
    if (selectDrive == null) {
      throw const CliOptionsError('Error: no input given and no drive menu available.');
    }
    isDir  = false;
    isMkv  = false;
    isIso  = false;
    device = await selectDrive();
  }

  // CLI flag is --video-output; config-file key is 'output' (shared with the UI).
  final outputDir =
      (args['video-output'] as String?) ??
      (config['output'] as String?) ??
      env['OUTDIR'] ??
      userDir('VIDEOS', fallback: r'$HOME/Videos');
  final musicOutputDir =
      (args['music-output'] as String?) ??
      (config['music-output'] as String?) ??
      userDir('MUSIC', fallback: r'$HOME/Music');

  final rip = RipOptions(
    device:     (isMkv || isDir) ? null : device,
    outputDir:  outputDir,
    ffmpeg:     ffmpegBin,
    ffprobe:    ffprobeBin,
    force:      args['force']     as bool,
    autoName:   args['auto-name'] as bool,
    loop:       args['loop']      as bool,
    mkvextract: mkvextractBin,
    subtileOcr: subtileOcrBin,
    whisper:      whisperBin,
    whisperModel: whisperModelPath,
    transcribeLanguage: cfgOpt('transcribe-lang'),
    tmdbToken:  cfgOpt('tmdb-token'),
    llmUrl:     cfgOpt('llm-url'),
    llmKey:     cfgOpt('llm-key'),
    llmModel:   cfgOpt('llm-model'),
    titleHint:   cfgOpt('name'),
    seasonHint:  parseSeasons(cfgOpt('season')),
    batchAssign:    (args['batch-assign'] as bool?) ??
        (config['batch-assign'] as bool?),
    subtitleLangs:  parseSubtitleLangs(cfgOpt('subtitle-langs')),
    lpcmFlac:       args.wasParsed('lpcm-flac')
        ? args['lpcm-flac'] as bool
        : (config['lpcm-flac'] as bool?) ?? false,
    dvdSinglePass:  args.wasParsed('dvd-single-pass')
        ? args['dvd-single-pass'] as bool
        : (config['dvd-single-pass'] as bool?) ?? false,
  );

  return CliOptions(
    rip: rip,
    device: device,
    outputDir: outputDir,
    musicOutputDir: musicOutputDir,
    isIso: isIso,
    isMkv: isMkv,
    isDir: isDir,
    inputGiven: rawInput.isNotEmpty,
  );
}

/// Parses `--subtitle-langs` value. Returns null (ask) if omitted,
/// empty set (all) for "all"/empty, or the set of 2-letter codes.
Set<String>? parseSubtitleLangs(String? input) {
  if (input == null) return null;
  final trimmed = input.trim().toLowerCase();
  if (trimmed.isEmpty || trimmed == 'all') return const {};
  return trimmed.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toSet();
}

/// Parses a season string into a list of season numbers.
///
/// Accepts comma- or space-separated integers, e.g. `"5"`, `"5,6"`, `"5 6"`.
/// Returns null when the input is empty, `?`, or contains no valid integers.
List<int>? parseSeasons(String? input) {
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
bool isBlockDevice(String path) => path.startsWith('/dev/');
