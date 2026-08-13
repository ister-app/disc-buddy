import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../rippers/video_disc_ripper.dart' show LogCallback;
import 'cc_format.dart';

/// Extracts EIA-608 Closed Caption subtitles embedded in an MPEG-2 video
/// stream and writes them as SRT.
///
/// Call [extractFromMkv] after ripping a DVD title; it pipes the video track
/// through ffmpeg (as raw MPEG-2) and scans for CC user_data packets.
class CcExtractor {
  final String ffmpeg;
  final LogCallback? onLog;

  CcExtractor({required this.ffmpeg, this.onLog});

  void _log(String msg, {bool isError = false}) {
    if (onLog != null) {
      onLog!(msg, isError: isError);
    } else if (isError) {
      stderr.writeln(msg);
    } else {
      stdout.writeln(msg);
    }
  }

  /// Extracts CC subtitles from [mkvFile] and writes a sidecar SRT file.
  ///
  /// Returns the [File] written, or null if no CC found / on error.
  Future<File?> extractFromMkv(File mkvFile, {String language = 'en'}) async {
    final stem   = mkvFile.path.replaceFirst(RegExp(r'\.mkv$'), '');
    final srtFile = File('$stem.$language.srt');
    if (await srtFile.exists()) {
      _log('   CC subtitle $language: already exists, skipping.');
      return srtFile;
    }

    _log('   Scanning video stream for EIA-608 closed captions…');

    final process = await Process.start(ffmpeg, [
      '-loglevel', 'error',
      '-i', mkvFile.path,
      '-map', '0:v:0',
      '-c:v', 'copy',
      '-f', 'mpeg2video',
      'pipe:1',
    ]);

    final scanner = Mpeg2CcScanner();
    final stderrFuture = process.stderr.drain<void>();
    await for (final chunk in process.stdout) {
      scanner.addChunk(chunk);
    }
    final results = await Future.wait([process.exitCode, stderrFuture]);
    final exitCode = results[0] as int;
    if (exitCode != 0) {
      _log('   CC scan: ffmpeg exited with code $exitCode — '
          'CC results may be incomplete.', isError: true);
    }

    final srt = scanner.buildSrt();
    if (srt.isEmpty) {
      _logNoCaptions(scanner);
      return null;
    }

    await srtFile.writeAsString(srt, encoding: utf8);
    _log('   CC subtitle written → ${srtFile.path}');
    return srtFile;
  }

  /// Extracts CC subtitles from a raw MPEG-PS stream (dvdread or VOB concat).
  ///
  /// Pipes [mpegPsStream] through ffmpeg to demux the video elementary stream,
  /// then scans for EIA-608 user_data. Using the source stream instead of the
  /// ripped MKV preserves user_data packets (including EDM) that ffmpeg may
  /// drop when remuxing MPEG-PS → MKV.
  ///
  /// Returns the [File] written, or null if no CC found / on error.
  Future<File?> extractFromMpegPsStream(
    Stream<List<int>> mpegPsStream,
    File srtFile,
  ) async {
    if (await srtFile.exists()) {
      _log('   CC subtitle: already exists, skipping.');
      return srtFile;
    }

    _log('   Scanning source stream for EIA-608 closed captions…');

    final process = await Process.start(ffmpeg, [
      '-loglevel', 'error',
      '-f', 'mpeg',
      '-i', 'pipe:0',
      '-map', '0:v:0',
      '-c:v', 'copy',
      '-f', 'mpeg2video',
      'pipe:1',
    ]);

    // Feed MPEG-PS to stdin concurrently with scanning stdout.
    // Ignore broken pipe in case ffmpeg exits before consuming all input.
    unawaited(mpegPsStream.pipe(process.stdin).catchError((_) {}));

    final scanner = Mpeg2CcScanner();
    final stderrFuture = process.stderr.drain<void>();
    await for (final chunk in process.stdout) {
      scanner.addChunk(chunk);
    }
    final results = await Future.wait([process.exitCode, stderrFuture]);
    final exitCode = results[0] as int;
    // A non-zero exit can be benign here (ffmpeg may close the input pipe early
    // once it has the video stream), so only surface it when nothing decoded.
    if (exitCode != 0 && scanner.userDataPackets == 0) {
      _log('   CC scan: ffmpeg exited with code $exitCode and no user_data '
          'was seen — the source stream may not have been demuxed.', isError: true);
    }

    final srt = scanner.buildSrt();
    if (srt.isEmpty) {
      _logNoCaptions(scanner);
      return null;
    }

    await srtFile.writeAsString(srt, encoding: utf8);
    _log('   CC subtitle written → ${srtFile.path}');
    return srtFile;
  }

  /// Explains an empty scan result: no user_data at all, user_data without CC
  /// structure, a CC track that carries only null padding, or CC pairs that
  /// decoded to no caption text.
  void _logNoCaptions(Mpeg2CcScanner scanner) {
    if (scanner.userDataPackets == 0) {
      _log('   No CC captions found (no MPEG-2 user_data packets in stream).');
    } else if (scanner.ccPacketsDetected == 0) {
      _log('   No CC captions found (${scanner.userDataPackets} user_data '
          'packet(s) scanned, none contained EIA-608 data).');
    } else if (scanner.nonNullCcPairs == 0) {
      _log('   CC channel empty: ${scanner.ccPacketsDetected} CC packet(s) '
          'found but all contained only null padding — the disc has a CC track '
          'with no captions; no SRT produced.');
    } else {
      _log('   No CC captions found (${scanner.nonNullCcPairs} CC byte pair(s) '
          'decoded but produced no caption text).');
    }
  }
}

// ---------------------------------------------------------------------------
// MPEG-2 bitstream scanner
// ---------------------------------------------------------------------------

/// Internal MPEG-2 elementary-stream scanner. Public only so tests can drive
/// it with synthetic byte streams; not part of the package API (kept out of
/// the `disc_buddy.dart` barrel).
class Mpeg2CcScanner {
  // Sliding buffer; kept small by trimming after each _process() call.
  final _buf = <int>[];

  // Continuous output position (in frame-ticks) at the START of the current GOP.
  // Accumulated from per-GOP timecode deltas so it tracks the ripped (contiguous)
  // output rather than the on-disc timecode, which is non-contiguous for cells of
  // an interleaved multi-angle title.
  int _outputTicks = 0;
  // Previous GOP's drop-frame-corrected timecode, to measure the delta.
  int? _lastGopTicks;

  // Displayed-field count of the GOP that just ended (fallback for a timecode
  // discontinuity, and set by _flushGop).
  int _lastGopFields = 0;

  // Pictures of the GOP being scanned, in coded order. [tr] is the picture's
  // temporal_reference (its position in DISPLAY order within the GOP); [fields]
  // is how long it stays on screen, which is 3 rather than 2 for every other
  // frame under 3:2 pulldown.
  final _gopPictures = <_GopPicture>[];

  // CC packets of the GOP being scanned. [picture] is the index in
  // [_gopPictures] of the picture the packet followed, or -1 when the packet
  // preceded the first picture (DVD encoders put one packet carrying the whole
  // GOP right after the GOP header). Null pairs are kept: each pair occupies one
  // displayed field, so dropping them here would shift every later pair.
  final _gopPackets = <_CcPacket>[];

  final Eia608Decoder decoder;

  Mpeg2CcScanner({Eia608Decoder? decoder})
      : decoder = decoder ?? Eia608Decoder();

  // Count of user_data packets encountered (useful for diagnosing missing CC).
  int userDataPackets = 0;

  // Count of user_data packets in which a CC payload structure was detected.
  int ccPacketsDetected = 0;

  // Count of non-null EIA-608 byte pairs handed to the decoder. Zero while
  // [ccPacketsDetected] > 0 means the disc has a CC track with no captions.
  int nonNullCcPairs = 0;

  void addChunk(List<int> chunk) {
    _buf.addAll(chunk);
    _process();
  }

  void _process() {
    int i = 0;
    final len = _buf.length;

    while (i + 4 <= len) {
      // Scan for 00 00 01 XX start codes.
      if (_buf[i] != 0x00) { i++; continue; }
      if (_buf[i + 1] != 0x00) { i += 2; continue; }
      if (_buf[i + 2] != 0x01) { i++; continue; }

      final type = _buf[i + 3];

      if (type == 0xB8) {
        // group_of_pictures_header — 4 bytes of timecode data follow.
        if (i + 8 > len) break;
        // The previous GOP is complete: its pictures are all known, so its CC
        // pairs can be placed on the display timeline and decoded.
        _flushGop();
        _parseGop(i + 4);
        i += 8;
      } else if (type == 0x00) {
        // picture_start_code — temporal_reference is the next 10 bits.
        if (i + 6 > len) break;
        // A stream without GOP headers would never flush; cut it into chunks so
        // the buffer stays bounded and the clock keeps running. Real DVD and
        // Blu-ray streams always carry GOP headers, so this never fires there.
        if (_gopPictures.length >= _maxPicturesPerGop) {
          _flushGop(advanceClock: true);
        }
        _gopPictures.add(_GopPicture((_buf[i + 4] << 2) | (_buf[i + 5] >> 6)));
        i += 4;
      } else if (type == 0xB5) {
        // extension_start_code — picture_coding_extension (id 8) carries
        // repeat_first_field, which is how 3:2 pulldown stretches 12 coded
        // frames into 15 displayed ones.
        if (i + 8 > len) break;
        if ((_buf[i + 4] >> 4) == 8 && _gopPictures.isNotEmpty) {
          final pictureStructure = _buf[i + 6] & 0x03;
          final repeatFirstField = (_buf[i + 7] >> 1) & 0x01;
          _gopPictures.last.fields =
              pictureStructure == 3 ? 2 + repeatFirstField : 1;
        }
        i += 4;
      } else if (type == 0xB7) {
        // sequence_end_code — nothing more belongs to this GOP.
        _flushGop();
        i += 4;
      } else if (type == 0xB2) {
        // user_data — look for CC payload.
        final dataStart = i + 4;
        final dataEnd   = _findNextStartCode(dataStart);
        if (dataEnd < 0) break; // need more data
        if (dataEnd - dataStart >= 4) {
          userDataPackets++;
          _parseUserData(dataStart, dataEnd);
        }
        i = dataEnd;
      } else {
        i += 4;
      }
    }

    // Trim buffer, keeping the last 3 bytes so start codes split across
    // chunk boundaries are not missed.
    if (i > 3) _buf.removeRange(0, i - 3);
  }

  // Returns the index of the next 00 00 01 XX start code at or after [from],
  // or -1 if the buffer does not yet contain the next start code.
  // Safety cap: if more than 2048 bytes pass without a start code, skip ahead.
  int _findNextStartCode(int from) {
    final len = _buf.length;
    final cap = from + 2048;
    final end = cap < len ? cap : len;
    for (int i = from; i + 3 < end; i++) {
      if (_buf[i] == 0x00 && _buf[i + 1] == 0x00 && _buf[i + 2] == 0x01) {
        return i;
      }
    }
    if (cap <= len) return cap; // gave up — skip forward
    return -1;
  }

  void _parseGop(int off) {
    // GOP timecode is packed into 32 bits (big-endian):
    //   [31]    drop_frame_flag
    //   [30-26] hours   (5 bits)
    //   [25-20] minutes (6 bits)
    //   [19]    marker_bit
    //   [18-13] seconds (6 bits)
    //   [12-7]  pictures/frames (6 bits)
    //   [6-5]   closed_gop, broken_link
    //   [4-0]   reserved
    final w = (_buf[off] << 24) | (_buf[off + 1] << 16) |
              (_buf[off + 2] << 8) | _buf[off + 3];
    final dropFrame = (w >> 31) & 0x1;
    final h = (w >> 26) & 0x1F;
    final m = (w >> 20) & 0x3F;
    final s = (w >> 13) & 0x3F;
    final f = (w >>  7) & 0x3F;
    // Convert HH:MM:SS:FF to an absolute frame count. NTSC DVDs use drop-frame
    // timecode: frame numbers 0 and 1 are skipped at the start of every minute
    // except every 10th minute, so the timecode tracks real (29.97 fps) time.
    // Treating it as a plain 30 fps count overcounts by ~2 frames/minute, which
    // (after the ×1001/30 ms conversion) drifts ~0.1 %/min — visibly late by the
    // end of an episode. Subtract the dropped frames to get the true count.
    var ticks = h * 108000 + m * 1800 + s * 30 + f;
    if (dropFrame == 1) {
      final totalMinutes = h * 60 + m;
      ticks -= 2 * (totalMinutes - totalMinutes ~/ 10);
    }
    // Advance the continuous output position by the timecode delta when GOPs are
    // contiguous (this stays wall-clock accurate, e.g. for 3:2 pulldown). A
    // negative or large jump means a cell/angle boundary: the on-disc timecode
    // is discontinuous but the ripped output is not, so advance by the frames
    // actually decoded in the GOP that just ended instead of the bogus jump.
    if (_lastGopTicks != null) {
      final delta = ticks - _lastGopTicks!;
      const maxNormalDelta = 150; // ~5s; real DVD GOPs are well under ~0.5s
      _outputTicks += (delta >= 0 && delta < maxNormalDelta)
          ? delta
          : _lastGopFields ~/ 2;
    }
    _lastGopTicks = ticks;
  }

  /// Places the CC pairs buffered for the GOP that just ended on the display
  /// timeline and feeds them to the decoder in display order.
  ///
  /// The pairs are one per DISPLAYED FIELD: a DVD encoder emits a single
  /// user_data right after the GOP header holding a pair for every field of the
  /// GOP (verified on real discs: the triple count equals the summed field count
  /// of the GOP's pictures, including the 3:2-pulldown repeats). Timestamping
  /// them all at the GOP header — as this scanner used to — shows captions up to
  /// half a second early.
  /// Far more pictures than any real GOP holds; see the picture_start_code case.
  static const _maxPicturesPerGop = 600;

  void _flushGop({bool advanceClock = false}) {
    // Display order: temporal_reference is the picture's position in display
    // order, so walking the pictures in that order gives each one the field
    // offset at which it appears on screen.
    final byDisplayOrder = List<int>.generate(_gopPictures.length, (i) => i)
      ..sort((a, b) => _gopPictures[a].tr.compareTo(_gopPictures[b].tr));
    var gopFields = 0;
    for (final index in byDisplayOrder) {
      _gopPictures[index].fieldOffset = gopFields;
      gopFields += _gopPictures[index].fields;
    }

    // Field offset per pair, then a stable sort so packets that map to the same
    // field keep the order they were transmitted in.
    final events = <_CcEvent>[];
    for (final packet in _gopPackets) {
      final base =
          packet.picture < 0 ? 0 : _gopPictures[packet.picture].fieldOffset;
      for (var i = 0; i < packet.pairs.length; i++) {
        final pair = packet.pairs[i];
        events.add(_CcEvent(base + i, events.length, pair.$1, pair.$2));
      }
      // The CC pairs span the whole GOP, so they are a lower bound on its
      // length when the picture headers are missing or incomplete (synthetic
      // streams, or a GOP truncated by a cell boundary).
      final extent = base + packet.pairs.length;
      if (extent > gopFields) gopFields = extent;
    }
    events.sort((a, b) => a.field != b.field
        ? a.field.compareTo(b.field)
        : a.seq.compareTo(b.seq));

    for (final event in events) {
      if (event.b1 == 0 && event.b2 == 0) continue; // null padding
      nonNullCcPairs++;
      // One field is 1001/60000 s; _outputTicks counts whole frames.
      final ms = ((_outputTicks * 2 + event.field) * 1001) ~/ 60;
      decoder.processPair(ms, event.b1, event.b2);
    }

    _lastGopFields = gopFields;
    // Normally _parseGop moves the clock on, from the next GOP header's
    // timecode; without one the flushed pictures have to do it themselves.
    if (advanceClock) _outputTicks += gopFields ~/ 2;
    _gopPictures.clear();
    _gopPackets.clear();
  }

  /// Flushes the trailing GOP and returns the completed SRT document. Callers
  /// must use this rather than `decoder.buildSrt()`, which would drop the CC
  /// pairs of the last GOP.
  String buildSrt() {
    _flushGop();
    return decoder.buildSrt();
  }

  void _parseUserData(int start, int end) {
    // user_data bytes after start code (00 00 01 B2). Format recognition —
    // known signatures plus a structural fallback for signature-less variants —
    // lives in detectCcPayload (cc_format.dart).
    final layout = detectCcPayload(_buf, start, end);
    if (layout == null) return;
    ccPacketsDetected++;

    // Buffer the pairs; they are timestamped in _flushGop, once the GOP's
    // pictures (and therefore the display timeline) are fully known.
    final pairs = <(int, int)>[];
    final tripleStart = start + layout.tripleStart;
    for (int i = 0; i < layout.ccCount; i++) {
      final off = tripleStart + i * 3;
      final t0 = _buf[off];
      // NTSC field 1 (0xFC), field 2 (0xFD), or non-standard 0xFF EIA-608 triple.
      // 0xFE triples are DTVCC padding and take up no 608 field.
      if (t0 == 0xFC || t0 == 0xFD || t0 == 0xFF) {
        pairs.add((_buf[off + 1] & 0x7F, _buf[off + 2] & 0x7F));
      }
    }
    if (pairs.isEmpty) return;
    _gopPackets.add(_CcPacket(_gopPictures.length - 1, pairs));
  }
}

/// A picture header seen inside the GOP being scanned.
class _GopPicture {
  _GopPicture(this.tr);

  /// temporal_reference — the picture's index in display order within the GOP.
  final int tr;

  /// Displayed fields: 2 normally, 3 when repeat_first_field is set (3:2
  /// pulldown), 1 for a field picture. Assumed 2 until the picture coding
  /// extension is seen.
  int fields = 2;

  /// Offset in displayed fields from the start of the GOP; filled in by
  /// _flushGop once every picture of the GOP is known.
  int fieldOffset = 0;
}

/// CC pairs from one user_data packet, tagged with the picture they followed
/// (-1 when the packet came before the GOP's first picture).
class _CcPacket {
  _CcPacket(this.picture, this.pairs);
  final int picture;
  final List<(int, int)> pairs;
}

/// One EIA-608 pair placed on the GOP's field timeline. [seq] preserves
/// transmission order across a sort that is not otherwise stable.
class _CcEvent {
  _CcEvent(this.field, this.seq, this.b1, this.b2);
  final int field;
  final int seq;
  final int b1;
  final int b2;
}

// ---------------------------------------------------------------------------
// EIA-608 decoder
// ---------------------------------------------------------------------------

/// One completed caption line, with the screen position its PAC put it at.
class _CaptionLine {
  _CaptionLine(this.row, this.indent, this.text);

  /// Screen row 1–15 (1 is the top), or 0 when no PAC was seen.
  final int row;

  /// Column the line starts at, 0–28.
  final int indent;

  final String text;
}

class Eia608Decoder {
  /// Whether to keep the caption's horizontal position, by indenting each line
  /// with the column its PAC (and any tab offset) placed it at. Off means every
  /// line is left-trimmed, which loses e.g. a second speaker parked on the left.
  final bool horizontalPlacement;

  /// Whether to mark captions that sit in the top half of the screen (rows 1–7)
  /// with an `{\an8}` tag, so players don't move them over the picture the
  /// broadcaster deliberately kept clear.
  final bool verticalPlacement;

  /// Gap left between a caption's end and the next one's start, in ms. One NTSC
  /// frame by default; 0 makes cues touch, which flickers in some players.
  final int cueGapMs;

  Eia608Decoder({
    this.horizontalPlacement = true,
    this.verticalPlacement = true,
    this.cueGapMs = 33,
  });

  // Non-displayed memory (loaded during pop-on mode).
  final _ndm = <_CaptionLine>[];

  // Displayed memory (emitted SRT).
  final _srt = StringBuffer();
  int _srtIndex = 0;

  // Current partial line being assembled in non-displayed memory.
  final _lineBuf = StringBuffer();
  int _currentRow = 0;     // row set by last PAC (1–15)
  int _currentIndent = 0;  // column set by last PAC, plus any leading tab offset

  // Pending SRT entry: start_ms set on EOC (pop-on) or CR (roll-up).
  int? _entryStartMs;
  String? _entryText;
  int _lastProcessedMs = 0;

  // Roll-up mode state.
  bool _isRollUp  = false;
  int  _ruLines   = 2;

  // Whether an <i> tag is currently open in _lineBuf (set by mid-row codes).
  bool _italic = false;

  // Timestamp of the last RCL (Resume Caption Loading). Used to tell an erase
  // that is part of a caption load (RCL+erase at the same instant — this
  // disc emits an EDM in every load) from a standalone erase that blanks the
  // screen during a silence. Only the latter ends the displayed caption.
  int _lastRclMs = -1000000;

  // Deduplication: skip if pair == previous pair (EIA-608 sends each code twice).
  int _prevB1 = -1;
  int _prevB2 = -1;

  // EIA-608 basic character substitutions (after parity strip, 0x20–0x7F range).
  static const _charSub = <int, String>{
    0x2A: 'á', 0x5C: 'é', 0x5E: 'í', 0x5F: 'ó', 0x60: 'ú',
    0x7B: 'ç', 0x7C: '÷', 0x7D: 'Ñ', 0x7E: 'ñ', 0x7F: '■',
  };

  // Special character table: second byte of (0x11, 0x30–0x3F).
  static const _special = <int, String>{
    0x30: '®', 0x31: '°', 0x32: '½', 0x33: '¿', 0x34: '™',
    0x35: '¢', 0x36: '£', 0x37: '♪', 0x38: 'à', 0x39: ' ',
    0x3A: 'è', 0x3B: 'â', 0x3C: 'ê', 0x3D: 'î', 0x3E: 'ô', 0x3F: 'û',
  };

  // Extended character set 1 (Spanish/French): second byte of (0x12, 0x20–0x3F).
  static const _extendedSpanishFrench = <int, String>{
    0x20: 'Á', 0x21: 'É', 0x22: 'Ó', 0x23: 'Ú', 0x24: 'Ü', 0x25: 'ü',
    0x26: '‘', 0x27: '¡', 0x28: '*', 0x29: '’', 0x2A: '─', 0x2B: '©',
    0x2C: '℠', 0x2D: '•', 0x2E: '“', 0x2F: '”',
    0x30: 'À', 0x31: 'Â', 0x32: 'Ç', 0x33: 'È', 0x34: 'Ê', 0x35: 'Ë',
    0x36: 'ë', 0x37: 'Î', 0x38: 'Ï', 0x39: 'ï', 0x3A: 'Ô', 0x3B: 'Ù',
    0x3C: 'ù', 0x3D: 'Û', 0x3E: '«', 0x3F: '»',
  };

  // Extended character set 2 (Portuguese/German/Danish): (0x13, 0x20–0x3F).
  static const _extendedPortugueseGerman = <int, String>{
    0x20: 'Ã', 0x21: 'ã', 0x22: 'Í', 0x23: 'Ì', 0x24: 'ì', 0x25: 'Ò',
    0x26: 'ò', 0x27: 'Õ', 0x28: 'õ', 0x29: '{', 0x2A: '}', 0x2B: r'\',
    0x2C: '^', 0x2D: '_', 0x2E: '¦', 0x2F: '~',
    0x30: 'Ä', 0x31: 'ä', 0x32: 'Ö', 0x33: 'ö', 0x34: 'ß', 0x35: '¥',
    0x36: '¤', 0x37: '│', 0x38: 'Å', 0x39: 'å', 0x3A: 'Ø', 0x3B: 'ø',
    0x3C: '┌', 0x3D: '┐', 0x3E: '└', 0x3F: '┘',
  };

  // The plain-ASCII stand-in an encoder is expected to transmit immediately
  // before an extended character, for decoders that can't render it. A
  // compliant decoder backspaces over that stand-in — but only when it really
  // is one: encoders that omit it (or that follow the extended character with
  // its ASCII twin) would otherwise lose a real character.
  static const _extendedBase = <String, String>{
    'Á': 'A', 'À': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A',
    'á': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E', 'ë': 'e',
    'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I', 'ì': 'i', 'ï': 'i',
    'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ø': 'O',
    'ò': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
    'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U', 'ù': 'u', 'ü': 'u',
    'Ç': 'C', '©': 'C', 'ß': 's', '℠': 'S', '¥': 'Y',
    '¡': '!', '•': '*', '‘': "'", '’': "'", '“': '"', '”': '"',
    '«': '"', '»': '"',
  };

  // Extended quotes and their ASCII twins. Used to drop the duplicate when an
  // encoder sends both (seen on real discs: "teachers" + ’ + ' ).
  static const _quoteChars = '‘’“”«»';

  void processPair(int ms, int b1, int b2) {
    _lastProcessedMs = ms;

    // Deduplication: EIA-608 repeats each two-byte control code.
    // Null pairs (0,0) are always skipped; control code dedup is standard.
    final isDup = (b1 == _prevB1 && b2 == _prevB2 && b1 < 0x20);
    _prevB1 = b1;
    _prevB2 = b2;
    if (isDup) return;

    if (b1 < 0x20) {
      _handleControl(ms, b1, b2);
    } else {
      // Printable characters load into NDM (the off-screen buffer) and do NOT
      // affect the currently displayed caption — it stays until the next EOC
      // flip or EDM erase.
      _appendChar(b1);
      if (b2 >= 0x20) _appendChar(b2);
    }
  }

  void _handleControl(int ms, int b1, int b2) {
    // PAC (Preamble Address Code): b2 in 0x40–0x7F for these b1 values.
    // Must be checked first because 0x14/0x1C also have PAC variants (b2 >= 0x40).
    if (b2 >= 0x40 && b2 <= 0x7F) {
      // A PAC marks the row for text loading into NDM (off-screen). It does not
      // change what's currently displayed, so it must not end the shown caption.
      final row = _pacRow(b1, b2);
      if (row > 0) {
        if (row != _currentRow) {
          _flushLine();
          _currentRow = row;
        }
        // Attribute: 0–6 colour, 7 italics, 8–15 an indent of (attr − 8) × 4.
        final attribute = (b2 & 0x1E) >> 1;
        if (_lineBuf.isEmpty) {
          _currentIndent = attribute >= 8 ? (attribute - 8) * 4 : 0;
        }
        if (attribute == 7 && !_italic) {
          _lineBuf.write('<i>');
          _italic = true;
        }
      }
      return;
    }

    // Miscellaneous control codes on field 1 (0x14) or field 2 (0x1C).
    if (b1 == 0x14 || b1 == 0x1C) {
      switch (b2) {
        case 0x20: // RCL — Resume Caption Loading (pop-on mode)
          _isRollUp = false;
          _lastRclMs = ms;
        case 0x25: // RU2 — Roll-Up 2 lines
          _isRollUp = true; _ruLines = 2;
        case 0x26: // RU3
          _isRollUp = true; _ruLines = 3;
        case 0x27: // RU4
          _isRollUp = true; _ruLines = 4;
        case 0x28: // FON — Flash On
        case 0x29: // RDC — Resume Direct Caption
        case 0x2A: // TR  — Text Restart
        case 0x2B: // RTD — Resume Text Display
          break;

        case 0x21: // BS — Backspace
          _backspace();

        case 0x2C: // ENM — Erase Non-Displayed Memory
          if (_isStandaloneClear(ms)) {
            // Standalone ENM (nothing being loaded, not coincident with an RCL):
            // this encoder uses it to BLANK the screen during a silence. End the
            // displayed caption so it doesn't linger until the next one.
            _closeEntry(ms);
          } else {
            // Part of a caption load (text pending, or sent with the load's RCL):
            // flush the in-progress line but don't erase the displayed caption,
            // which lasts until the next EOC.
            _flushLine();
          }

        case 0x2D: // CR — Carriage Return
          _flushLine();
          if (_isRollUp && _ndm.isNotEmpty) {
            // Emit the visible window (last N lines) as a subtitle entry.
            _closeEntry(ms);
            final lines = _ruLines >= _ndm.length
                ? _ndm
                : _ndm.sublist(_ndm.length - _ruLines);
            _emitEntry(ms, _render(lines));
          }

        case 0x2E: // EDM — Erase Displayed Memory
          if (_isRollUp) {
            _closeEntry(ms);
            _ndm.clear();
          } else if (_isStandaloneClear(ms)) {
            // A genuine erase during a silence (see ENM). NOTE: this disc emits
            // an EDM inside every pop-on load sequence (right at the RCL); that
            // is NOT a clear — the caption stays until the next EOC — so it is
            // excluded by the RCL-coincidence check.
            _closeEntry(ms);
          }

        case 0x2F: // EOC — End of Caption (Flip Memories)
          _isRollUp = false;
          _flushLine();
          // The flip ends the currently displayed caption and shows the NDM
          // contents (if any). A displayed caption therefore lasts from its EOC
          // until the next EOC or EDM — not until the next caption pre-loads.
          _closeEntry(ms);
          if (_ndm.isNotEmpty) {
            _emitEntry(ms, _render(_ndm));
          }
          _ndm.clear();
      }
      return;
    }

    // Special characters: b1 == 0x11 (field 1) or 0x19 (field 2), b2 == 0x30–0x3F.
    if ((b1 == 0x11 || b1 == 0x19) && b2 >= 0x30 && b2 <= 0x3F) {
      final ch = _special[b2];
      if (ch != null) _lineBuf.write(ch);
      return;
    }

    // Extended character sets: b1 == 0x12/0x1A (Spanish/French) or 0x13/0x1B
    // (Portuguese/German/Danish), b2 == 0x20–0x3F. Field 2 uses the +8 variants.
    if (b2 >= 0x20 && b2 <= 0x3F) {
      final table = switch (b1) {
        0x12 || 0x1A => _extendedSpanishFrench,
        0x13 || 0x1B => _extendedPortugueseGerman,
        _ => null,
      };
      if (table != null) {
        final ch = table[b2];
        if (ch != null) _appendExtended(ch);
        return;
      }
    }

    // Tab offsets: b1 == 0x17 or 0x1F, b2 == 0x21–0x23 → 1–3 columns.
    if ((b1 == 0x17 || b1 == 0x1F) && b2 >= 0x21 && b2 <= 0x23) {
      // Before any text a tab shifts where the line starts, which is placement
      // rather than content; in mid-line it is just spacing.
      if (_lineBuf.isEmpty) {
        _currentIndent += b2 - 0x20;
      } else {
        _lineBuf.write(' ' * (b2 - 0x20));
      }
      return;
    }

    // Mid-row codes (styling): b1 == 0x11 or 0x19, b2 == 0x20–0x2F.
    // A mid-row code occupies a character cell, so it renders as a space.
    // 0x2E/0x2F turn italics on; any other (color) code resets attributes.
    if ((b1 == 0x11 || b1 == 0x19) && b2 >= 0x20 && b2 <= 0x2F) {
      final italicsOn = b2 == 0x2E || b2 == 0x2F;
      final atLineStart = _lineBuf.isEmpty;
      if (italicsOn) {
        // Space before the tag so whitespace stays outside the styled span.
        if (!atLineStart) _lineBuf.write(' ');
        if (!_italic) {
          _lineBuf.write('<i>');
          _italic = true;
        }
      } else {
        if (_italic) {
          _lineBuf.write('</i>');
          _italic = false;
        }
        if (!atLineStart) _lineBuf.write(' ');
      }
      // At line start the cell the code occupies shifts where the text begins;
      // written as a space it would just be trimmed off again.
      if (atLineStart) _currentIndent++;
      return;
    }
  }

  void _appendChar(int b) {
    final ch = _charSub[b] ?? String.fromCharCode(b);
    // An encoder that sent an extended quote may follow it with the ASCII twin
    // it was standing in for; keep only the extended one. The emptiness check
    // matters: every string contains '', so a quote opening a line would
    // otherwise look like a duplicate and be dropped.
    final last = _lastChar();
    if (last.isNotEmpty &&
        (ch == "'" || ch == '"') &&
        _quoteChars.contains(last)) {
      return;
    }
    _lineBuf.write(ch);
  }

  /// Writes an extended character, backspacing over the ASCII stand-in that
  /// precedes it — but only when the preceding character really is that
  /// stand-in, since not every encoder sends one.
  void _appendExtended(String ch) {
    if (_extendedBase[ch] == _lastChar()) _backspace();
    _lineBuf.write(ch);
  }

  /// Last character of the line under construction, or '' when empty.
  String _lastChar() {
    final s = _lineBuf.toString();
    return s.isEmpty ? '' : s.substring(s.length - 1);
  }

  /// Removes the last character, leaving any emitted markup intact.
  void _backspace() {
    final s = _lineBuf.toString();
    if (s.isEmpty || s.endsWith('>')) return;
    _lineBuf
      ..clear()
      ..write(s.substring(0, s.length - 1));
  }

  void _flushLine() {
    // Close an italics span left open by a mid-row code; attributes do not
    // persist across rows. A trailing bare '<i>' (no text after it) is
    // dropped by the replaceAll below rather than closed.
    if (_italic) {
      if (_lineBuf.isNotEmpty) _lineBuf.write('</i>');
      _italic = false;
    }
    final line =
        _lineBuf.toString().replaceAll('<i></i>', '').replaceAll('<i> </i>', ' ').trim();
    _lineBuf.clear();
    if (line.isNotEmpty) {
      _ndm.add(_CaptionLine(_currentRow, _currentIndent, line));
    }
  }

  /// Renders caption lines to SRT text, restoring the on-screen placement the
  /// PACs asked for: an indent per line, and `{\an8}` when the whole caption
  /// sits in the top half of the screen.
  String _render(List<_CaptionLine> lines) {
    final body = lines
        .map((l) => horizontalPlacement ? ' ' * l.indent + l.text : l.text)
        .join('\n');
    final atTop = verticalPlacement &&
        lines.every((l) => l.row > 0 && l.row <= 7);
    return atTop ? r'{\an8}' '$body' : body;
  }

  /// True when an erase command (ENM/EDM) is a real screen-blank rather than
  /// part of a caption load: nothing is being loaded into NDM and it doesn't
  /// belong to this load's RCL (this disc emits an EDM with every RCL).
  ///
  /// The erase follows its RCL by a field or two — pairs are transmitted one
  /// per field — whereas a screen-blank during a silence stands seconds clear
  /// of any load, so a short window separates the two reliably.
  bool _isStandaloneClear(int ms) =>
      _lineBuf.isEmpty && _ndm.isEmpty && (ms - _lastRclMs) > _rclWindowMs;

  /// How long after an RCL an erase still counts as part of that caption load.
  static const _rclWindowMs = 200;

  void _emitEntry(int startMs, String text) {
    _entryStartMs = startMs;
    _entryText    = text;
  }

  void _closeEntry(int endMs) {
    if (_entryStartMs == null || _entryText == null) return;
    var end = endMs <= _entryStartMs! ? _entryStartMs! + 3000 : endMs;
    // Stop one frame short of the next caption so consecutive cues don't touch.
    end -= cueGapMs;
    if (end <= _entryStartMs!) end = _entryStartMs! + 1;
    _srtIndex++;
    _srt
      ..writeln(_srtIndex)
      ..writeln('${_msToSrt(_entryStartMs!)} --> ${_msToSrt(end)}')
      ..writeln(_entryText!)
      ..writeln();
    _entryStartMs = null;
    _entryText    = null;
  }

  /// Returns the completed SRT document, flushing any open entry.
  String buildSrt() {
    _flushLine();
    // Close any unclosed entry with a 3-second default duration.
    _closeEntry(_lastProcessedMs + 3000);
    return _srt.toString();
  }

  // Returns the 1-based row number (1–15) for a PAC, or 0 when [b1] is not a
  // PAC base code. EIA-608 assigns rows via b1 (channel/row-set) and b2 bit 5
  // (row within set). Bit 3 of b1 selects the channel (CC1/CC3 vs CC2/CC4);
  // strip it for row lookup. Note the row sets are not in numeric order of b1,
  // and row 11 (base 0x10) is the odd one out with no pair.
  static int _pacRow(int b1, int b2) {
    final high = (b2 & 0x20) != 0 ? 1 : 0; // 0 → lower row, 1 → upper row of pair
    return switch (b1 & 0xF7) { // strip channel bit (bit 3)
      0x11 => high == 0 ?  1 :  2,
      0x12 => high == 0 ?  3 :  4,
      0x15 => high == 0 ?  5 :  6,
      0x16 => high == 0 ?  7 :  8,
      0x17 => high == 0 ?  9 : 10,
      0x10 => 11, // the only row with a single base code
      0x13 => high == 0 ? 12 : 13,
      0x14 => high == 0 ? 14 : 15,
      _ => 0,
    };
  }

  static String _msToSrt(int ms) {
    final h  =  ms ~/ 3600000;
    final m  = (ms % 3600000) ~/ 60000;
    final s  = (ms %   60000) ~/ 1000;
    final ms2 = ms % 1000;
    return '${_p2(h)}:${_p2(m)}:${_p2(s)},${_p3(ms2)}';
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');
  static String _p3(int v) => v.toString().padLeft(3, '0');
}
