# Invariant Rules

This repo treats invariants as typed, named rules instead of ad hoc log strings.

This file is not the user's interface. It is the agent's encoding guide.

For recoverable invalid states, pair this file with `SELF_HEALING.md`. This file explains how to name and emit the broken truth; `SELF_HEALING.md` explains how to choose and prove the bounded repair action.

The user should be able to describe a failure in plain language, for example:

- "Avery still sees Blake online after Blake disconnected."
- "Both devices look ready in the backend, but one UI is still stuck in requested."
- "The sender can hold to talk even though the peer is not actually ready."

The agent's job is to translate that report into a typed invariant, add the detector at the authoritative seam, and make future occurrences show up automatically in diagnostics and merged logs.

The goal is:

1. detect a violated assumption at the authoritative seam
2. emit a stable invariant ID into diagnostics
3. surface that same ID from merged multi-device diagnostics
4. turn the violation into a checked-in regression

If the violation is clearly recoverable, the additional goal is to converge the app/backend back to a valid state without requiring force quit, manual reset, or manual peer intervention. Use `SELF_HEALING.md` for that repair design.

Use this file when you are adding a new invariant rule or teaching an agent how to do it.

## Plain-Language Intake

When a user reports a bug, do not ask them to write invariant IDs or formal rule text first.

Instead:

1. restate the report as a broken truth
2. decide who is authoritative for that truth
3. decide whether the rule is `local`, `backend`, `pair`, or `convergence`
4. encode the invariant in code
5. emit a stable invariant ID into diagnostics
6. make sure merged diagnostics can rediscover it later
7. add the regression scenario/test

The desired workflow is:

- the user reports the problem in normal product/debug language
- the agent translates it into an invariant
- the system logs it automatically when it happens again
- merged diagnostics discovers the same invariant ID later without requiring another human interpretation pass

## Current rule surfaces

- app-side snapshot and projection checks:
  - `Turbo/AppDiagnostics.swift`
- merged multi-device and convergence checks:
  - `scripts/merged_diagnostics.py`
- distributed regressions and proofs:
  - `scenarios/*.json`
  - `TurboTests/TurboTests.swift`
  - `STATE_MACHINE_TESTING.md`

## Rule anatomy

Every invariant rule should define:

- `invariantId`
  - stable, checked-in, string identifier
  - format: `<subject>.<claim>`
  - examples:
    - `selected.ready_without_join`
    - `selected.backend_ready_ui_not_live`
    - `pair.backend_ready_ui_not_live`
    - `channel.stale_membership_on_session_connect`
- `scope`
  - one of:
    - `local`
    - `backend`
    - `pair`
    - `convergence`
- authoritative seam
  - the narrowest place that can actually know the rule is violated
- predicate
  - the exact condition that means the rule failed
- evidence
  - the fields, IDs, and projections needed to debug it
- regression target
  - the lowest-leverage test that should prevent recurrence

## Where a rule belongs

Choose the smallest seam that can prove the rule.

- put the rule in Swift diagnostics when one device can already prove the contradiction from its own typed state or backend snapshot
- put the rule in the merged diagnostics analyzer when the rule depends on multiple device views or cross-device convergence
- put the rule in the backend when the backend is the authority for the fact, such as transmitter exclusivity or canonical readiness

Do not put pair or convergence rules only in client-side logs. One device cannot prove those alone.
Do not treat a distributed-state bug as fully encoded if every invariant lives only in the UI or merged analyzer while the backend owns the broken fact.

For distributed app/backend bugs:

- at least one invariant should exist at the backend/domain seam when the backend is authoritative for the violated truth
- client-side invariants should describe projection contradictions, not replace backend ownership
- merged invariants should help rediscover cross-device fallout, not be the only place the broken truth is observable

## Relationship to self-healing

An invariant is observability. A self-heal is a repair policy.

Do not automatically repair every invariant. Add a repair only when the bad state is provably invalid and there is a safe owner for convergence:

- backend stale, client can prove it: emit the invariant and send an idempotent backend repair such as leave/clear-membership
- client stale, backend already converged: emit or preserve the invariant evidence and clear the stale local coordinator state
- ambiguous or in-flight: wait for a callback, attempt ID, or timeout before repairing

See `SELF_HEALING.md` for the full taxonomy, current examples, and proof checklist.

## Naming rules

Rule IDs must stay stable over time. They are the handle that ties together:

- diagnostics
- merged analysis
- handoffs
- bug reports
- regression tests

Use these conventions:

- keep IDs short and factual
- describe the broken truth, not the symptom
- prefer `selected.*` for selected-session projection rules
- prefer `pair.*` for merged multi-device rules
- prefer `channel.*` or `backend.*` for backend-owned rules

Good:

- `selected.ready_without_join`
- `selected.peer_joined_ui_not_connectable`
- `pair.backend_ready_ui_not_live`

Bad:

- `ui_broken_again`
- `weird-ready-bug`
- `fix-me`

## Required evidence

Every emitted invariant violation should include enough context to reproduce and classify it.

At minimum include:

- `selectedPeerPhase` or equivalent typed phase
- relevant backend truth such as `backendSelfJoined`, `backendPeerJoined`, `backendPeerDeviceConnected`, `backendCanTransmit`, or readiness ADTs
- the capture reason or operation context
- device, channel, session, or handle identifiers when available

Prefer expected/observed context in the message or metadata over generic prose.

Good:

- `selectedPeerPhase=ready while isJoined=false`
- `backend says both sides are ready, but selectedPeerPhase=requested`

Bad:

- `session looks wrong`
- `state drift`

## App-side encoding

Use `DiagnosticsStore.recordInvariantViolation(...)` for explicit app-side violations.

Current pattern:

- `captureState(...)` evaluates a small catalog of snapshot invariants automatically
- explicit adapter or coordinator code may also call `recordInvariantViolation(...)` directly when it detects a real contract break
- invariant violations are exported in the `INVARIANT VIOLATIONS` transcript section and also recorded as diagnostics errors

Swift example:

```swift
diagnostics.recordInvariantViolation(
    invariantID: "selected.ready_without_join",
    scope: .local,
    message: "selectedPeerPhase=ready while isJoined=false",
    metadata: [
        "selectedPeerPhase": selectedPeerState.phase.rawValue,
        "isJoined": String(isJoined),
        "reason": reason,
    ]
)
```

Rules in `AppDiagnostics.swift` should stay cheap, deterministic, and based on already-derived typed state. Do not put expensive polling or remote fan-out there.

## Backend-side encoding

Use `turbo.service.internal.appendInvariantEvent` for explicit backend-owned invariant violations.

Current pattern:

- detect the violation at the backend-owned seam
- emit a stable invariant ID plus scope, source, message, and optional metadata
- expose the event through `/v1/dev/invariant-events/recent` so merged diagnostics can rediscover it later

Backend example:

```unison
_ =
  turbo.service.internal.appendInvariantEvent
    db
    currentUserId
    "backend.ptt_push_target_missing_token"
    "backend"
    "backend"
    "active transmit did not have a token-backed wake target"
    (Some metadata)
    ()
```

Keep backend invariant emitters narrow and authoritative. Emit them where the backend can prove the contradiction from its own state, not from client guesses.

## Merged multi-device encoding

Use `scripts/merged_diagnostics.py` for rules that depend on multiple device reports or merged convergence.

Current pattern:

- parse explicit invariant violations from the transcript
- derive additional pair/convergence violations from merged reports
- emit stable invariant IDs
- support `--json` for machine-readable output
- support `--fail-on-violations` for strict automation

Python example:

```python
violations.append(
    build_violation(
        subject="pair",
        invariant_id="pair.backend_ready_ui_not_live",
        scope="pair",
        message=(
            "backend is ready on both devices, but at least one UI is still "
            "not in a live session state"
        ),
    )
)
```

If a rule can already be emitted explicitly by the app, keep the merged rule aligned to the same `invariantId` when it is expressing the same broken truth.

## When to encode a test as an invariant

Do not try to turn every test into an invariant.

Use an invariant when the thing being tested is a durable system truth that should never be false in any real run, and when surfacing that failure in diagnostics would help classify future incidents quickly.

Good candidates for invariants:

- backend-authoritative truths that should hold across app runs, retries, reconnects, or duplicate delivery
- local projection contradictions that one device can already prove from typed state plus backend snapshot
- pair or convergence truths that merged multi-device diagnostics can prove after the fact
- bugs where the same broken truth should appear in logs, merged analysis, handoffs, and the regression suite under one stable ID

Keep a normal test when the assertion is mostly about:

- a pure function example such as `f(x) == y`
- a parser, formatter, helper, or algorithm edge case
- a reducer transition sample that is useful as executable specification but does not need production diagnostics
- implementation details whose failure would not be useful to surface as an incident-level invariant

Rules of thumb:

1. If it is a timeless truth about valid state, make it an invariant.
2. If it is an example, edge case, or algorithm contract, keep it as a normal test.
3. If it is distributed, pair the invariant with a checked-in scenario, not just a unit test.
4. If it would help you debug or classify a future production failure, it probably deserves an invariant ID.
5. Do not replace tests with invariants. The invariant gives observability; the tests and scenarios prove the detector, the fix, and the regression.

Examples:

- "backend says both sides are ready, but at least one UI is still not live" should be an invariant
- "this helper normalizes handles correctly" should stay a normal test
- "this reducer maps event A to state B" usually stays a normal test unless that transition encodes a named system truth that should also surface in diagnostics

## Test obligations

An invariant is not done when it only logs.

Each new invariant should usually produce:

- one lower-level reducer, projection, or backend test for the rule itself
- one checked-in simulator scenario if the bug is distributed and reproducible there

Use this order:

1. encode the invariant
2. reproduce the bug with a scenario if it is distributed
3. add the lower-level regression test
4. fix the code
5. rerun the strict merge path

## Agent workflow

When an agent sees a new distributed bug report:

1. restate the bug as a violated invariant
2. decide whether the rule is `local`, `backend`, `pair`, or `convergence`
3. choose a stable `invariantId`
4. add detection at the authoritative seam
5. emit exact expected/observed evidence
6. add or update a checked-in simulator scenario when the behavior is distributed
7. add the lower-level regression test
8. fix the reducer, coordinator, adapter, or backend seam
9. verify with strict merged diagnostics

In other words:

- the user speaks the bug
- the agent encodes the invariant
- the system logs and rediscovers it

## Commands

Manual inspection:

- `just simulator-scenario-merge`
- `just simulator-scenario-merge-local`

Strict check:

- `just simulator-scenario-merge-strict`
- `just simulator-scenario-merge-local-strict`

Machine-readable output:

- `python3 scripts/merged_diagnostics.py --json --fail-on-violations ...`

## Current invariant IDs

Current first-pass IDs in the repo:

- `selected.ready_without_join`
- `selected.ready_while_backend_cannot_transmit`
- `selected.backend_ready_ui_not_live`
- `selected.peer_joined_ui_not_connectable`
- `selected.stale_membership_peer_ready_without_session`
- `selected.local_join_failure_present`
- `selected.online_contact_projected_offline`
- `pair.backend_ready_ui_not_live`
- `pair.symmetric_peer_ready_without_session`
- `channel.stale_membership_on_session_connect`
- `transmit.stale_startup_side_effect`

Add new IDs here when you add new rules so the catalog remains discoverable.
