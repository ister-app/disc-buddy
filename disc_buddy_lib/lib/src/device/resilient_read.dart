import 'dart:typed_data';

/// Block-level read salvage for damaged DVDs.
///
/// libdvdread returns a short count or an error for a chunk that touches a
/// bad sector, and the old loop silently stopped there — the rip looked
/// finished but was truncated. This layer retries a failed chunk, bisects
/// it down to single blocks to isolate the damage, and replaces blocks that
/// stay unreadable with zero bytes. Every DVD sector is a self-contained
/// 2048-byte MPEG-PS pack starting with `00 00 01 BA`, so a zeroed sector
/// never splits a packet across the gap: the demuxer simply resynchronises
/// on the next start code (ddrescue/dvdbackup produce the same result).
///
/// The functions here are pure over an injected [BlockReader] so they can be
/// unit-tested without FFI.

const int kDvdBlockLen = 2048;

/// Reads [count] blocks at [offset]. Returns the bytes actually read (a
/// multiple of [kDvdBlockLen], possibly shorter than requested = partial
/// success), or null on a read error. Mirrors `DVDReadBlocks`.
typedef BlockReader = Uint8List? Function(int offset, int count);

/// Inclusive block range.
typedef BlockRange = ({int first, int last});

/// Tally of one streamed read.
class ReadStats {
  int blocksRequested = 0;
  int blocksRead = 0;
  int badBlocks = 0;
  int retries = 0;

  /// Unreadable runs, coalesced. Capped so a hopeless disc doesn't grow it
  /// without bound; [badBlocks] stays exact.
  final List<BlockRange> badRanges = [];
  static const int maxRanges = 256;

  bool get hasErrors => badBlocks > 0;

  void addBad(int first, int last) {
    badBlocks += last - first + 1;
    if (badRanges.isNotEmpty && badRanges.last.last == first - 1) {
      badRanges[badRanges.length - 1] = (first: badRanges.last.first, last: last);
    } else if (badRanges.length < maxRanges) {
      badRanges.add((first: first, last: last));
    }
  }

  String summary() {
    if (badBlocks == 0) return 'all $blocksRead sectors read cleanly';
    final kib = badBlocks * kDvdBlockLen ~/ 1024;
    return '$badBlocks unreadable sector${badBlocks == 1 ? '' : 's'} '
        '($kib KiB) zero-filled in ${badRanges.length} range'
        '${badRanges.length == 1 ? '' : 's'}'
        '${retries > 0 ? ', $retries retries' : ''}';
  }
}

/// Thrown by [salvageBlocks]/[resilientBlockStream] once more than
/// `maxBadBlocks` sectors had to be zero-filled.
class DvdReadException implements Exception {
  DvdReadException({required this.badBlocks, required this.cap, required this.offset});
  final int badBlocks;
  final int cap;
  final int offset;

  @override
  String toString() =>
      'DvdReadException: $badBlocks unreadable sectors exceed the cap of $cap '
      '(at sector $offset)';
}

/// Calls [read] up to `1 + retries` times. Returns the first non-null,
/// non-empty result or null.
Uint8List? readBlocksWithRetry(
  BlockReader read,
  int offset,
  int count,
  int retries,
  ReadStats stats,
) {
  for (var attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) stats.retries++;
    final data = read(offset, count);
    if (data != null && data.isNotEmpty) return data;
  }
  return null;
}

/// Reads exactly [count] blocks starting at [offset], always returning
/// `count * kDvdBlockLen` bytes.
///
/// A chunk that fails after [chunkRetries] extra attempts is split into
/// pieces of the next size in [bisectSizes] (which must end in 1). A single
/// block that still fails after [blockRetries] attempts becomes zeros and is
/// recorded in [stats]; [onBadRange] receives each coalesced unreadable run.
/// Throws [DvdReadException] once `stats.badBlocks > maxBadBlocks`.
Uint8List salvageBlocks(
  BlockReader read,
  int offset,
  int count, {
  List<int> bisectSizes = const [512, 64, 1],
  int chunkRetries = 1,
  int blockRetries = 2,
  int? maxBadBlocks,
  required ReadStats stats,
  void Function(int first, int last)? onBadRange,
}) {
  final out = Uint8List(count * kDvdBlockLen);
  var pos = 0;
  var cur = offset;
  final end = offset + count;

  // Pending unreadable run, flushed when a good block follows or at the end.
  int? badStart;
  int? badEnd;
  void flushBad() {
    if (badStart == null) return;
    stats.addBad(badStart!, badEnd!);
    onBadRange?.call(badStart!, badEnd!);
    badStart = null;
    badEnd = null;
  }

  void markBad(int block) {
    if (badStart != null && badEnd == block - 1) {
      badEnd = block;
    } else {
      flushBad();
      badStart = block;
      badEnd = block;
    }
    if (maxBadBlocks != null && stats.badBlocks + (badEnd! - badStart! + 1) > maxBadBlocks) {
      flushBad();
      throw DvdReadException(badBlocks: stats.badBlocks, cap: maxBadBlocks, offset: block);
    }
  }

  // Reads [n] blocks at [cur] with the given piece size, recursing to the
  // next smaller size on failure.
  void readPiece(int n, int sizeIdx) {
    while (n > 0) {
      final size = sizeIdx < bisectSizes.length ? bisectSizes[sizeIdx] : 1;
      final want = n < size ? n : size;
      final retries = want == 1 ? blockRetries : chunkRetries;
      stats.blocksRequested += want;
      final data = readBlocksWithRetry(read, cur, want, retries, stats);
      if (data != null) {
        final got = data.length ~/ kDvdBlockLen;
        final use = got < want ? got : want;
        if (use > 0) {
          flushBad();
          out.setRange(pos, pos + use * kDvdBlockLen, data);
          pos += use * kDvdBlockLen;
          cur += use;
          n -= use;
          stats.blocksRead += use;
          stats.blocksRequested -= want - use; // the rest is re-requested below
        }
        if (use == want) continue;
        // Short read: the remainder of this piece is suspect — go finer.
        if (want == 1) {
          // A 1-block "short read" can only be an empty buffer: treat as bad.
          markBad(cur);
          pos += kDvdBlockLen; // zeros already there
          cur += 1;
          n -= 1;
        }
        continue;
      }
      if (want == 1) {
        markBad(cur);
        pos += kDvdBlockLen;
        cur += 1;
        n -= 1;
      } else {
        stats.blocksRequested -= want;
        readPiece(want, sizeIdx + 1);
        n -= want;
      }
    }
  }

  readPiece(count, 0);
  flushBad();
  assert(cur == end && pos == out.length);
  return out;
}

/// Streams every block in [ranges] in chunks of [chunkBlocks]. A chunk that
/// fails after [chunkRetries] goes through [salvageBlocks]; a successful
/// short read simply advances by the blocks received. Always yields exactly
/// the bytes of all ranges, zero-filled where the disc was unreadable.
Stream<Uint8List> resilientBlockStream({
  required List<BlockRange> ranges,
  required BlockReader read,
  int chunkBlocks = 8192,
  int chunkRetries = 1,
  List<int> bisectSizes = const [512, 64, 1],
  int blockRetries = 2,
  int? maxBadBlocks,
  ReadStats? stats,
  void Function(int first, int last)? onBadRange,
}) async* {
  stats ??= ReadStats();
  for (final range in ranges) {
    var offset = range.first;
    while (offset <= range.last) {
      final remaining = range.last - offset + 1;
      final toRead = remaining < chunkBlocks ? remaining : chunkBlocks;
      stats.blocksRequested += toRead;
      final data = readBlocksWithRetry(read, offset, toRead, chunkRetries, stats);
      if (data != null) {
        final got = data.length ~/ kDvdBlockLen;
        final use = got < toRead ? got : toRead;
        stats.blocksRead += use;
        stats.blocksRequested -= toRead - use;
        yield use == got ? data : Uint8List.sublistView(data, 0, use * kDvdBlockLen);
        offset += use;
        continue;
      }
      // Hard failure: isolate the damage and keep going.
      stats.blocksRequested -= toRead;
      yield salvageBlocks(
        read,
        offset,
        toRead,
        bisectSizes: bisectSizes,
        chunkRetries: chunkRetries,
        blockRetries: blockRetries,
        maxBadBlocks: maxBadBlocks,
        stats: stats,
        onBadRange: onBadRange,
      );
      offset += toRead;
    }
  }
}
