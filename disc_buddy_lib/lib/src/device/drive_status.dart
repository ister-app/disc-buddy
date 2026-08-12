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
// sg_io_hdr_t — identical to Linux <scsi/sg.h>
//
// Deliberately NOT @Packed: see the note in cdrom_toc.dart, which carries the
// same declaration.  Only the header fields are read here (host status), never
// a transferred payload.
// ---------------------------------------------------------------------------

final class _SgIoHdr extends Struct {
  @Int32()   external int interfaceId;
  @Int32()   external int dxferDirection;
  @Uint8()   external int cmdLen;
  @Uint8()   external int mxSbLen;
  @Uint16()  external int ivecCount;
  @Uint32()  external int dxferLen;
  external   Pointer<Void> dxferp;
  external   Pointer<Void> cmdp;
  external   Pointer<Void> sbp;
  @Uint32()  external int timeout;
  @Uint32()  external int flags;
  @Int32()   external int packId;
  external   Pointer<Void> usrPtr;
  @Uint8()   external int status;
  @Uint8()   external int maskedStatus;
  @Uint8()   external int msgStatus;
  @Uint8()   external int sbLenWr;
  @Uint16()  external int hostStatus;
  @Uint16()  external int driverStatus;
  @Int32()   external int resid;
  @Uint32()  external int duration;
  @Uint32()  external int info;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _kCdromDriveStatus = 0x5326;
const _kCdslCurrent      = 0x7FFFFFFE; // CDSL_CURRENT — single-slot drive
const _sgIo              = 0x2285;
const _sgDxferNone       = -1;
const _senseLen          = 32;

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

/// True when the drive still answers at the SCSI transport layer.
///
/// A drive whose link has died reports the same `CDS_TRAY_OPEN` as a genuinely
/// open tray, so the tray state alone cannot tell "empty" from "broken".  A
/// `TEST UNIT READY` can: an open tray produces a valid SCSI answer (CHECK
/// CONDITION with NOT READY sense, host status 0), while a drive the kernel can
/// no longer reach fails in the transport itself — the ioctl errors out, the
/// device node cannot be opened, or the kernel returns a host status such as
/// `DID_NO_CONNECT` (0x01) or `DID_BAD_TARGET` (0x04).
///
/// Observed on a TSSTcorp TS-H653A after libata logged `ata2.00: disable
/// device`: `host=0x04`, no sense data, while a healthy drive answers
/// `host=0x00`.
///
/// Only a clear transport failure returns false; anything ambiguous returns
/// true, so a working drive is never reported as broken.
bool driveResponds(String device) {
  return using((arena) {
    final senseBuf = arena<Uint8>(_senseLen);
    final cdbBuf   = arena<Uint8>(6); // TEST UNIT READY: six zero bytes
    for (var i = 0; i < 6; i++) {
      cdbBuf[i] = 0;
    }

    final hdr = arena<_SgIoHdr>();
    hdr.ref.interfaceId    = 0x53; // 'S'
    hdr.ref.dxferDirection = _sgDxferNone;
    hdr.ref.cmdLen         = 6;
    hdr.ref.mxSbLen        = _senseLen;
    hdr.ref.ivecCount      = 0;
    hdr.ref.dxferLen       = 0;
    hdr.ref.dxferp         = nullptr;
    hdr.ref.cmdp           = cdbBuf.cast();
    hdr.ref.sbp            = senseBuf.cast();
    hdr.ref.timeout        = 5000;
    hdr.ref.flags          = 0;
    hdr.ref.packId         = 0;
    hdr.ref.usrPtr         = nullptr;

    final fd = _dsOpen(
      device.toNativeUtf8(allocator: arena),
      _oRdonly | _oNonblock,
    );
    if (fd < 0) return false; // node gone or the driver refuses to open it
    try {
      final ret = _dsIoctl(fd, _sgIo, hdr.cast());
      if (ret != 0) return false;
      return hdr.ref.hostStatus == 0;
    } finally {
      _dsClose(fd);
    }
  });
}
