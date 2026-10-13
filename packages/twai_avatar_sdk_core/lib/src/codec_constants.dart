/// Golden codec constants — single source of truth for the MSE
/// SourceBuffer type string + the avcC profile-compatibility byte the
/// 2wai pipeline emits.
///
/// **Every hardcoded `avc1.42*` literal in the SDK is a codec-check
/// violation.** This file is the ONE place these values live. The
/// `codec-check` CI job (see `tools/codec-check` upstream at
/// `c:\Dev\twai-protocol\tools\codec-check.mjs`) fails any build
/// carrying a non-golden literal anywhere else.
///
/// Byte-identical to `c:\Dev\twai-protocol\schema\constants.json`
/// (`MSE_CODECS`, `AVCC_PROFILE_COMPAT_BYTE`) and the
/// `codec.json` conformance vector.
///
/// **Origin story**: the 2026-07-07 outage was a `42E01F` (high
/// profile) vs `42C01F` (baseline) drift — the client added a
/// SourceBuffer with a codec the worker never emits, leaving `<video>`
/// stuck at `HAVE_METADATA`. The wrong literal was in three places;
/// this file exists so it can only ever be wrong in one.
library;

/// The MSE `SourceBuffer` type string. Muxed H.264 baseline + AAC-LC.
const String kMseCodecs = 'video/mp4; codecs="avc1.42C01F, mp4a.40.2"';

/// The `profile_compatibility` byte in the avcC box of a valid init
/// segment (0xC0 = 192). Clients that parse avcC to derive their
/// SourceBuffer codec should assert this byte matches; a byte of
/// 0xE0 (high profile) signals worker-side drift.
const int kAvccProfileCompatByte = 192;

/// The video-only fragment of [kMseCodecs] (no audio codec) — useful
/// when a caller only needs the video part for `isTypeSupported`
/// probing.
const String kAvcBaselineCodec = 'avc1.42C01F';
