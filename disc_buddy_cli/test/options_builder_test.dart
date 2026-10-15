import 'package:disc_buddy_cli/src/cli/options_builder.dart';
import 'package:test/test.dart';

Future<CliOptions> resolve(
  List<String> argv, {
  Map<String, dynamic> config = const {},
  Map<String, String> env = const {},
  Set<String> existingFiles = const {},
  Set<String> existingDirs = const {},
  Set<String> binaries = const {'ffmpeg', 'ffprobe'},
}) =>
    resolveCliOptions(
      buildArgParser().parse(argv),
      config,
      env: env,
      binaryExists: (b) async => binaries.contains(b),
      fileExists: existingFiles.contains,
      dirExists: existingDirs.contains,
      xdgUserDirLookup: (name, {required fallback}) => '/xdg/$name',
    );

void main() {
  group('resolveCliOptions', () {
    test('CLI-waarde wint van config', () async {
      final cli = await resolve(
        ['-i', '/dev/sr0', '--llm-model', 'cli-model', '--ffmpeg', 'ffmpeg'],
        config: {'llm-model': 'cfg-model', 'tmdb-token': 'tok'},
        existingFiles: {'/dev/sr0'},
      );
      expect(cli.rip.llmModel, 'cli-model');
      expect(cli.rip.tmdbToken, 'tok');
      expect(cli.rip.device, '/dev/sr0');
      expect(cli.isIso, isFalse);
      expect(cli.isMkv, isFalse);
      expect(cli.isDir, isFalse);
      expect(cli.inputGiven, isTrue);
    });

    test('output-dir fallbackketen: flag → config → OUTDIR → XDG', () async {
      Future<String> out({List<String> extra = const [], Map<String, dynamic> cfg = const {}, Map<String, String> env = const {}}) async =>
          (await resolve(['-i', '/dev/sr0', ...extra], config: cfg, env: env, existingFiles: {'/dev/sr0'})).outputDir;

      expect(await out(extra: ['--video-output', '/flag'], cfg: {'output': '/cfg'}, env: {'OUTDIR': '/env'}), '/flag');
      expect(await out(cfg: {'output': '/cfg'}, env: {'OUTDIR': '/env'}), '/cfg');
      expect(await out(env: {'OUTDIR': '/env'}), '/env');
      expect(await out(), '/xdg/VIDEOS');
    });

    test('music-output valt terug op XDG MUSIC', () async {
      final cli = await resolve(['-i', '/dev/sr0'], existingFiles: {'/dev/sr0'});
      expect(cli.musicOutputDir, '/xdg/MUSIC');
    });

    test('invoertype: map, mkv, iso', () async {
      final dir = await resolve(['-i', '/videos'], existingDirs: {'/videos'});
      expect(dir.isDir, isTrue);
      expect(dir.rip.device, isNull);

      final mkv = await resolve(['-i', '/a/Film.MKV'], existingFiles: {'/a/Film.MKV'});
      expect(mkv.isMkv, isTrue);
      expect(mkv.rip.device, isNull);

      final iso = await resolve(['-i', '/a/disc.iso'], existingFiles: {'/a/disc.iso'});
      expect(iso.isIso, isTrue);
      expect(iso.rip.device, '/a/disc.iso');
    });

    test('ontbrekende invoer geeft CliOptionsError', () async {
      expect(() => resolve(['-i', '/dev/sr9']), throwsA(isA<CliOptionsError>()));
      expect(() => resolve(['-i', '/nope.iso']), throwsA(isA<CliOptionsError>()));
    });

    test('ontbrekende ffmpeg geeft CliOptionsError', () async {
      expect(
        () => resolve(['-i', '/dev/sr0'], existingFiles: {'/dev/sr0'}, binaries: {'ffprobe'}),
        throwsA(predicate((e) => e is CliOptionsError && e.message.contains('ffmpeg'))),
      );
    });

    test('optionele tools: expliciet pad moet bestaan, anders /usr/bin-probe', () async {
      final probed = await resolve(['-i', '/dev/sr0'],
          existingFiles: {'/dev/sr0', '/usr/bin/mkvextract'});
      expect(probed.rip.mkvextract, '/usr/bin/mkvextract');
      expect(probed.rip.subtileOcr, isNull);

      expect(
        () => resolve(['-i', '/dev/sr0', '--mkvextract', '/opt/mkvx'],
            existingFiles: {'/dev/sr0'}),
        throwsA(isA<CliOptionsError>()),
      );
    });

    test('--force, --auto-name, --loop en seizoenen', () async {
      final cli = await resolve(
        ['-i', '/dev/sr0', '--force', '--auto-name', '--loop', '--season', '3,4', '--subtitle-langs', 'en,nl'],
        existingFiles: {'/dev/sr0'},
      );
      expect(cli.rip.force, isTrue);
      expect(cli.rip.autoName, isTrue);
      expect(cli.rip.loop, isTrue);
      expect(cli.rip.seasonHint, [3, 4]);
      expect(cli.rip.subtitleLangs, {'en', 'nl'});
    });

    test('flags uit config als ze niet op de CLI staan', () async {
      final cli = await resolve(['-i', '/dev/sr0'],
          config: {'lpcm-flac': true, 'dvd-single-pass': true, 'batch-assign': false},
          existingFiles: {'/dev/sr0'});
      expect(cli.rip.lpcmFlac, isTrue);
      expect(cli.rip.dvdSinglePass, isTrue);
      expect(cli.rip.batchAssign, isFalse);
    });

    test('zonder -i wordt de drive-selector gebruikt', () async {
      final cli = await resolveCliOptions(
        buildArgParser().parse([]),
        {},
        env: {},
        binaryExists: (_) async => true,
        fileExists: (_) => false,
        dirExists: (_) => false,
        selectDrive: () async => '/dev/sr1',
        xdgUserDirLookup: (n, {required fallback}) => fallback,
      );
      expect(cli.device, '/dev/sr1');
      expect(cli.inputGiven, isFalse);
    });
  });

  group('parse helpers', () {
    test('parseSeasons', () {
      expect(parseSeasons('1,3 5'), [1, 3, 5]);
      expect(parseSeasons(' ? '), isNull);
      expect(parseSeasons(''), isNull);
      expect(parseSeasons('abc'), isNull);
      expect(parseSeasons(null), isNull);
    });

    test('parseSubtitleLangs', () {
      expect(parseSubtitleLangs(null), isNull);
      expect(parseSubtitleLangs(''), isEmpty);
      expect(parseSubtitleLangs('ALL'), isEmpty);
      expect(parseSubtitleLangs('EN, nl'), {'en', 'nl'});
    });

    test('isBlockDevice', () {
      expect(isBlockDevice('/dev/sr0'), isTrue);
      expect(isBlockDevice('/home/x.iso'), isFalse);
    });
  });
}
