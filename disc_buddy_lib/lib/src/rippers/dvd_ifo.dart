/// Pure parsers for the DVD-Video IFO structures (`VTS_xx_0.IFO`): VTS
/// attribute tables, PGC stream control, cell/chapter maps and the subtitle
/// palette. No I/O — callers hand in the file's bytes.
library;

import 'dart:typed_data';

import '../models/dvd_title.dart';

const _audioFormats = {0: 'AC3', 2: 'MP2', 3: 'MP2E', 4: 'LPCM', 6: 'DTS'};

/// Reads the VTS-level audio attribute table (offset 0x202).
Map<int, ({String lang, String codec, int channels})> readVtsAudioAttribs(
    Uint8List data, ByteData bd) {
  final result = <int, ({String lang, String codec, int channels})>{};
  try {
    final numAudio = bd.getUint16(0x202, Endian.big);
    for (var i = 0; i < numAudio && i < 8; i++) {
      final off  = 0x204 + i * 8;
      if (off + 4 > data.length) break;
      final fmt  = (data[off] >> 5) & 0x7;
      final ch   = (data[off + 1] & 0x7) + 1;
      final lang = (data[off + 2] > 0x20 && data[off + 3] > 0x20)
          ? String.fromCharCodes([data[off + 2], data[off + 3]])
          : '';
      result[i] = (lang: lang, codec: _audioFormats[fmt] ?? 'PCM', channels: ch);
    }
  } catch (_) {}
  return result;
}

/// Reads the VTS-level subtitle attribute table (offset 0x254).
Map<int, String> readVtsSubtitleAttribs(Uint8List data, ByteData bd) {
  final result = <int, String>{};
  try {
    final numSubs = bd.getUint16(0x254, Endian.big);
    for (var i = 0; i < numSubs && i < 32; i++) {
      final off  = 0x256 + i * 6;
      if (off + 4 > data.length) break;
      final lang = (data[off + 2] > 0x20 && data[off + 3] > 0x20)
          ? String.fromCharCodes([data[off + 2], data[off + 3]])
          : '';
      result[i] = lang;
    }
  } catch (_) {}
  return result;
}

/// Scans the PGC audio/subtitle control words and returns the active stream IDs.
///
/// PGC audio control (pgc + 0x0C, 8 × uint16):
///   high byte: bit7 = active, bits2-0 = sub-stream nr → MPEG ID 0x80+nr
/// PGC subtitle control (pgc + 0x1C, 32 × uint32):
///   see pgcSubId for bit layout.
({
  bool pgcOk,
  Set<int> activeAudio,
  Map<int, int> audioStreamIds,
  Set<int> activeSubs,
  Map<int, int> subStreamIds,
}) scanPgcStreams(
  Uint8List data,
  ByteData bd,
  int pgc,
  bool is16x9,
  Map<int, ({String lang, String codec, int channels})> vtsAudio,
) {
  final activeAudio    = <int>{};
  final audioStreamIds = <int, int>{};
  final activeSubs     = <int>{};
  final subStreamIds   = <int, int>{};
  final pgcOk          = pgc + 0x1C + 32 * 4 <= data.length;

  if (!pgcOk) {
    return (pgcOk: false, activeAudio: activeAudio, audioStreamIds: audioStreamIds,
            activeSubs: activeSubs, subStreamIds: subStreamIds);
  }

  for (var i = 0; i < 8; i++) {
    final ctrl = bd.getUint16(pgc + 0x0C + i * 2, Endian.big);
    if ((ctrl & 0x8000) != 0) {
      activeAudio.add(i);
      final nr    = (ctrl >> 8) & 0x07;
      final codec = vtsAudio[i]?.codec ?? '';
      // DVD private stream 1 sub-IDs are codec-range-specific:
      //   AC3/MP2: 0x80–0x87,  DTS: 0x88–0x8F,  LPCM: 0xA0–0xA7
      final base  = codec == 'DTS' ? 0x88 : codec == 'LPCM' ? 0xA0 : 0x80;
      audioStreamIds[i] = base + nr;
    }
  }

  for (var i = 0; i < 32; i++) {
    final ctrl  = bd.getUint32(pgc + 0x1C + i * 4, Endian.big);
    final subId = pgcSubId(ctrl, prefer16x9: is16x9);
    if (subId != null) {
      activeSubs.add(i);
      subStreamIds[i] = subId;
    }
  }

  // Post-process: when multiple IFO subtitle entries map to the same SID
  // (e.g. a disc where ALL entries share 4:3 stream_nr=0), look at the
  // widescreen/letterbox/pan-scan stream_nr bytes (even if inactive) for
  // a unique stream number to differentiate them.
  final usedSids = <int, int>{};
  for (var i = 0; i < 32; i++) {
    if (!subStreamIds.containsKey(i)) continue;
    final sid = subStreamIds[i]!;
    if (!usedSids.containsKey(sid)) {
      usedSids[sid] = i;
      continue;
    }
    // Duplicate SID — try wide, letterbox, pan-scan stream_nrs in order.
    final ctrl   = bd.getUint32(pgc + 0x1C + i * 4, Endian.big);
    final altNrs = [
      (ctrl >> 16) & 0x1F, // widescreen stream_nr
      (ctrl >>  8) & 0x1F, // letterbox stream_nr
       ctrl        & 0x1F, // pan-scan stream_nr
    ];
    for (final nr in altNrs) {
      final altSid = 0x20 + nr;
      if (!usedSids.containsKey(altSid)) {
        subStreamIds[i] = altSid;
        usedSids[altSid] = i;
        break;
      }
    }
    if (subStreamIds[i] == sid) subStreamIds[i] = 0x20 + i;
  }

  return (pgcOk: pgcOk, activeAudio: activeAudio, audioStreamIds: audioStreamIds,
          activeSubs: activeSubs, subStreamIds: subStreamIds);
}

List<AudioTrack> buildAudioTracks(
  Map<int, ({String lang, String codec, int channels})> vtsAudio,
  ({bool pgcOk, Set<int> activeAudio, Map<int, int> audioStreamIds,
    Set<int> activeSubs, Map<int, int> subStreamIds}) streams,
) {
  final tracks = <AudioTrack>[];
  for (final entry in vtsAudio.entries) {
    if (streams.pgcOk && !streams.activeAudio.contains(entry.key)) continue;
    final a = entry.value;
    tracks.add(AudioTrack(
      index:    entry.key,
      streamId: streams.audioStreamIds[entry.key] ?? (0x80 + entry.key),
      language: a.lang,
      codec:    a.codec,
      channels: a.channels,
    ));
  }
  return tracks;
}

List<SubtitleTrack> buildSubtitleTracks(
  Map<int, String> vtsSub,
  ({bool pgcOk, Set<int> activeAudio, Map<int, int> audioStreamIds,
    Set<int> activeSubs, Map<int, int> subStreamIds}) streams,
) {
  final tracks = <SubtitleTrack>[];
  for (final entry in vtsSub.entries) {
    if (streams.pgcOk && !streams.activeSubs.contains(entry.key)) continue;
    tracks.add(SubtitleTrack(
      index:    entry.key,
      streamId: streams.subStreamIds[entry.key] ?? (0x20 + entry.key),
      language: entry.value,
    ));
  }
  return tracks;
}

/// Extracts the cell sector ranges and chapter timestamps for one PGC.
({List<({int first, int last})> cells, List<Duration> chapters})
    scanPgcCells(Uint8List data, ByteData bd, int pgc, int durSeconds,
        {void Function(String)? onDiag}) {
  final cells    = <({int first, int last})>[];
  final chapters = <Duration>[];
  try {
    final cpbitRel   = bd.getUint16(pgc + 0xE8, Endian.big);
    final cpbitOff   = pgc + cpbitRel;
    final nrCells    = data[pgc + 3];
    final nrPrograms = data[pgc + 2];
    int bcdV(int b) => ((b >> 4) & 0xF) * 10 + (b & 0xF);

    final allFirstSectors = <int>[];
    final allLastSectors  = <int>[];
    final allCellSecs     = <int>[];
    // Diagnostics for the trailing-frame investigation (cell category byte:
    // bits 7–6 block mode, 5–4 block type, bit 3 seamless, bit 2 interleaved).
    final allCategories     = <int>[];
    final allFirstIlvuEnds  = <int>[]; // C_PBIT +12: first ILVU end sector
    final allLastVobuStarts = <int>[]; // C_PBIT +16: last VOBU start sector
    for (var c = 0; c < nrCells; c++) {
      final coff = cpbitOff + c * 24;
      if (coff + 24 > data.length) break;
      allFirstSectors.add(bd.getUint32(coff + 8,  Endian.big));
      allLastSectors.add(bd.getUint32(coff + 20, Endian.big));
      allCategories.add(data[coff]);
      allFirstIlvuEnds.add(bd.getUint32(coff + 12, Endian.big));
      allLastVobuStarts.add(bd.getUint32(coff + 16, Endian.big));
      final h = bcdV(data[coff + 4]);
      final m = bcdV(data[coff + 5]);
      final s = bcdV(data[coff + 6]);
      allCellSecs.add(h * 3600 + m * 60 + s);
    }

    // Copy-protection inserts dummy cells (zero or tiny BCD duration,
    // referencing other angles' sectors) around the real content.
    // Real cells are identified via the PGMAP:
    //
    //   firstReal: first PGMAP entry with non-zero BCD duration → scan
    //              backwards to also include any adjacent non-zero
    //              pre-chapter lead-in cells (not in PGMAP but played
    //              sequentially before the first chapter on hardware).
    //   lastReal:  last PGMAP entry, then extended while non-zero
    //              continuation cells remain (covers genuine multi-cell
    //              last chapters on unprotected discs).
    int firstReal = 0;
    int lastReal  = allCellSecs.isNotEmpty ? allCellSecs.length - 1 : 0;
    if (nrPrograms > 0) {
      final pgmapRel = bd.getUint16(pgc + 0xE6, Endian.big);
      final pgmapOff = pgc + pgmapRel;
      if (pgmapOff < data.length) {
        var pgmapAnchor = -1;
        for (var p = 0; p < nrPrograms && pgmapOff + p < data.length; p++) {
          final idx = data[pgmapOff + p] - 1;
          if (idx >= 0 && idx < allCellSecs.length && allCellSecs[idx] > 0) {
            pgmapAnchor = idx;
            break;
          }
        }
        if (pgmapAnchor < 0) {
          firstReal = (data[pgmapOff] - 1).clamp(0, allCellSecs.length - 1);
        } else {
          firstReal = pgmapAnchor;
          while (firstReal > 0 && allCellSecs[firstReal - 1] > 0) {
            firstReal--;
          }
        }

        final lastPgmapIdx = pgmapOff + nrPrograms - 1 < data.length
            ? (data[pgmapOff + nrPrograms - 1] - 1)
                .clamp(firstReal, allCellSecs.length - 1)
            : firstReal;
        lastReal = lastPgmapIdx;
        var accum = 0;
        for (var i = firstReal; i <= lastReal; i++) {
          accum += allCellSecs[i];
        }
        var next = lastReal + 1;
        while (next < allCellSecs.length &&
               allCellSecs[next] > 0 &&
               accum < durSeconds) {
          accum += allCellSecs[next];
          lastReal = next;
          next++;
        }
      }
    }

    // Shared trailing "stinger" cells: some discs (e.g. iCarly S1) end every
    // PGC with the same sub-second cell far past the main content — a single
    // GOP that shows up as one extra video frame plus an ffmpeg timestamp
    // discontinuity in the rip. Drop trailing cells with a zero-second BCD
    // playtime that do not adjoin the previous cell; genuine multi-cell
    // endings are contiguous and keep their cells.
    while (lastReal > firstReal &&
        allCellSecs[lastReal] == 0 &&
        allFirstSectors[lastReal] != allLastSectors[lastReal - 1] + 1) {
      onDiag?.call('dropping trailing stinger cell ${lastReal + 1}: '
          'sectors ${allFirstSectors[lastReal]}..${allLastSectors[lastReal]}');
      lastReal--;
    }

    final originalToFiltered = List.filled(allCellSecs.length, -1);
    var filteredCount = 0;
    final cellSecs = <int>[];
    for (var i = firstReal; i <= lastReal; i++) {
      final first = allFirstSectors[i];
      final last  = allLastSectors[i];
      if (last >= first) cells.add((first: first, last: last));
      // Interleaved / angle-block cells: report the unused C_PBIT sector
      // fields so a future VOBU-boundary trim can be validated against
      // real discs before changing read behavior.
      final cat = allCategories[i];
      if (onDiag != null && (cat & 0x34) != 0) {
        onDiag('cell ${i + 1}: category=0x${cat.toRadixString(16).padLeft(2, '0')} '
            'first=$first firstIlvuEnd=${allFirstIlvuEnds[i]} '
            'lastVobuStart=${allLastVobuStarts[i]} last=$last');
      }
      originalToFiltered[i] = filteredCount++;
      cellSecs.add(allCellSecs[i]);
    }

    if (nrPrograms > 0 && cellSecs.isNotEmpty) {
      final pgmapRel = bd.getUint16(pgc + 0xE6, Endian.big);
      final pgmapOff = pgc + pgmapRel;
      final cellStarts = <int>[0];
      for (final d in cellSecs) { cellStarts.add(cellStarts.last + d); }
      for (var prog = 0; prog < nrPrograms; prog++) {
        if (pgmapOff + prog >= data.length) break;
        final origCell = data[pgmapOff + prog] - 1;
        final filtCell = (origCell >= 0 && origCell < originalToFiltered.length)
            ? originalToFiltered[origCell]
            : -1;
        if (filtCell >= 0 && filtCell < cellStarts.length) {
          chapters.add(Duration(seconds: cellStarts[filtCell]));
        }
      }
    }
  } catch (_) {}
  return (cells: cells, chapters: chapters);
}

/// Reads the PGC Color Lookup Table at pgc + 0xA4 (16 × 4 bytes, YCbCr BT.601).
List<int> readPgcClut(Uint8List data, int pgc) {
  final clut = <int>[];
  if (pgc + 0xA4 + 64 <= data.length) {
    for (var i = 0; i < 16; i++) {
      final y  = data[pgc + 0xA4 + i * 4 + 1];
      final cb = data[pgc + 0xA4 + i * 4 + 2];
      final cr = data[pgc + 0xA4 + i * 4 + 3];
      clut.add(_ycbcrToRgb(y, cb, cr));
    }
  }
  return clut;
}

/// Returns the MPEG sub-stream ID (0x20–0x3F) for a PGC subpicture control
/// word, or null if the track is inactive in all four display modes.
///
/// For 16:9 content, widescreen streams are preferred so that the subtitle
/// data actually present in the VOB is selected. For 4:3 content, the 4:3
/// stream is preferred because it is always present when declared.
int? pgcSubId(int ctrl, {bool prefer16x9 = false}) {
  if (prefer16x9) {
    if ((ctrl & 0x00800000) != 0) return 0x20 + ((ctrl >> 16) & 0x1F); // wide (prefer)
    if ((ctrl & 0x80000000) != 0) return 0x20 + ((ctrl >> 24) & 0x1F); // 4:3 fallback
    if ((ctrl & 0x00008000) != 0) return 0x20 + ((ctrl >>  8) & 0x1F); // letterbox
    if ((ctrl & 0x00000080) != 0) return 0x20 +  (ctrl        & 0x1F); // pan-scan
  } else {
    if ((ctrl & 0x80000000) != 0) return 0x20 + ((ctrl >> 24) & 0x1F); // 4:3 (prefer)
    if ((ctrl & 0x00800000) != 0) return 0x20 + ((ctrl >> 16) & 0x1F); // wide
    if ((ctrl & 0x00008000) != 0) return 0x20 + ((ctrl >>  8) & 0x1F); // letterbox
    if ((ctrl & 0x00000080) != 0) return 0x20 +  (ctrl        & 0x1F); // pan-scan
  }
  return null;
}

String readAsciiFixed(Uint8List data, int offset, int length) {
  if (offset + length > data.length) return '';
  return String.fromCharCodes(
    data.sublist(offset, offset + length)
        .where((b) => b >= 0x20 && b < 0x7F),
  ).trim();
}

/// Converts a DVD YCbCr color (BT.601 studio swing) to 0xRRGGBB.
int _ycbcrToRgb(int y, int cb, int cr) {
  final r = (1.164 * (y - 16) + 1.596 * (cr - 128)).round().clamp(0, 255);
  final g = (1.164 * (y - 16) - 0.391 * (cb - 128) - 0.813 * (cr - 128)).round().clamp(0, 255);
  final b = (1.164 * (y - 16) + 2.018 * (cb - 128)).round().clamp(0, 255);
  return (r << 16) | (g << 8) | b;
}
