import 'dart:ffi';
import 'dart:isolate';
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
//
// NOT @Packed: the kernel struct uses natural alignment. With @Packed(1) the
// 4 bytes of padding the C compiler inserts before `usrPtr` (to 8-byte-align
// the pointer after the 4-byte `packId`) would be dropped, shifting `status`
// and every trailing field 4 bytes earlier than the kernel writes them — so
// the status/sense fields would be read from the wrong offsets.
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

const _oRdonly        = 0;
const _oNonblock      = 2048;
const _sgIo           = 0x2285;
const _sgDxferFromDev = -3;

/// Bytes per CDDA sector (raw 16-bit stereo PCM at 44.1 kHz).
const kCddaSectorSize = 2352;

/// CDDA sectors (frames) per second of audio.
const kCddaSectorsPerSecond = 75;

/// Sectors per READ CD command: ~63 KB, safely under common 64 KB
/// SCSI transfer limits.
const kCddaBatchSectors = 27;

// ---------------------------------------------------------------------------
// Pure layer (unit-testable)
// ---------------------------------------------------------------------------

/// Builds a READ CD (0xBE, MMC) CDB for [sectorCount] CDDA sectors at
/// SCSI [lba] (i.e. absolute LBA minus the fixed 150-sector pre-gap).
Uint8List buildReadCdCdb(int lba, int sectorCount) {
  return Uint8List.fromList([
    0xBE,
    0x04,                    // expected sector type = CD-DA
    (lba >> 24) & 0xFF,
    (lba >> 16) & 0xFF,
    (lba >> 8) & 0xFF,
    lba & 0xFF,
    (sectorCount >> 16) & 0xFF,
    (sectorCount >> 8) & 0xFF,
    sectorCount & 0xFF,
    0x10,                    // user data only → 2352 bytes/sector
    0x00,                    // no subchannel
    0x00,
  ]);
}

/// Sector range of track [trackIndex] (0-based) as SCSI LBA + count.
///
/// [offsets] and [leadOut] are absolute LBAs from `readToc` (session 1 only,
/// so on CD Extra the last audio track ends exactly at the session-1
/// lead-out). The returned [startLba] has the 150-sector pre-gap subtracted,
/// ready for [buildReadCdCdb].
({int startLba, int sectorCount}) trackSectorRange({
  required List<int> offsets,
  required int leadOut,
  required int trackIndex,
}) {
  final start = offsets[trackIndex];
  final end   = trackIndex + 1 < offsets.length ? offsets[trackIndex + 1] : leadOut;
  return (startLba: start - 150, sectorCount: end - start);
}

/// A CDDA sector that could not be read after all retries.
class CddaReadException implements Exception {
  final int lba;
  CddaReadException(this.lba);

  @override
  String toString() => 'CddaReadException: unreadable sector at LBA $lba';
}

/// Streams [sectorCount] CDDA sectors starting at [startLba] via [read].
///
/// Reads in batches of [batchSectors]. A failed batch is retried
/// [batchRetries] times, then degraded to single-sector reads (each retried
/// [sectorRetries] times); a sector that still fails throws
/// [CddaReadException] — a track is never silently truncated.
///
/// [onBytes] receives the cumulative byte count after every yielded chunk.
/// Backpressure comes from `Stream.pipe`: the generator suspends at `yield`
/// until the consumer accepts the chunk.
Stream<Uint8List> cddaSectorStream({
  required int startLba,
  required int sectorCount,
  required Future<Uint8List?> Function(int lba, int count) read,
  int batchSectors = kCddaBatchSectors,
  int batchRetries = 2,
  int sectorRetries = 3,
  void Function(int totalBytes)? onBytes,
}) async* {
  var totalBytes = 0;
  var lba = startLba;
  final endLba = startLba + sectorCount;

  Future<Uint8List?> readWithRetries(int lba, int count, int retries) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      final data = await read(lba, count);
      if (data != null && data.length == count * kCddaSectorSize) return data;
    }
    return null;
  }

  while (lba < endLba) {
    final count = (endLba - lba).clamp(1, batchSectors);
    var chunk = await readWithRetries(lba, count, batchRetries);
    if (chunk == null) {
      // Degrade to single-sector reads to salvage what the drive can still
      // deliver and pinpoint the failing sector.
      final builder = BytesBuilder(copy: false);
      for (var s = lba; s < lba + count; s++) {
        final sector = await readWithRetries(s, 1, sectorRetries);
        if (sector == null) throw CddaReadException(s);
        builder.add(sector);
      }
      chunk = builder.takeBytes();
    }
    totalBytes += chunk.length;
    yield chunk;
    onBytes?.call(totalBytes);
    lba += count;
  }
}

// ---------------------------------------------------------------------------
// FFI layer
// ---------------------------------------------------------------------------

/// Reads raw CDDA sectors from an optical drive via SG_IO READ CD (0xBE).
///
/// Holds a persistent fd and a reusable transfer buffer; call [close] when
/// done. Not thread-safe — issue one read at a time.
class CddaReader {
  final int _fd;
  final Pointer<Uint8> _dataBuf;

  CddaReader._(this._fd, this._dataBuf);

  /// Opens [device]; returns null if the device cannot be opened.
  static CddaReader? open(String device) {
    final pathPtr = device.toNativeUtf8();
    final fd = _open(pathPtr, _oRdonly | _oNonblock);
    calloc.free(pathPtr);
    if (fd < 0) return null;
    final buf = calloc<Uint8>(kCddaBatchSectors * kCddaSectorSize);
    return CddaReader._(fd, buf);
  }

  /// Reads [count] sectors (max [kCddaBatchSectors]) at SCSI [lba].
  /// Returns null on any SCSI/transport error.
  Uint8List? readSectors(int lba, int count) {
    assert(count >= 1 && count <= kCddaBatchSectors);
    final byteLen = count * kCddaSectorSize;

    return using((arena) {
      final senseBuf = arena<Uint8>(32);
      final cdbBuf   = arena<Uint8>(12);
      final cdb      = buildReadCdCdb(lba, count);
      for (var i = 0; i < cdb.length; i++) {
        cdbBuf[i] = cdb[i];
      }

      final hdr = arena<_SgIoHdr>();
      hdr.ref.interfaceId    = 0x53; // 'S'
      hdr.ref.dxferDirection = _sgDxferFromDev;
      hdr.ref.cmdLen         = 12;
      hdr.ref.mxSbLen        = 32;
      hdr.ref.ivecCount      = 0;
      hdr.ref.dxferLen       = byteLen;
      hdr.ref.dxferp         = _dataBuf.cast();
      hdr.ref.cmdp           = cdbBuf.cast();
      hdr.ref.sbp            = senseBuf.cast();
      hdr.ref.timeout        = 10000; // scratched-disc reads can be slow
      hdr.ref.flags          = 0;
      hdr.ref.packId         = 0;
      hdr.ref.usrPtr         = nullptr;

      final ret = _ioctl(_fd, _sgIo, hdr.cast());
      // Fail on any error: ioctl error, non-zero SCSI status, a transport-level
      // host/driver failure (which can leave `status == 0` but the buffer
      // stale), or returned sense data.
      if (ret != 0 ||
          hdr.ref.status != 0 ||
          hdr.ref.hostStatus != 0 ||
          hdr.ref.driverStatus != 0 ||
          hdr.ref.sbLenWr != 0) {
        return null;
      }

      // Copy out: the native buffer is reused by the next read.
      return Uint8List.fromList(_dataBuf.asTypedList(byteLen));
    });
  }

  void close() {
    _close(_fd);
    calloc.free(_dataBuf);
  }
}

// ---------------------------------------------------------------------------
// Isolate wrapper
// ---------------------------------------------------------------------------

/// Runs a [CddaReader] in its own isolate.
///
/// SG_IO is a blocking ioctl; issued from the main isolate it would freeze a
/// Flutter UI for the entire rip. This wrapper serves reads over ports so the
/// caller's isolate stays responsive. Requests are answered one at a time —
/// issue one read at a time, as with [CddaReader].
class IsolateCddaReader {
  final Isolate _isolate;
  final SendPort _commands;

  IsolateCddaReader._(this._isolate, this._commands);

  /// Spawns the reader isolate and opens [device] there.
  /// Returns null if the device cannot be opened.
  static Future<IsolateCddaReader?> open(String device) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_isolateMain, (device, ready.sendPort));
    final commands = await ready.first as SendPort?;
    ready.close();
    if (commands == null) {
      isolate.kill(priority: Isolate.immediate);
      return null;
    }
    return IsolateCddaReader._(isolate, commands);
  }

  /// Reads [count] sectors (max [kCddaBatchSectors]) at SCSI [lba].
  /// Returns null on any SCSI/transport error.
  Future<Uint8List?> readSectors(int lba, int count) async {
    final reply = ReceivePort();
    _commands.send((lba, count, reply.sendPort));
    final result = await reply.first as Uint8List?;
    reply.close();
    return result;
  }

  void close() {
    _commands.send(null);
    // Safety net in case the isolate is stuck inside the blocking ioctl.
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static void _isolateMain((String, SendPort) args) {
    final (device, ready) = args;
    final reader = CddaReader.open(device);
    if (reader == null) {
      ready.send(null);
      return;
    }
    final commands = ReceivePort();
    ready.send(commands.sendPort);
    commands.listen((msg) {
      if (msg == null) {
        reader.close();
        commands.close();
        return;
      }
      final (lba, count, reply) = msg as (int, int, SendPort);
      reply.send(reader.readSectors(lba, count));
    });
  }
}
