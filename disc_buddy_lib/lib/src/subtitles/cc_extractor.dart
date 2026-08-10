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

    final srt = scanner.decoder.buildSrt();
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

    final srt = scanner.decoder.buildSrt();
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

  // Frame counter within current GOP (for sub-second timing).
  int _frameInGop = 0;

  final Eia608Decoder decoder = Eia608Decoder();

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
        _parseGop(i + 4);
        _frameInGop = 0;
        i += 8;
      } else if (type == 0x00) {
        // picture_start_code — count frames within GOP.
        _frameInGop++;
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
      _outputTicks += (delta >= 0 && delta < maxNormalDelta) ? delta : _frameInGop;
    }
    _lastGopTicks = ticks;
  }

  void _parseUserData(int start, int end) {
    // user_data bytes after start code (00 00 01 B2). Format recognition —
    // known signatures plus a structural fallback for signature-less variants —
    // lives in detectCcPayload (cc_format.dart).
    final layout = detectCcPayload(_buf, start, end);
    if (layout == null) return;
    ccPacketsDetected++;

    // Continuous output position = ticks at this GOP's start + frames since it.
    final ms = ((_outputTicks + _frameInGop) * 1001) ~/ 30;

    final tripleStart = start + layout.tripleStart;
    for (int i = 0; i < layout.ccCount; i++) {
      final off = tripleStart + i * 3;
      final t0 = _buf[off];
      final b1 = _buf[off + 1] & 0x7F;
      final b2 = _buf[off + 2] & 0x7F;
      // NTSC field 1 (0xFC), field 2 (0xFD), or non-standard 0xFF EIA-608 triple.
      if (t0 == 0xFC || t0 == 0xFD || t0 == 0xFF) {
        if (b1 != 0 || b2 != 0) {
          nonNullCcPairs++;
          decoder.processPair(ms, b1, b2);
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// EIA-608 decoder
// ---------------------------------------------------------------------------

class Eia608Decoder {
  // Non-displayed memory (loaded during pop-on mode).
  final _ndm = <String>[];

  // Displayed memory (emitted SRT).
  final _srt = StringBuffer();
  int _srtIndex = 0;

  // Current partial line being assembled in non-displayed memory.
  final _lineBuf = StringBuffer();
  int _currentRow = 0;  // row set by last PAC (1–15)

  // Pending SRT entry: start_ms set on EOC (pop-on) or CR (roll-up).
  int? _entryStartMs;
  String? _entryText;
  int _lastProcessedMs = 0;

  // Roll-up mode state.
  bool _isRollUp  = false;
  int  _ruLines   = 2;

  // Timestamp of the last RCL (Resume Caption Loading). Used to tell an erase
  // that is part of a caption load (RCL+erase at the same instant — this
  // disc emits an EDM in every load) from a standalone erase that blanks the
  // screen during a silence. Only the latter ends the displayed caption.
  int _lastRclMs = -1;

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
      if (row > 0 && row != _currentRow) {
        _flushLine();
        _currentRow = row;
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
          if (_lineBuf.isNotEmpty) {
            final s = _lineBuf.toString();
            _lineBuf
              ..clear()
              ..write(s.substring(0, s.length - 1));
          }

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
            _emitEntry(ms, lines.join('\n'));
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
            _emitEntry(ms, _ndm.join('\n'));
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

    // Tab offsets: b1 == 0x17 or 0x1F, b2 == 0x21–0x23 → 1–3 spaces.
    if ((b1 == 0x17 || b1 == 0x1F) && b2 >= 0x21 && b2 <= 0x23) {
      _lineBuf.write(' ' * (b2 - 0x20));
      return;
    }

    // Mid-row codes (styling): b1 == 0x11 or 0x19, b2 == 0x20–0x2F — ignore.
  }

  void _appendChar(int b) {
    final sub = _charSub[b];
    if (sub != null) {
      _lineBuf.write(sub);
    } else {
      _lineBuf.writeCharCode(b);
    }
  }

  void _flushLine() {
    final line = _lineBuf.toString().trim();
    _lineBuf.clear();
    if (line.isNotEmpty) _ndm.add(line);
  }

  /// True when an erase command (ENM/EDM) is a real screen-blank rather than
  /// part of a caption load: nothing is being loaded into NDM and it doesn't
  /// coincide with this load's RCL (this disc emits an EDM with every RCL).
  bool _isStandaloneClear(int ms) =>
      _lineBuf.isEmpty && _ndm.isEmpty && ms != _lastRclMs;

  void _emitEntry(int startMs, String text) {
    _entryStartMs = startMs;
    _entryText    = text;
  }

  void _closeEntry(int endMs) {
    if (_entryStartMs == null || _entryText == null) return;
    if (endMs <= _entryStartMs!) endMs = _entryStartMs! + 3000;
    _srtIndex++;
    _srt
      ..writeln(_srtIndex)
      ..writeln('${_msToSrt(_entryStartMs!)} --> ${_msToSrt(endMs)}')
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

  // Returns the 1-based row number (1–15) for a PAC.
  // EIA-608 assigns rows via b1 (channel/row-set) and b2 bit 5 (row within set).
  // Bit 3 of b1 selects the channel (CC1/CC3 vs CC2/CC4); strip it for row lookup.
  static int _pacRow(int b1, int b2) {
    final high = (b2 & 0x20) != 0 ? 1 : 0; // 0 → lower row, 1 → upper row of pair
    return switch (b1 & 0xF7) { // strip channel bit (bit 3)
      0x11 => high == 0 ?  1 :  2,
      0x12 => high == 0 ?  3 :  4,
      0x15 => high == 0 ?  5 :  6,
      0x16 => high == 0 ?  7 :  8,
      0x17 => high == 0 ?  9 : 10,
      0x13 => high == 0 ? 11 : 12,
      0x14 => high == 0 ? 13 : 14,
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
