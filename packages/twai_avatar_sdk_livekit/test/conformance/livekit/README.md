# Conformance

The vectors in `vectors/livekit/` are the **cross-SDK contract** for the 2wai
avatar protocol, not a test suite for this repo. A second runner — Jim's Dart
port — replays the same JSON against the Dart client. So anything a rule needs
in order to be checkable lives in the JSON; the runner stays thin, and new
checks should stay declarative.

```bash
npm run build && npm run conformance      # the reference adapter
node conformance/harness/conformance.mjs --sut <path>   # any other client
```

Exit `0` conformant · `1` drift · `2` the SUT could not be loaded (a setup
problem, not a verdict).

## The files

| Vector | Pins | Source of truth |
|---|---|---|
| `mint-cases.json` | status/headers/body → enabled · disabled · rate-limited · unavailable; body-read accounting | `src/mintHelpers.ts`, `MintRateLimited` in `src/engineTypes.ts` |
| `envelope.json` | `send(text, extra)` → the `lk.chat` envelope; extras cannot clobber `v`/`request_id`/`text` | `src/engine.ts` `send()` |
| `reply-stream.json` | the `2wai.reply` reducer: seq gating, authoritative terminal text, the `sawProtocol` latch, the expression-tag vocabulary | `src/replyStream.ts` |
| `speaking-timeline.json` | `livealman`-topic data messages → speaking transitions | `src/engine.ts` `DataReceived` |
| `lifecycle-cases.json` | room events + timer expiries → final state, terminal cause, notices | `src/engine.ts` |
| `retry-policy.json` | host retry admission: attempt bound, rate-limit latch, owner gating, disconnect barrier | `src/roomLifecycle.ts` |
| `session-data.json` | fallback transcription, protocol-beats-fallback, `2wai.control` passthrough, send→reset | `src/engine.ts` (`consumeFallbackTranscription`, :543) |

Producer side of the wire, verified against `clg_pp_payment` `origin/staging`
`vm-mirror/.../livealman-host/`: `host.py` (topics, speaking payload, agent
identity, `parse_pp_chat`) and `brain_llm.py` (`_emit_reply`, `_emit_control`).

`vectors/livekit/CAPTURE.md` records the live cross-check of those shapes
against a real staging session (2026-08-24: PASS, zero mismatches), including
which reply and control kinds a single happy-path turn could **not** reach and
are still source-derived only. Read it before trusting a shape more than the
capture actually earned. It also carries observed-behaviour notes that are
deliberately not vectored.

`vectors/mse-archive/` holds the pre-2026-08-22 MSE vectors. They are **not
replayed** — MSE was retired as a chat transport — but `main_service` still
speaks that wire, so they are kept unmodified rather than deleted.

## SUT surface

An adapter exports one function per vector file. All may be async.

| Export | Given | Returns |
|---|---|---|
| `classifyMint(case)` | a `mint-cases` row | the `MintResult` fields, or `{throws, retryAfterSeconds \| detail}`, plus `jsonCalls` |
| `buildEnvelope(case)` | an `envelope` row | `{topic, envelope}` or `{throws}` |
| `reduceReply(scenario)` | a `reply-stream` scenario | `{events, accepted, sawProtocol}` |
| `gateSpeaking(scenario)` | a `speaking-timeline` scenario | the ordered `active` booleans |
| `classifyLifecycle(case, defaults)` | a `lifecycle` case + the file's `livekitRoomName`/`defaultMint` | a report object; only declared keys are compared |
| `classifyRetryPolicy(scenario)` | a `retry-policy` scenario | `{results, order, final}` |
| `driveSession(scenario, meta)` | a `session-data` scenario + `{agentIdentity}` | `{events}` |

## Runner obligations

Not all of these are visible from the JSON. A port that skips one produces a
green run that proves less than it looks like it does.

1. **Object compare is key-order independent; array order is significant.**
   Every array in these vectors is an ordered event log. Every object may be
   built in any order (a Dart `Map` certainly will be).
2. **Subset narrowing.** `lifecycle-cases` and `retry-policy`'s `expectFinal`
   compare *only* the keys the case declares. Do not require the adapter to
   report exactly that set.
3. **`uniqueAcrossBuilds` means build the row twice.** The two `request_id`s
   must differ. One build cannot prove freshness.
4. **Body-read accounting.** `bodyMustNotBeRead: true` asserts the body was read
   **0** times; every other `mint-cases` row asserts **exactly 1**. Several
   rules are "decide from the status alone", and counting is the only way to
   tell that apart from "read the body and happened to agree". Exactly-once
   matters because a real body is single-use.
5. **Per-scenario `try`/`catch`.** A SUT that *throws* must fail that one
   scenario and let the run continue — not abort the process. Several vectors
   exist precisely because a client used to crash (a `null` payload on the
   speaking topic), and a runner without this reports a crash as a lost run
   rather than as non-conformance. Keep this property.
6. **Unknown expectation shapes fail.** A row whose `expect` matches no known
   form must be reported as a failure, never allowed to fall through into
   another branch — otherwise a typo in a new vector ships as a passing check
   that tests nothing.
7. **Directive entries.** `reply-stream` `frames` may contain
   `{"op": "reset"}` or `{"op": "keepTags", "value": <bool>}`; these are not
   frames. Their slot in `expectAccepted` is `null`.
8. **Named owners are identities.** `retry-policy` names owners with strings;
   map each distinct name to one stable object/reference. The stale-owner rules
   are about identity, and JSON cannot carry a reference.

## Also in CI

`codec-check.mjs` is a separate step and the only remaining guard on the H.264
profile literal: it fails on any `avc1.42XXXX` in the tree that is not
`avc1.42C01F`. It is not part of this runner.
