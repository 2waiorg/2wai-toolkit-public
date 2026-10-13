# avatar_player_lab

TwaiPlayer capability exerciser — every SDK knob as a live control. The "kitchen sink with dials" reference app.

**Design principle:** EVERYTHING IS ON BY DEFAULT. Boot maxed-out; knobs dial features back to bisect issues. See [`docs/twai_player_capability_exerciser_plan.md`](../../docs/twai_player_capability_exerciser_plan.md) for the full plan.

**One codebase, two modes:**
- **Public showcase** (default) — polished landing for the marketing site
- **Dev mode** — every diagnostic panel unlocked (see `dev_mode.dart`)

See [`RUN.md`](RUN.md) for launch instructions.

## Current phase

**P0 — skeleton.** Shell, theme, dev-mode plumbing, adapter picker with 4 rows + 5 seeded avatars, P1 panel stubs. Sophi Summers plays end-to-end via penthouse-staging on boot.

Next: **P1** — wire up the six zero-SDK-change panels (Construction, Credentials, Methods, Streams, Idle, Immersive) with actual controls.
