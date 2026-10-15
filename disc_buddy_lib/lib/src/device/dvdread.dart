import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'resilient_read.dart';
export 'resilient_read.dart' show ReadStats, DvdReadException, BlockRange;

// ---------------------------------------------------------------------------
// Load libdvdread
// ---------------------------------------------------------------------------

DynamicLibrary? _tryLoad() {
  for (final name in ['libdvdread.so.8', 'libdvdread.so.4', 'libdvdread.so']) {
    try { return DynamicLibrary.open(name); } catch (_) {}
  }
  return null;
}

final _lib = _tryLoad();

// ---------------------------------------------------------------------------
// libc: dup / dup2 / open / close — to suppress stderr during DVDOpen
// ---------------------------------------------------------------------------

final _libc = DynamicLibrary.open('libc.so.6');

typedef _DupC  = Int32 Function(Int32);
typedef _DupD  = int   Function(int);
final _dup  = _libc.lookupFunction<_DupC, _DupD>('dup');

typedef _Dup2C = Int32 Function(Int32, Int32);
typedef _Dup2D = int   Function(int,   int);
final _dup2 = _libc.lookupFunction<_Dup2C, _Dup2D>('dup2');

typedef _OpenC2 = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenD2 = int   Function(Pointer<Utf8>, int);
final _open = _libc.lookupFunction<_OpenC2, _OpenD2>('open');

typedef _CloseC2 = Int32 Function(Int32);
typedef _CloseD2 = int   Function(int);
final _close = _libc.lookupFunction<_CloseC2, _CloseD2>('close');

const _kOWronly = 1; // O_WRONLY

/// Redirects fd 2 to /dev/null for the synchronous [fn] call, then restores it.
/// A no-op when [_dvdOpen2] is available — the null logger already silences everything.
T _suppressStderr<T>(T Function() fn) {
  if (_dvdOpen2 != null) return fn();

  final savedStderr = _dup(2);
  final devNull     = '/dev/null'.toNativeUtf8();
  final nullFd      = _open(devNull, _kOWronly);
  calloc.free(devNull);
  if (nullFd >= 0) _dup2(nullFd, 2);
  try {
    return fn();
  } finally {
    if (savedStderr >= 0) { _dup2(savedStderr, 2); _close(savedStderr); }
    if (nullFd >= 0) _close(nullFd);
  }
}

/// Opens the DVD without logging output.
///
/// Prefers DVDOpen2 (libdvdread 6.x) with a nullptr callback — that suppresses
/// logging cleanly at the source.
/// Falls back to DVDOpen with fd redirect (dup2) for older versions.
Pointer<Void> _dvdOpenQuiet(Pointer<Utf8> devPtr) {
  if (_dvdOpen2 != null) return _dvdOpen2!(nullptr, nullptr, devPtr);
  return _suppressStderr(() => _dvdOpen(devPtr));
}

/// True if libdvdread is available (and thus CSS-encrypted discs can be read).
bool get dvdreadAvailable => _lib != null;

// ---------------------------------------------------------------------------
// Function lookups (only safe after checking dvdreadAvailable)
// ---------------------------------------------------------------------------

typedef _OpenC  = Pointer<Void> Function(Pointer<Utf8>);
typedef _OpenD  = Pointer<Void> Function(Pointer<Utf8>);
final _dvdOpen =
    _lib!.lookupFunction<_OpenC, _OpenD>('DVDOpen');

// DVDOpen2 (libdvdread 6.x): accepts (stream, logger_cb, path).
// Passing nullptr for both stream and logger_cb disables all logging.
typedef _Open2C = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>);
typedef _Open2D = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>);
final _dvdOpen2 = () {
  try {
    return _lib!.lookupFunction<_Open2C, _Open2D>('DVDOpen2');
  } catch (_) {
    return null;
  }
}();

typedef _OpenFileC  = Pointer<Void> Function(Pointer<Void>, Int32, Int32);
typedef _OpenFileD  = Pointer<Void> Function(Pointer<Void>, int, int);
final _dvdOpenFile =
    _lib!.lookupFunction<_OpenFileC, _OpenFileD>('DVDOpenFile');

typedef _ReadBlocksC  = IntPtr Function(Pointer<Void>, Int32, IntPtr, Pointer<Uint8>);
typedef _ReadBlocksD  = int    Function(Pointer<Void>, int,   int,    Pointer<Uint8>);
final _dvdReadBlocks =
    _lib!.lookupFunction<_ReadBlocksC, _ReadBlocksD>('DVDReadBlocks');

typedef _FileSizeC  = Int32 Function(Pointer<Void>);
typedef _FileSizeD  = int   Function(Pointer<Void>);
final _dvdFileSize =
    _lib!.lookupFunction<_FileSizeC, _FileSizeD>('DVDFileSize');

typedef _CloseFileC = Void Function(Pointer<Void>);
typedef _CloseFileD = void Function(Pointer<Void>);
final _dvdCloseFile =
    _lib!.lookupFunction<_CloseFileC, _CloseFileD>('DVDCloseFile');

typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseD = void Function(Pointer<Void>);
final _dvdClose =
    _lib!.lookupFunction<_CloseC, _CloseD>('DVDClose');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _kReadTitleVobs = 3; // DVD_READ_TITLE_VOBS
const _kBlockLen      = 2048;
const _kChunkBlocks   = 8192; // 16 MB per chunk (16 MiB / 2048-byte block)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Streams VOB blocks for [vtsNum] via libdvdread (+ libdvdcss if present).
///
/// If [cells] is provided, only the sectors of those cells are read
/// (correct multi-angle support). Otherwise reads linearly.
///
/// Throws an [Exception] if the disc cannot be opened.
/// Returns [null] if libdvdread is not installed.
Stream<List<int>>? streamVobs(
  String device,
  int vtsNum, {
  List<({int first, int last})>? cells,
}) {
  if (!dvdreadAvailable) return null;
  return _stream(device, vtsNum, cells: cells);
}

Stream<List<int>> _stream(
  String device,
  int vtsNum, {
  List<({int first, int last})>? cells,
}) async* {
  final devPtr = device.toNativeUtf8();
  final dvd    = _dvdOpenQuiet(devPtr);
  calloc.free(devPtr);

  if (dvd == nullptr) {
    throw Exception(
      'Cannot open disc. '
      'Install libdvdcss for encrypted discs: sudo dnf install libdvdcss',
    );
  }

  try {
    yield* _streamFromHandle(dvd, vtsNum, cells: cells);
  } finally {
    _dvdClose(dvd);
  }
}

/// Streams the VOB blocks of [vtsNum]: the given [cells] (multi-angle
/// support) or the whole title set linearly.
///
/// Read errors no longer end the stream: a failing chunk is retried,
/// bisected and, where the disc stays unreadable, zero-filled (see
/// `resilientBlockStream`). [stats] collects the tally, [onBadRange] is
/// called per unreadable run, and more than [maxBadBlocks] zero-filled
/// sectors throw a [DvdReadException] from the stream.
Stream<List<int>> _streamFromHandle(
  Pointer<Void> dvd,
  int vtsNum, {
  List<BlockRange>? cells,
  ReadStats? stats,
  int? maxBadBlocks,
  void Function(int first, int last)? onBadRange,
}) async* {
  final file = _suppressStderr(() => _dvdOpenFile(dvd, vtsNum, _kReadTitleVobs));
  if (file == nullptr) {
    throw Exception('Cannot open VTS $vtsNum');
  }

  try {
    final buf = calloc<Uint8>(_kChunkBlocks * _kBlockLen);
    try {
      // Copy the native buffer in one memcpy (asTypedList is a view over
      // [buf], which is reused next call, so fromList must copy it).
      Uint8List? read(int offset, int count) {
        final n = _dvdReadBlocks(file, offset, count, buf);
        if (n <= 0) return null;
        return Uint8List.fromList(buf.asTypedList(n * _kBlockLen));
      }

      final ranges = (cells != null && cells.isNotEmpty)
          ? cells
          : <BlockRange>[(first: 0, last: _dvdFileSize(file) - 1)];
      yield* resilientBlockStream(
        ranges: ranges,
        read: read,
        chunkBlocks: _kChunkBlocks,
        stats: stats,
        maxBadBlocks: maxBadBlocks,
        onBadRange: onBadRange,
      );
    } finally {
      calloc.free(buf);
    }
  } finally {
    _dvdCloseFile(file);
  }
}

/// Keeps a DVD handle open across multiple stream calls so the disc is opened
/// only once and libdvdcss does not repeat its CSS key-retrieval log per call.
class DVDSession {
  final Pointer<Void> _dvd;
  DVDSession._(this._dvd);

  /// Opens [device] and retrieves CSS keys once.
  /// Returns null if libdvdread is unavailable or the disc cannot be opened.
  static DVDSession? open(String device) {
    if (!dvdreadAvailable) return null;
    final devPtr = device.toNativeUtf8();
    final dvd    = _dvdOpenQuiet(devPtr);
    calloc.free(devPtr);
    if (dvd == nullptr) return null;
    return DVDSession._(dvd);
  }

  /// Streams VOB blocks for [vtsNum], reusing the already-open disc handle.
  /// Equivalent to [streamVobs] but does not re-open the disc. See
  /// `_streamFromHandle` for the read-error parameters.
  Stream<List<int>> stream(
    int vtsNum, {
    List<BlockRange>? cells,
    ReadStats? stats,
    int? maxBadBlocks,
    void Function(int first, int last)? onBadRange,
  }) =>
      _streamFromHandle(_dvd, vtsNum,
          cells: cells, stats: stats, maxBadBlocks: maxBadBlocks, onBadRange: onBadRange);

  void close() => _dvdClose(_dvd);
}
