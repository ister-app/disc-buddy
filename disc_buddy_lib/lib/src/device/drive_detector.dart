import 'dart:io';
import '../models/drive_info.dart';
import '../utils/udev.dart';
import 'drive_status.dart';

class DriveDetector {

  /// Returns all optical drives on the system.
  static Future<List<DriveInfo>> detect() async {
    final result = await Process.run(
      'lsblk', ['-d', '-n', '-o', 'NAME,TYPE'],
    );
    final devices = (result.stdout as String)
        .split('\n')
        .where((line) => line.trim().endsWith('rom'))
        .map((line) => '/dev/${line.trim().split(RegExp(r'\s+')).first}')
        .toList();

    return Future.wait(devices.map(_queryDrive));
  }

  static Future<DriveInfo> _queryDrive(String device) async {
    final result = await Process.run(
      'udevadm', ['info', '--query=property', '--name=$device'],
    );
    final props = parseUdevProps(result.stdout as String);

    final vendor = (props['ID_VENDOR'] ?? '').replaceAll('_', ' ').trim();
    final model  = (props['ID_MODEL']  ?? '').replaceAll('_', ' ').trim();

    // Step 1: hardware tray state via ioctl (udevadm cannot report this)
    final hw = readDriveStatus(device);
    if (hw == kCdsTrayOpen) {
      // An open tray and a drive that fell off the bus both report
      // CDS_TRAY_OPEN; only a transport-level probe separates them.
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: driveResponds(device)
            ? DiscStatus.ejected
            : DiscStatus.unreachable,
      );
    }
    if (hw == kCdsDriveNotReady) {
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: DiscStatus.loading,
      );
    }
    if (hw == kCdsNoDisc) {
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: DiscStatus.noDisc,
      );
    }

    // hw == kCdsDiscOk or null/kCdsNoInfo → use udevadm for disc type
    final hasMedia    = props['ID_CDROM_MEDIA'] == '1';
    final audioTracks = int.tryParse(props['ID_CDROM_MEDIA_TRACK_COUNT_AUDIO'] ?? '') ?? 0;

    if (!hasMedia) {
      // udev also reports no medium for a drive it can no longer talk to
      // (its properties simply stop being refreshed), so probe here too.
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: driveResponds(device)
            ? DiscStatus.noDisc
            : DiscStatus.unreachable,
      );
    }

    // Audio CD: audio tracks present (CD Extra / Enhanced CD included)
    if (audioTracks > 0) {
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: DiscStatus.audioCD,
        audioCDTracks: audioTracks,
        mediaId: mediaIdFromProps(props),
      );
    }

    // Data disc: read label from udev cache (already fetched above — no disc access needed).
    final label = (props['ID_FS_LABEL'] ?? props['ID_FS_LABEL_ENC'] ?? '').trim();

    return DriveInfo(
      device: device, vendor: vendor, model: model,
      status: DiscStatus.dataDisc,
      label: label,
      mediaId: mediaIdFromProps(props),
    );
  }

}
