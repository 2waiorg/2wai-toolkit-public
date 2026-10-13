# Live-capture provenance

The vectors in this directory were written from shipped code and from the
production test fixtures ported alongside it. That is good evidence about what
our client does, and no evidence at all about what the wire actually carries. A
vector set derived entirely from one side of a protocol can be perfectly
self-consistent and still be wrong about the protocol.

So the shapes were checked against a real session. This file records that check:
what was captured, what it confirmed, and, just as importantly, what it did
**not** reach. Task 9.

Result: **PASS, zero mismatches.** Every shape the vectors assert was observed on
the wire exactly as asserted.

## The capture

| | |
|---|---|
| Date | 2026-08-24 |
| Environment | staging, `/livealman` |
| Scope | one real chat turn, end to end |
| Agent participant | `livealman-agent-AJ_GSopLRGgAYjo` |
| Records | 68 JSONL |
| Method | `probe_client.py --dump-data` |
| Tool provenance | `clg_pp_payment`, branch `fix/livekit-session-cap`, commit `c3fcced` |

The capture and this file were grepped for credentials before anything was
written down: **0 hits**. No tokens, no room URLs, no signed anything appears
below.

## Cross-check

| Vector assertion | Observed | |
|---|---|---|
| Speaking payload key set is exactly `{type, value}` | exactly `{type, value}`, no extra keys | MATCH |
| Reply frames carry `v: 1` | all 12 frames `v = 1` | MATCH |
| Reply frame key union is `{v, reply_id, seq, kind, text}` | exactly that union, nothing else | MATCH |
| `seq` starts at 0 and is contiguous | 0 through 11, no gaps, no repeats | MATCH |
| The terminal frame carries the whole reply | `end.text` equalled `"".join(delta.text)` byte for byte, 268 characters | MATCH |
| Fallback transcription reconstructs the same reply | 53 word-level chunks joining to exactly the terminal text | MATCH |
| Agent identity carries the `livealman-agent-` prefix | confirmed | MATCH |

The byte-for-byte terminal check is the one that matters most, because it is the
load-bearing assumption behind the split-tag contract in `reply-stream.json`:
the terminal frame is the backstop that repairs a tag split across deltas, and
that only works if the producer really does send the whole reply on the terminal
every time. One turn is not "every time", but it is no longer an assumption
about code we cannot see.

## Coverage, honestly

**Validated on the wire:** reply `kind` values `start`, `delta`, `end`. The
speaking pair. The transcription fallback. The agent prefix.

**Source-derived only, NOT yet observed:**

- reply `kind: "cancel"`
- reply `kind: "error"`
- `2wai.control` `kind: "mood"`
- `2wai.control` `kind: "scenario_state"`

These four remain exactly as strong as reading `brain_llm.py`, which is to say
reasonably strong and not verified. They are the paths a single happy-path turn
cannot reach: `cancel` needs an interruption, `error` needs a failure, and
neither control kind is emitted by the profile that was captured.

**A second capture closes all four**, and the shape of it is known: run with
`--barge-in-text` to force an interruption mid-reply (which exercises `cancel`),
against a mood-emitting profile (which exercises both control kinds). `error`
still needs a brain failure to coincide, so it may stay source-derived longer
than the others. Until that capture happens, treat those four vector shapes as
the best available reading of the producer rather than as confirmed wire.

## Example frames

Sanitized. Values are elided where this document records **shape** rather than
content; the verbatim records live in the capture JSONL, not here.

`2wai.reply`, the three validated kinds:

```
{"v": 1, "reply_id": "brain_<12 hex>", "seq": 0,  "kind": "start"}
{"v": 1, "reply_id": "brain_<12 hex>", "seq": 1,  "kind": "delta", "text": "<partial>"}
{"v": 1, "reply_id": "brain_<12 hex>", "seq": 11, "kind": "end",   "text": "<full reply, 268 chars>"}
```

Note the start frame has no `text` key at all, rather than an empty one.

`livealman`, the speaking pair (exact, nothing elided):

```
{"type": "speaking", "value": "start"}
{"type": "speaking", "value": "stop"}
```

`lk.transcription`, one chunk. Chunks are word-level and carry their **leading**
space, so a consumer concatenates them without inserting separators:

```
" <word>"
```

## Observed behaviour

Everything in this section is an **observation from one turn**, not a contract.
None of it is vectored, and an implementation is not wrong for differing. It is
recorded because each item is a trap somebody would otherwise fall into once,
expensively.

**The two text channels are not interchangeable, and diverge by about 17
seconds.** `2wai.reply` is LLM-paced and had finished at t=8.763. The
`lk.transcription` stream is speech-paced and ran t=8.572 through t=25.834, so
it was still arriving long after the reply protocol had completed. A consumer
that treats them as two views of the same thing, or that waits for both, will
either double-render or stall for the length of the spoken reply. The protocol
supersedes the fallback for exactly this reason (see `session-data.json`).

**`speaking: start` arrived AFTER reply frames seq 0 through 8.** The indicator
tracks audio, and audio lags text. A client that gates its text rendering on the
speaking indicator, which looks like a reasonable way to keep the bubble in sync
with the voice, would have added roughly 3.7 s of dead air to this turn while
the reply text was already in hand.

**`reply_id` looked like `brain_<12 lowercase hex>`.** Observed, not
contractual. `isReplyFrame` requires only a non-empty string, and nothing should
start parsing this.

**Delta chunking is uneven.** Five frames arrived inside 37 ms, then multiple
gaps of several hundred milliseconds. A consumer that assumes smooth arrival, or
that derives a typing animation from inter-frame timing, gets a stutter. The
transcription stream is the opposite: word-level and evenly paced.

**The agent participant reported `kind = 4` with `lk.agent_name` empty.** That
is automatic dispatch. Do not key agent detection on `lk.agent_name`; the
identity prefix is what the engine uses, and it is what was confirmed above.

**Text is UTF-8 verbatim on the wire.** A raw `e2 80 94` (U+2014) was observed
inside reply text. There is no ASCII-only path here, and no escaping layer to
undo. Anything that decodes these payloads has to decode UTF-8 properly, and
anything that measures length should be clear about whether it means bytes or
characters.
