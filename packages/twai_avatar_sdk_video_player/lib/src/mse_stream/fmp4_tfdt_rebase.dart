import 'dart:typed_data';

/// Rewrites the `tfdt` boxes inside every `moof` of a fragmented MP4
/// slice so each track's `base_media_decode_time` starts at 0.
///
/// # Why
///
/// The muse wire delivers fMP4 fragments with absolute wire-timeline
/// `tfdt` values — the fMP4 spec allows a session to keep a monotonically-
/// increasing decode-time counter across its lifetime. When the sink
/// slices out a sub-range of the wire stream (a single sealed turn or
/// clause), the fragments in that slice still carry their original
/// absolute `tfdt` values.
///
/// Android's `video_player` / ExoPlayer treats the resulting standalone
/// MP4 as broken: it reads the moov (declaring duration=0) then reads
/// the fragments and computes a duration that collapses to ~1ms because
/// the fragment start times don't line up with the moov's zero baseline.
/// Symptom on Android: `initialize()` succeeds, `value.duration = 1ms`,
/// video ends immediately, no playback frames render.
///
/// The 2026-07-14 ffmpeg-remux fix (`-reset_timestamps 1`) handled this
/// on Windows but ffmpeg isn't on Android's PATH so the fallback code
/// path shipped a broken MP4. This function replaces the ffmpeg call
/// with a pure-Dart rewrite: portable, deterministic, ~0ms overhead
/// per turn (single linear scan).
///
/// # What this does
///
/// Walks the top-level box tree of [bytes] in place. For each `moof`
/// encountered, walks its child `traf` boxes. Each `traf` contains a
/// `tfhd` (track_ID) and a `tfdt` (base_media_decode_time). Records the
/// FIRST `tfdt` seen per track_ID and subtracts that base from every
/// subsequent `tfdt` for the same track. Video and audio are rebased
/// independently so A/V sync is preserved.
///
/// Zero allocations for the walk (uses [ByteData.sublistView]).
/// Mutates [bytes] in place.
///
/// # Scope
///
/// - Full box iteration at top level, moof, and traf.
/// - `tfdt` version 0 (32-bit) and version 1 (64-bit).
/// - Any number of tracks.
///
/// Does NOT touch `mvhd` / `mehd` duration fields — the player derives
/// duration from the rebased fragments once they line up with zero.
///
/// # Correctness notes
///
/// - Box size can be 0 ("to end of buffer") or 1 ("size in next 8
///   bytes as uint64"). Both handled; malformed sizes stop the walk
///   cleanly without corrupting the buffer.
/// - MP4 is big-endian throughout; [ByteData.getUint32] /
///   [ByteData.getUint64] default to big-endian.
///
/// Returns the same [bytes] instance for chaining convenience.
Uint8List rebaseFmp4Tfdt(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final perTrackBase = <int, int>{};

  final end = bytes.length;
  var pos = 0;
  while (pos + 8 <= end) {
    final boxSize = _readBoxSize(view, pos, end);
    if (boxSize == null) break;
    final type = _readBoxType(bytes, pos);
    if (type == 'moof') {
      _walkMoof(bytes, view, pos + 8, pos + boxSize, perTrackBase);
    }
    pos += boxSize;
  }
  return bytes;
}

void _walkMoof(
  Uint8List bytes,
  ByteData view,
  int start,
  int end,
  Map<int, int> perTrackBase,
) {
  var pos = start;
  while (pos + 8 <= end) {
    final boxSize = _readBoxSize(view, pos, end);
    if (boxSize == null) return;
    final type = _readBoxType(bytes, pos);
    if (type == 'traf') {
      _walkTraf(bytes, view, pos + 8, pos + boxSize, perTrackBase);
    }
    pos += boxSize;
  }
}

void _walkTraf(
  Uint8List bytes,
  ByteData view,
  int start,
  int end,
  Map<int, int> perTrackBase,
) {
  int? trackId;
  int? tfdtBoxPos;
  int? tfdtVersion;
  int? currentTfdt;

  var pos = start;
  while (pos + 8 <= end) {
    final boxSize = _readBoxSize(view, pos, end);
    if (boxSize == null) break;
    final type = _readBoxType(bytes, pos);
    switch (type) {
      case 'tfhd':
        // tfhd payload: [version(1)][flags(3)][track_ID(4)][optional...]
        // track_ID at pos + 8 (header) + 4 (version_flags) = pos + 12.
        if (pos + 16 <= end) {
          trackId = view.getUint32(pos + 12);
        }
      case 'tfdt':
        // tfdt payload: [version(1)][flags(3)][base_media_decode_time(4|8)]
        if (pos + 12 <= end) {
          final ver = view.getUint8(pos + 8);
          tfdtVersion = ver;
          tfdtBoxPos = pos;
          if (ver == 1) {
            if (pos + 20 <= end) currentTfdt = view.getUint64(pos + 12);
          } else {
            if (pos + 16 <= end) currentTfdt = view.getUint32(pos + 12);
          }
        }
    }
    pos += boxSize;
  }

  if (trackId != null && tfdtBoxPos != null && currentTfdt != null) {
    final base = perTrackBase.putIfAbsent(trackId, () => currentTfdt!);
    final rebased = currentTfdt - base;
    if (tfdtVersion == 1) {
      view.setUint64(tfdtBoxPos + 12, rebased);
    } else {
      view.setUint32(tfdtBoxPos + 12, rebased < 0 ? 0 : rebased);
    }
  }
}

/// Reads a box header's size field. Handles the two special values
/// (size==0 → to end of buffer, size==1 → 64-bit largesize follows).
/// Returns `null` on malformed sizes so the walk stops cleanly.
int? _readBoxSize(ByteData view, int pos, int end) {
  if (pos + 8 > end) return null;
  final size32 = view.getUint32(pos);
  if (size32 == 1) {
    if (pos + 16 > end) return null;
    final size64 = view.getUint64(pos + 8);
    if (size64 < 16 || pos + size64 > end) return null;
    return size64;
  }
  if (size32 == 0) {
    return end - pos;
  }
  if (size32 < 8 || pos + size32 > end) return null;
  return size32;
}

String _readBoxType(Uint8List bytes, int pos) {
  return String.fromCharCodes(bytes, pos + 4, pos + 8);
}

/// Stamps inflated duration values into every `mvhd`, `tkhd`, and
/// `mdhd` box inside an fMP4 init segment.
///
/// # Why
///
/// The muse init segment ships mvhd/tkhd/mdhd durations set to 0
/// (correct per the fMP4 spec — actual duration is derived from
/// fragments). Android's `video_player_android` / ExoPlayer reads
/// those durations literally and reports `value.duration = 1ms`,
/// which causes the player to stop playback immediately after
/// starting. `video_player.value.position` advances from 0 to 1ms
/// then halts, even though the file contains ~22s of decodable
/// fragments. The tfdt rebase alone doesn't fix this — the player
/// never gets past its own duration read.
///
/// Stamping an inflated duration (default 1 hour) makes the player
/// play until it actually runs out of bytes, at which point the
/// sink's position-poll detects the quiet and advances the queue.
///
/// # What this does
///
/// Walks the moov box, then each child. For every `mvhd`, `tkhd`,
/// and `mdhd`, reads the box's timescale (or inherits the movie
/// timescale from `mvhd` for `tkhd`), computes duration =
/// timescale * [fakeSeconds], and writes it into the duration field.
/// Handles both version-0 (32-bit fields) and version-1 (64-bit)
/// forms of each box per ISO/IEC 14496-12.
///
/// Clamps the stamped uint32 duration to `0x7FFFFFFF` to avoid the
/// sign-bit trap that some decoders hit on unsigned values ≥ 2^31.
///
/// Mutates [initSegment] in place. Returns it for chaining.
Uint8List stampFmp4InitDurations(
  Uint8List initSegment, {
  int fakeSeconds = 3600,
}) {
  final view = ByteData.sublistView(initSegment);
  final end = initSegment.length;
  var pos = 0;
  int movieTimescale = 1000; // sane default before we've seen mvhd
  while (pos + 8 <= end) {
    final size = _readBoxSize(view, pos, end);
    if (size == null) return initSegment;
    final type = _readBoxType(initSegment, pos);
    if (type == 'moov') {
      // Two-pass: first find mvhd's timescale (tkhd durations are in
      // movie timescale), then stamp everything.
      movieTimescale = _findMovieTimescale(initSegment, view, pos + 8, pos + size);
      _stampMoovChildren(
        initSegment,
        view,
        pos + 8,
        pos + size,
        movieTimescale,
        fakeSeconds,
      );
    }
    pos += size;
  }
  return initSegment;
}

int _findMovieTimescale(Uint8List bytes, ByteData view, int start, int end) {
  var pos = start;
  while (pos + 8 <= end) {
    final size = _readBoxSize(view, pos, end);
    if (size == null) return 1000;
    final type = _readBoxType(bytes, pos);
    if (type == 'mvhd') {
      final ver = view.getUint8(pos + 8);
      // timescale offset from box start: v=0 → 8+4+4+4=20, v=1 → 8+4+8+8=28
      final tsOff = pos + (ver == 1 ? 28 : 20);
      if (tsOff + 4 <= end) return view.getUint32(tsOff);
    }
    pos += size;
  }
  return 1000;
}

void _stampMoovChildren(
  Uint8List bytes,
  ByteData view,
  int start,
  int end,
  int movieTimescale,
  int fakeSeconds,
) {
  var pos = start;
  while (pos + 8 <= end) {
    final size = _readBoxSize(view, pos, end);
    if (size == null) return;
    final type = _readBoxType(bytes, pos);
    switch (type) {
      case 'mvhd':
        _writeHeaderDuration(
          view,
          pos,
          durationOffsetV0: 24,
          durationOffsetV1: 32,
          isDuration64: true,
          timescale: movieTimescale,
          fakeSeconds: fakeSeconds,
        );
      case 'trak':
        _stampTrakChildren(
          bytes,
          view,
          pos + 8,
          pos + size,
          movieTimescale,
          fakeSeconds,
        );
    }
    pos += size;
  }
}

void _stampTrakChildren(
  Uint8List bytes,
  ByteData view,
  int start,
  int end,
  int movieTimescale,
  int fakeSeconds,
) {
  var pos = start;
  while (pos + 8 <= end) {
    final size = _readBoxSize(view, pos, end);
    if (size == null) return;
    final type = _readBoxType(bytes, pos);
    switch (type) {
      case 'tkhd':
        // tkhd.duration is in movie timescale.
        _writeHeaderDuration(
          view,
          pos,
          durationOffsetV0: 28,
          durationOffsetV1: 36,
          isDuration64: true,
          timescale: movieTimescale,
          fakeSeconds: fakeSeconds,
        );
      case 'mdia':
        _stampMdiaChildren(bytes, view, pos + 8, pos + size, fakeSeconds);
    }
    pos += size;
  }
}

void _stampMdiaChildren(
  Uint8List bytes,
  ByteData view,
  int start,
  int end,
  int fakeSeconds,
) {
  var pos = start;
  while (pos + 8 <= end) {
    final size = _readBoxSize(view, pos, end);
    if (size == null) return;
    final type = _readBoxType(bytes, pos);
    if (type == 'mdhd') {
      final ver = view.getUint8(pos + 8);
      // mdhd timescale offset: v=0 → 8+4+4+4=20, v=1 → 8+4+8+8=28
      final tsOff = pos + (ver == 1 ? 28 : 20);
      if (tsOff + 4 > end) return;
      final trackTimescale = view.getUint32(tsOff);
      _writeHeaderDuration(
        view,
        pos,
        durationOffsetV0: 24,
        durationOffsetV1: 32,
        isDuration64: true,
        timescale: trackTimescale,
        fakeSeconds: fakeSeconds,
      );
    }
    pos += size;
  }
}

/// Writes an inflated duration value into a version-aware header box.
///
/// [durationOffsetV0] / [durationOffsetV1] are offsets from the box's
/// start (inclusive of the 8-byte header) where the duration field
/// lives for each version. mvhd/mdhd have 32-bit v0 durations and
/// 64-bit v1 durations. tkhd is the same pattern. [isDuration64] here
/// is true when the v1 duration is 64-bit (all three boxes we handle).
///
/// The value stamped is `timescale * fakeSeconds`, clamped to
/// 0x7FFFFFFF for the 32-bit v0 case so the sign bit stays clear.
void _writeHeaderDuration(
  ByteData view, // ignore: unused_element_parameter
  int boxStart, {
  required int durationOffsetV0,
  required int durationOffsetV1,
  required bool isDuration64,
  required int timescale,
  required int fakeSeconds,
}) {
  final ver = view.getUint8(boxStart + 8);
  final value = timescale * fakeSeconds;
  if (ver == 1 && isDuration64) {
    view.setUint64(boxStart + durationOffsetV1, value);
  } else {
    final clamped = value > 0x7FFFFFFF ? 0x7FFFFFFF : value;
    view.setUint32(boxStart + durationOffsetV0, clamped);
  }
}
