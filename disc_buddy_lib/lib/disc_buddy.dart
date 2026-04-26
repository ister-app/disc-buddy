// Public API of the disc_buddy library.
// Pure-Dart modules are usable directly in Flutter.
export 'src/models/drive_info.dart';
export 'src/models/disc_metadata.dart';
export 'src/models/video_title.dart';
export 'src/models/dvd_title.dart';
export 'src/models/bluray_title.dart';
export 'src/models/rip_options.dart';
export 'src/metadata/disc_id.dart';
export 'src/metadata/musicbrainz.dart';
export 'src/metadata/cover_art.dart';
export 'src/rippers/video_disc_ripper.dart';
export 'src/rippers/dvd_ripper.dart';
export 'src/rippers/bluray_ripper.dart';
export 'src/rippers/audiocd_ripper.dart';
export 'src/device/drive_detector.dart';
export 'src/device/disc_type_detector.dart';
export 'src/ffmpeg/ffmpeg_runner.dart' show FfmpegProgress, ProgressCallback;
export 'src/utils/xdg.dart';
export 'src/utils/config_loader.dart';
export 'src/utils/mount.dart' show withMountedDisc;
export 'src/utils/sanitize.dart' show sanitizeFilename;
export 'src/utils/languages.dart' show langMatchesFilter;
export 'src/subtitles/subtitle_extractor.dart';
export 'src/subtitles/cc_extractor.dart';
export 'src/cli/title_selector.dart';
export 'src/naming/auto_namer.dart' show AutoNamer;
export 'src/naming/tmdb_client.dart' show TmdbClient;
export 'src/naming/llm_client.dart' show LlmClient;
