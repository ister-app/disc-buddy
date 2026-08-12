import 'package:disc_buddy/disc_buddy.dart';
import 'package:disc_buddy/src/device/drive_status.dart';
import 'package:test/test.dart';

void main() {
  group('driveResponds', () {
    test('a device node that does not exist cannot respond', () {
      expect(driveResponds('/dev/definitely-not-a-drive'), isFalse);
    });

    test('a regular file rejects the SCSI ioctl', () {
      // Opens fine, but SG_IO fails on anything that is not a SCSI device —
      // the guard must key on the ioctl result, not on the open() succeeding.
      expect(driveResponds('/dev/null'), isFalse);
    });
  });

  group('DiscStatus.unreachable', () {
    DriveInfo info(DiscStatus s) =>
        DriveInfo(device: '/dev/sr9', vendor: 'ACME', model: 'X1', status: s);

    test('reads differently from an empty tray', () {
      expect(info(DiscStatus.unreachable).statusLabel,
          isNot(info(DiscStatus.ejected).statusLabel));
      expect(info(DiscStatus.unreachable).statusLabel,
          isNot(info(DiscStatus.noDisc).statusLabel));
    });

    test('names the hardware as the suspect', () {
      expect(info(DiscStatus.unreachable).statusLabel,
          contains('not responding'));
    });
  });
}
