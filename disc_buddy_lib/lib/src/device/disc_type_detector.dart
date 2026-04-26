import 'dart:io';
import 'package:path/path.dart' as p;
import '../utils/udev.dart';

enum DiscType { audioCD, dvd, bluray, unknown }

class DiscTypeDetector {
  /// Detects the disc type by inspecting the directory structure at [mountPath].
  /// Used for ISO images, which cannot be identified via udevadm.
  static DiscType detectFromMountPoint(String mountPath) {
    if (Directory(p.join(mountPath, 'VIDEO_TS')).existsSync()) return DiscType.dvd;
    if (Directory(p.join(mountPath, 'BDMV')).existsSync())     return DiscType.bluray;
    return DiscType.unknown;
  }

  /// Detects the disc type via udevadm (no mount or root required).
  static Future<DiscType> detect(String device) async {
    final udev = await Process.run(
      'udevadm', ['info', '--query=property', '--name=$device'],
    );
    final props = parseUdevProps(udev.stdout as String);

    // Audio CD
    final audioTracks = int.tryParse(props['ID_CDROM_MEDIA_TRACK_COUNT_AUDIO'] ?? '') ?? 0;
    if ((props['ID_CDROM_MEDIA_CD_AUDIO'] == '1') || audioTracks > 0) {
      return DiscType.audioCD;
    }

    // Blu-ray
    if (props['ID_CDROM_MEDIA_BD']    == '1' ||
        props['ID_CDROM_MEDIA_BD_R']  == '1' ||
        props['ID_CDROM_MEDIA_BD_RE'] == '1') {
      return DiscType.bluray;
    }

    // DVD
    if (props['ID_CDROM_MEDIA_DVD']    == '1' ||
        props['ID_CDROM_MEDIA_DVD_R']  == '1' ||
        props['ID_CDROM_MEDIA_DVD_RW'] == '1' ||
        props['ID_CDROM_MEDIA_DVD_RAM']== '1' ||
        props['ID_CDROM_MEDIA_DVD_PLUS_R']  == '1' ||
        props['ID_CDROM_MEDIA_DVD_PLUS_RW'] == '1') {
      return DiscType.dvd;
    }

    return DiscType.unknown;
  }
}
