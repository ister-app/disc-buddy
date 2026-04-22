import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

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

/// Opens the DVD without logging output.
///
/// Prefers DVDOpen2 (libdvdread 6.x) with a nullptr callback — that suppresses
/// logging cleanly at the source.
/// Falls back to DVDOpen with fd redirect (dup2) for older versions.
Pointer<Void> _dvdOpenQuiet(Pointer<Utf8> devPtr) {
  // Prefer: DVDOpen2 with null logger → no output
  if (_dvdOpen2 != null) {
    return _dvdOpen2!(nullptr, nullptr, devPtr);
  }

  // Fallback: redirect fd 2 to /dev/null for the duration of DVDOpen
  final savedStderr = _dup(2);
  final devNull     = '/dev/null'.toNativeUtf8();
  final nullFd      = _open(devNull, _kOWronly);
  calloc.free(devNull);
  if (nullFd >= 0) _dup2(nullFd, 2);

  final dvd = _dvdOpen(devPtr);

  if (savedStderr >= 0) { _dup2(savedStderr, 2); _close(savedStderr); }
  if (nullFd >= 0) _close(nullFd);

  return dvd;
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
const _kChunkBlocks   = 512; // 1 MB per chunk

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

Stream<List<int>> _streamFromHandle(
  Pointer<Void> dvd,
  int vtsNum, {
  List<({int first, int last})>? cells,
}) async* {
  final file = _dvdOpenFile(dvd, vtsNum, _kReadTitleVobs);
  if (file == nullptr) {
    throw Exception('Cannot open VTS $vtsNum');
  }

  try {
    final buf = calloc<Uint8>(_kChunkBlocks * _kBlockLen);
    try {
      if (cells != null && cells.isNotEmpty) {
        // Cell navigation: read only sectors belonging to this PGC/angle
        for (final cell in cells) {
          var offset = cell.first;
          while (offset <= cell.last) {
            final toRead = (_kChunkBlocks < cell.last - offset + 1)
                ? _kChunkBlocks
                : cell.last - offset + 1;
            final n = _dvdReadBlocks(file, offset, toRead, buf);
            if (n <= 0) break;
            final bytes = Uint8List(n * _kBlockLen);
            for (var i = 0; i < bytes.length; i++) { bytes[i] = buf[i]; }
            yield bytes;
            offset += n;
          }
        }
      } else {
        // Linear read (all blocks)
        final numBlocks = _dvdFileSize(file);
        var offset = 0;
        while (offset < numBlocks) {
          final toRead = (_kChunkBlocks < numBlocks - offset)
              ? _kChunkBlocks
              : numBlocks - offset;
          final n = _dvdReadBlocks(file, offset, toRead, buf);
          if (n <= 0) break;
          final bytes = Uint8List(n * _kBlockLen);
          for (var i = 0; i < bytes.length; i++) { bytes[i] = buf[i]; }
          yield bytes;
          offset += n;
        }
      }
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
  /// Equivalent to [streamVobs] but does not re-open the disc.
  Stream<List<int>> stream(int vtsNum, {List<({int first, int last})>? cells}) =>
      _streamFromHandle(_dvd, vtsNum, cells: cells);

  void close() => _dvdClose(_dvd);
}
