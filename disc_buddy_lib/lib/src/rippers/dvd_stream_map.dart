/// DVD stream mapping: finds the order in which ffmpeg will discover the
/// MPEG-PS private-stream sub-IDs of a title and turns that into explicit
/// `-map` / `-metadata` arguments in IFO order.
library;

import 'dart:async';
import 'dart:typed_data';

import '../models/dvd_title.dart';
import '../utils/languages.dart';

// ---------------------------------------------------------------------------
// VOB scan: find MPEG-PS private stream 1 sub-IDs for correct stream mapping
// ---------------------------------------------------------------------------

/// Streams through [src] looking for MPEG-PS private-stream-1 (0xBD) packets
/// Scans [src] for MPEG-PS private-stream-1 (0xBD) packets and records each
/// unique sub-stream ID in [wantedSids] in order of first appearance.
/// Stops as soon as all wanted SIDs have been found.
///
/// Only IFO-declared SIDs are passed as [wantedSids]. Scanning broader sets
/// (e.g. all 0x80–0x8F) picks up spurious SIDs from other angles in
/// multi-angle VOBs, inflating audio-index counts and causing invalid -map
/// arguments in ffmpeg.
///
/// Returns the SID discovery order and the byte offset at which the last SID
/// was found. The caller uses [lastSidByteOffset] to set ffmpeg's -probesize
/// so that ffmpeg discovers every stream before writing the MKV header.
Future<({List<int> sidOrder, int lastSidByteOffset})> scanVobSids(
  Stream<List<int>> src,
  Set<int> wantedSids,
) async {
  if (wantedSids.isEmpty) return (sidOrder: <int>[], lastSidByteOffset: 0);

  // The scan walks the packet structure instead of searching for the 0xBD
  // start code byte by byte: a pack header is skipped by its size, every PES
  // packet (video, audio, padding, navigation) by its declared length. The
  // bytes 00 00 01 BD also occur by chance inside a video packet; read as a
  // private-stream header they yield a random "sub-stream ID", and one that
  // lands in 0x20–0x3F counts as a subtitle stream ffmpeg never sees. That
  // shifts every real subtitle one index up, so `-map 0:s:N?` points past
  // the last stream and the title is ripped without subtitles (Mad Men S1
  // disc 3: phantom 0x34 / 0x2A ahead of the real 0x20).
  //
  // Safety cap: stop scanning after 600 MB even if not all SIDs are found.
  // The scan normally returns early the moment all IFO-declared SIDs have
  // been seen (see the early return below). The cap only matters when a
  // declared SID never actually materialises in the VOB — e.g. a stream the
  // IFO lists but that only exists on another angle. Without a cap such a
  // disc would force a read of the entire (multi-GB) title on every rip,
  // because the "found them all" condition can never be satisfied.
  //
  // The cap must sit ABOVE the latest-appearing real stream we've observed,
  // or a legitimately-late stream would be missed: Die Hard 4.0 SE has an
  // audio SID (0x85) first appearing at 281.9 MB and First Blood 3 has its
  // only subtitle SID at 518.8 MB. 600 MB clears both with headroom while
  // staying far below a full title. (Was mistakenly 60000*1024*1024 ≈ 58 GB,
  // which disabled the cap entirely.)
  const kScanCap  = 600 * 1024 * 1024;
  final order   = <int>[];
  final seen    = <int>{};
  var   totalBytes              = 0;
  var   lastTrackedSidByteOffset = 0;
  // Unparsed tail of the previous chunk (an incomplete header, < 300 bytes).
  var   carry = Uint8List(0);
  // Bytes at the start of the next chunk(s) that belong to a packet already
  // stepped over. [carry] is empty whenever this is non-zero.
  var   skip  = 0;

  await for (final chunk in src) {
    final window = carry.isEmpty
        ? (chunk is Uint8List ? chunk : Uint8List.fromList(chunk))
        : (Uint8List(carry.length + chunk.length)
            ..setRange(0, carry.length, carry)
            ..setRange(carry.length, carry.length + chunk.length, chunk));

    final winBase = totalBytes - carry.length;
    final len     = window.length;
    var   i = skip;

    while (i + 4 <= len) {
      if (window[i] != 0x00 || window[i+1] != 0x00 || window[i+2] != 0x01) {
        i++;
        continue;
      }
      final id = window[i+3];
      if (id == 0xBA) {
        // MPEG-2 pack header: 14 bytes + 0–7 stuffing bytes.
        if (i + 14 > len) break;
        i += (window[i+4] & 0xC0) == 0x40 ? 14 + (window[i+13] & 0x07) : 4;
        continue;
      }
      if (id < 0xBB) {
        // Video-layer start code (only seen while resynchronising).
        i += 4;
        continue;
      }
      // System header or PES packet: 16-bit length follows the start code.
      if (i + 6 > len) break;
      final pktLen = (window[i+4] << 8) | window[i+5];
      if (id == 0xBD) {
        if (i + 9 > len) break;
        final sidOff = i + 9 + window[i + 8];
        if (sidOff >= len) break;
        final sid = window[sidOff];
        if (!seen.contains(sid)) {
          // Track ALL subtitle SIDs (0x20–0x3F) even if not in wantedSids.
          // DVDs sometimes store companion subtitle streams for different
          // display modes (widescreen/letterbox) alongside the declared
          // streams. ffmpeg counts all of them when assigning stream indices,
          // so we must include them in the discovery order too.
          final isWanted  = wantedSids.contains(sid);
          final isSubSid  = sid >= 0x20 && sid <= 0x3F;
          if (isWanted || isSubSid) {
            order.add(sid);
            seen.add(sid);
            lastTrackedSidByteOffset = winBase + sidOff;
          }
          if (isWanted) {
            final wantedSeen = seen.intersection(wantedSids);
            if (wantedSeen.length == wantedSids.length) {
              return (sidOrder: order, lastSidByteOffset: lastTrackedSidByteOffset);
            }
          }
        }
      }
      // Length 0 = unbounded (not used on DVD): fall back to a byte search.
      i += pktLen > 0 ? 6 + pktLen : 4;
    }

    totalBytes += chunk.length;
    if (totalBytes >= kScanCap) break; // Safety cap — don't scan beyond this
    if (i >= len) {
      skip  = i - len;
      carry = Uint8List(0);
    } else {
      skip  = 0;
      carry = Uint8List.fromList(Uint8List.sublistView(window, i));
    }
  }

  return (sidOrder: order, lastSidByteOffset: lastTrackedSidByteOffset);
}

// ---------------------------------------------------------------------------
// Build ffmpeg map + metadata arguments
// ---------------------------------------------------------------------------

/// Builds -map and -metadata arguments based on the VOB SID scan.
///
/// Method (identical to rip.sh + dvdread_pipe.py):
/// 1. Determine per SID the ffmpeg discovery index (separate for audio and subs).
/// 2. Use explicit -map 0:a:FF_IDX / -map 0:s:FF_IDX? in IFO order.
/// 3. Metadata uses output indices 0,1,2... (= IFO order), not ffmpeg discovery order.
List<String> buildMapAndMetaArgs({
  required DvdTitle title,
  required List<int> sidOrder,    // MPEG SIDs in ffmpeg discovery order
  required List<String> audioLangs,
  required List<String> subLangs,
}) {
  // Build SID → ffmpeg discovery index, separate per type (a:N and s:N count separately)
  final audioSidToFf = <int, int>{};
  final subSidToFf   = <int, int>{};
  var aCount = 0;
  var sCount = 0;
  for (final sid in sidOrder) {
    // Audio ranges: AC3/DTS 0x80–0x8F, LPCM 0xA0–0xA7
    if (((sid >= 0x80 && sid <= 0x8F) || (sid >= 0xA0 && sid <= 0xA7)) &&
        !audioSidToFf.containsKey(sid)) {
      audioSidToFf[sid] = aCount++;
    } else if (sid >= 0x20 && sid <= 0x3F && !subSidToFf.containsKey(sid)) {
      subSidToFf[sid] = sCount++;
    }
  }

  final args = <String>['-map', '0:v'];

  // Audio maps in IFO order; for missing SIDs: ascending fallback index
  for (final a in title.audioTracks) {
    final ffIdx = audioSidToFf[a.streamId] ?? aCount++;
    args.addAll(['-map', '0:a:$ffIdx']);
  }

  // Subtitle maps — empty subLang means the user removed that track.
  final keptSubs = <(SubtitleTrack, String)>[];
  for (var i = 0; i < title.subtitleTracks.length; i++) {
    final lang = i < subLangs.length ? subLangs[i] : '';
    if (lang.isNotEmpty) keptSubs.add((title.subtitleTracks[i], lang));
  }
  for (final (s, _) in keptSubs) {
    final ffIdx = subSidToFf[s.streamId] ?? sCount++;
    args.addAll(['-map', '0:s:$ffIdx?']);
  }

  args.addAll(codecAndMetaArgs(
    title: title, audioLangs: audioLangs, keptSubs: keptSubs));
  return args;
}

/// Computes the kept-subtitle list (drops tracks the user cleared via an empty
/// language entry), preserving IFO order.
List<(SubtitleTrack, String)> keptSubtitles(
    DvdTitle title, List<String> subLangs) {
  final keptSubs = <(SubtitleTrack, String)>[];
  for (var i = 0; i < title.subtitleTracks.length; i++) {
    final lang = i < subLangs.length ? subLangs[i] : '';
    if (lang.isNotEmpty) keptSubs.add((title.subtitleTracks[i], lang));
  }
  return keptSubs;
}

/// Codec selection + per-stream metadata + subtitle dispositions, shared by
/// the discovery-order ([buildMapAndMetaArgs]) and stream-id
/// ([buildMapAndMetaArgsById]) map builders. Output indices 0,1,2… follow the
/// map order (= IFO order), independent of how the streams were mapped.
List<String> codecAndMetaArgs({
  required DvdTitle title,
  required List<String> audioLangs,
  required List<(SubtitleTrack, String)> keptSubs,
}) {
  final args = <String>[
    '-c:v', 'copy',
    '-c:a', 'copy',
    '-c:s', 'copy',
    '-avoid_negative_ts', 'make_zero',
  ];

  // Video language: take from first audio track (DVD has no per-stream video language)
  if (audioLangs.isNotEmpty && audioLangs.first.isNotEmpty) {
    args.addAll(['-metadata:s:v:0', 'language=${audioLangs.first}']);
  }

  for (var i = 0; i < title.audioTracks.length; i++) {
    final a = title.audioTracks[i];
    final lang = i < audioLangs.length ? audioLangs[i] : '';
    if (lang.isNotEmpty) {
      args.addAll(['-metadata:s:a:$i', 'language=$lang']);
    }
    args.addAll(['-metadata:s:a:$i', 'title=${a.codec} ${channelLabel(a.channels)}']);
  }
  for (var i = 0; i < keptSubs.length; i++) {
    args.addAll(['-metadata:s:s:$i', 'language=${keptSubs[i].$2}']);
  }

  // Subtitle dispositions: first kept track = default.
  if (keptSubs.isNotEmpty) {
    args.addAll(['-disposition:s:0', 'default']);
    for (var i = 1; i < keptSubs.length; i++) {
      args.addAll(['-disposition:s:$i', '0']);
    }
  }

  return args;
}

/// Builds -map/-metadata args WITHOUT a pre-scan, mapping each stream by its
/// MPEG stream id (`-map 0:i:0x80`). ffmpeg resolves the id to whatever output
/// index it lands on, so we don't need to know the discovery order.
///
/// Audio maps are non-optional: if a declared id isn't found, ffmpeg fails,
/// which the caller detects and falls back to the two-pass scan. Subtitle maps
/// are optional (`?`) since declared subs may legitimately be absent.
List<String> buildMapAndMetaArgsById({
  required DvdTitle title,
  required List<String> audioLangs,
  required List<String> subLangs,
}) {
  final args = <String>['-map', '0:v:0'];
  for (final a in title.audioTracks) {
    args.addAll(['-map', '0:i:0x${a.streamId.toRadixString(16)}']);
  }
  final keptSubs = keptSubtitles(title, subLangs);
  for (final (s, _) in keptSubs) {
    args.addAll(['-map', '0:i:0x${s.streamId.toRadixString(16)}?']);
  }
  args.addAll(codecAndMetaArgs(
    title: title, audioLangs: audioLangs, keptSubs: keptSubs));
  return args;
}
