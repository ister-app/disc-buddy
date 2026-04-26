import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// libc bindings (same pattern as cdrom_toc.dart)
// ---------------------------------------------------------------------------

final _libc = DynamicLibrary.open('libc.so.6');

typedef _OpenC    = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int   Function(Pointer<Utf8>, int);
final _dsOpen = _libc.lookupFunction<_OpenC, _OpenDart>('open');

typedef _IoctlC    = Int32 Function(Int32, Uint64, Pointer<Void>);
typedef _IoctlDart = int   Function(int,   int,    Pointer<Void>);
final _dsIoctl = _libc.lookupFunction<_IoctlC, _IoctlDart>('ioctl');

typedef _CloseC    = Int32 Function(Int32);
typedef _CloseDart = int   Function(int);
final _dsClose = _libc.lookupFunction<_CloseC, _CloseDart>('close');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _kCdromDriveStatus = 0x5326;
const _kCdslCurrent      = 0x7FFFFFFE; // CDSL_CURRENT — single-slot drive

const _oRdonly   = 0;
const _oNonblock = 2048;

/// Tray open / ejected.
const kCdsTrayOpen      = 2;

/// Drive present, disc spinning up or not yet ready.
const kCdsDriveNotReady = 3;

/// No disc in closed tray.
const kCdsNoDisc        = 1;

/// Disc present and readable.
const kCdsDiscOk        = 4;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Reads the hardware tray state of an optical device via
/// the `CDROM_DRIVE_STATUS` ioctl (0x5326).
///
/// Returns one of the `kCds*` constants, or null on error.
int? readDriveStatus(String device) {
  return using((arena) {
    final fd = _dsOpen(
      device.toNativeUtf8(allocator: arena),
      _oRdonly | _oNonblock,
    );
    if (fd < 0) return null;
    try {
      final r = _dsIoctl(
        fd,
        _kCdromDriveStatus,
        Pointer<Void>.fromAddress(_kCdslCurrent),
      );
      return r >= 0 ? r : null;
    } finally {
      _dsClose(fd);
    }
  });
}
