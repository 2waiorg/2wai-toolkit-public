# Cross-language conformance vectors

Mirrors of [`2waiorg/twai-protocol`](https://github.com/2waiorg/twai-protocol)
`conformance/vectors/` — the canonical spec-of-record for behaviors the Dart,
TypeScript, and (eventually) Python clients must implement identically. When
one changes upstream, all mirrors must be updated in lockstep.

Upstream location: `c:\Dev\twai-protocol\conformance\vectors\`

## Files here

- **`speaking-timeline.json`** — pts-gating for `speaking` events. Consumed by
  `test/speaking_gate_test.dart` via the pure `gateSpeaking()` function in
  `lib/src/speaking_gate.dart`. Byte-identical to upstream.

## Vectors still to mirror in

Both are consumed by the Dart conformance runner (Mason's P5 hand-off — see
`c:\Dev\twai-protocol\conformance\README.md:41-43`) alongside speaking-timeline:

- **`codec.json`** — MSE codec string + avcC profile-compat byte. Guards the
  2026-07-07 outage class.
- **`handshake-cases.json`** — server-side handshake accept/reject rules.
  Tests the client's handshake shape by driving `classifyHandshake` from the
  spec.

## Why they live here (not just fetched at test time)

Tests must be hermetic — no filesystem walk out of the package, no network.
Mirroring in and letting the upstream repo's `codegen:check` catch drift is
the same pattern the TS runner uses.
