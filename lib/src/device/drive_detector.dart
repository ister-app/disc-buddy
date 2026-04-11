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
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: DiscStatus.ejected,
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
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: DiscStatus.noDisc,
      );
    }

    // Audio CD: audio tracks present (CD Extra / Enhanced CD included)
    if (audioTracks > 0) {
      return DriveInfo(
        device: device, vendor: vendor, model: model,
        status: DiscStatus.audioCD,
        audioCDTracks: audioTracks,
      );
    }

    // Data disc: try to fetch the filesystem label
    final blkid = await Process.run('blkid', ['-s', 'LABEL', '-o', 'value', device]);
    if (blkid.exitCode != 0) {
      stderr.writeln('blkid error for $device: ${(blkid.stderr as String).trim()}');
    }
    final label = (blkid.stdout as String).trim();

    return DriveInfo(
      device: device, vendor: vendor, model: model,
      status: DiscStatus.dataDisc,
      label: label,
    );
  }

}
