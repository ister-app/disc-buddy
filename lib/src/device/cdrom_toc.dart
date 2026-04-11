import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// libc bindings
// ---------------------------------------------------------------------------

final _libc = DynamicLibrary.open('libc.so.6');

typedef _OpenC    = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenDart = int   Function(Pointer<Utf8>, int);
final _open = _libc.lookupFunction<_OpenC, _OpenDart>('open');

typedef _IoctlC    = Int32 Function(Int32, Uint64, Pointer<Void>);
typedef _IoctlDart = int   Function(int,   int,    Pointer<Void>);
final _ioctl = _libc.lookupFunction<_IoctlC, _IoctlDart>('ioctl');

typedef _CloseC    = Int32 Function(Int32);
typedef _CloseDart = int   Function(int);
final _close = _libc.lookupFunction<_CloseC, _CloseDart>('close');

// ---------------------------------------------------------------------------
// sg_io_hdr_t — identical to Linux <scsi/sg.h>
// ---------------------------------------------------------------------------

@Packed(1)
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

const _oRdonly         = 0;
const _oNonblock       = 2048;
const _sgIo            = 0x2285;
const _sgDxferFromDev  = -3;

// READ TOC/PMA/ATIP (0x43), format 2 = Full TOC
// TIME=1 (MSF), session=1, alloc=512
const _kReadTocCdb = [0x43, 0x02, 0x02, 0, 0, 0, 0x01, 0x02, 0x00, 0x00];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Full TOC of session 1: track offsets (as absolute LBA) + lead-out LBA.
///
/// [offsets] has one element per track (index 0 = track 1).
/// All LBAs are absolute (including the fixed 150-sector pre-gap).
///
/// Returns null if the ioctl fails or the device does not support it.
Future<({int firstTrack, int lastTrack, List<int> offsets, int leadOut})?> readToc(
  String device,
) async {
  const bufSize = 512;

  return using((arena) {
    final dataBuf  = arena<Uint8>(bufSize);
    final senseBuf = arena<Uint8>(32);
    final cdbBuf   = arena<Uint8>(10);

    for (var i = 0; i < _kReadTocCdb.length; i++) {
      cdbBuf[i] = _kReadTocCdb[i];
    }

    final hdr = arena<_SgIoHdr>();
    hdr.ref.interfaceId    = 0x53; // 'S'
    hdr.ref.dxferDirection = _sgDxferFromDev;
    hdr.ref.cmdLen         = 10;
    hdr.ref.mxSbLen        = 32;
    hdr.ref.ivecCount      = 0;
    hdr.ref.dxferLen       = bufSize;
    hdr.ref.dxferp         = dataBuf.cast();
    hdr.ref.cmdp           = cdbBuf.cast();
    hdr.ref.sbp            = senseBuf.cast();
    hdr.ref.timeout        = 5000;
    hdr.ref.flags          = 0;
    hdr.ref.packId         = 0;
    hdr.ref.usrPtr         = nullptr;

    final pathPtr = device.toNativeUtf8(allocator: arena);
    final fd = _open(pathPtr, _oRdonly | _oNonblock);
    if (fd < 0) return null;

    try {
      final ret = _ioctl(fd, _sgIo, hdr.cast());
      if (ret != 0 || hdr.ref.status != 0) return null;

      final bytes = Uint8List(bufSize);
      for (var i = 0; i < bufSize; i++) { bytes[i] = dataBuf[i]; }

      final bd     = ByteData.sublistView(bytes);
      final tocLen = bd.getUint16(0, Endian.big);

      // Full TOC descriptor layout (MMC-5, 11 bytes each):
      //   +0  session
      //   +1  ADR|Control
      //   +2  TNO
      //   +3  POINT  (track# 1-99, or 0xA0/A1/A2)
      //   +4  Min (absolute MSF)
      //   +5  Sec
      //   +6  Frame
      //   +7  Zero
      //   +8  PMIN   ← P-address (start of this POINT)
      //   +9  PSEC
      //   +10 PFRAME
      //
      // For 0xA0: PMIN = first track# (not MSF)
      // For 0xA1: PMIN = last track#  (not MSF)
      // For 0xA2: PMIN/PSEC/PFRAME = MSF lead-out
      // For 1-99: PMIN/PSEC/PFRAME = MSF start of the track

      int firstTrack = 1;
      int lastTrack  = 1;
      int leadOut    = 0;
      final trackLba = <int, int>{};

      var offset = 4;
      while (offset + 11 <= tocLen + 2) {
        final sess  = bytes[offset];
        final point = bytes[offset + 3];
        final pmin  = bytes[offset + 8];
        final psec  = bytes[offset + 9];
        final pfrm  = bytes[offset + 10];

        if (sess == 1) {
          if (point == 0xA0) {
            firstTrack = pmin;
          } else if (point == 0xA1) {
            lastTrack = pmin;
          } else if (point == 0xA2) {
            leadOut = (pmin * 60 + psec) * 75 + pfrm;
          } else if (point >= 1 && point <= 99) {
            trackLba[point] = (pmin * 60 + psec) * 75 + pfrm;
          }
        }
        offset += 11;
      }

      if (leadOut == 0 || trackLba.isEmpty) return null;

      final sorted = List.generate(
        lastTrack - firstTrack + 1,
        (i) => trackLba[firstTrack + i] ?? 0,
      );
      if (sorted.any((o) => o == 0)) return null;

      return (
        firstTrack: firstTrack,
        lastTrack: lastTrack,
        offsets: sorted,
        leadOut: leadOut,
      );
    } finally {
      _close(fd);
    }
  });
}
