# Reliability Guidelines

This document is the practical reliability guide for day-to-day work in Turbo.

- [`RELIABILITY_GOALS.md`](/Users/mau/Development/Turbo/RELIABILITY_GOALS.md)
  is the north star.
- [`RELIABILITY_PLAN.md`](/Users/mau/Development/Turbo/RELIABILITY_PLAN.md)
  is the longer execution roadmap.
- This file explains how to reason, model, test, and iterate so the system
  moves toward maximum reliability in concrete engineering work.

The target is not "write more tests." The target is:

> Every important claim has a clear owner, a named invariant, a narrow proof,
> and production-visible evidence when it fails.

## What "100% Reliable" Means Here

Turbo cannot literally guarantee perfect behavior across Apple PushToTalk, APNs,
carrier networks, batteries, permissions, radios, and process death.

The practical definition is:

- illegal states are made unrepresentable where possible
- remaining invalid states are detected at the authoritative seam
- recoverable invalid states are repaired through a bounded idempotent path
- retries, duplicates, reordering, reconnects, and stale data converge back to
  the same valid state
- production failures become deterministic diagnostics, replays, invariants, and
  regressions instead of stories

## Core Model

Reliability in Turbo should be built from a small set of mathematical ideas used
in a pragmatic way:

- **State machines**
  - model workflows as `State + Event -> NewState + Commands`
- **ADTs / sum types**
  - when a thing can be in exactly one mode, encode it as one variant, not a bag
    of booleans
- **Invariants**
  - facts that must always hold
- **Preconditions**
  - facts that must hold before an event or command is accepted
- **Postconditions**
  - facts that must hold after a transition or route completes
- **Idempotence**
  - retries and duplicate deliveries should be safe
- **Convergence**
  - reconnect, refresh, replay, and reordering should move replicas back toward
    the same valid truth
- **Leases / epochs / fencing**
  - runtime truth should expire or be superseded explicitly so stale rows cannot
    be mistaken for current capability

## Design Rules

### 1. Start With Ownership

Before editing code, restate the bug as a broken fact and decide who owns that
fact.

Common owners:

- backend/shared truth
- client-local reducer or projection
- pair/convergence rule requiring merged evidence
- Apple/PTT/audio boundary

Do not fix a backend-owned contradiction only in Swift because the UI happened
to show it first.

### 2. Treat The Backend As The Authority For Shared Truth

The backend should own:

- channel membership
- request/session relationship truth
- readiness and wake target truth
- active transmit ownership
- distributed convergence after retry/reconnect/disconnect

The client should own:

- local gesture state
- local audio/session/framework state
- optimistic local intent
- UI projection of already-owned facts

When app and backend both represent the same concept, backend/domain truth
should lead and the client should derive from it.

### 3. Prefer ADTs Over Boolean Bundles

Good:

- explicit relationship variants
- explicit readiness variants
- explicit session phases with phase-specific payloads

Bad:

- `isReady`, `isJoined`, `isConnecting`, `isReceiving` combinations that can
  contradict each other
- stringly typed status fields that decide behavior deep in reducers

If a weird distributed case is real, model it as a real state instead of hiding
it behind precedence rules.

### 4. Store Canonical Truth Once, Derive Everything Else

The same fact should not live independently in:

- UI latches
- coordinator booleans
- backend projections
- diagnostics text

Prefer one canonical fact plus derived projections.

### 5. Runtime Facts Need Epochs, Leases, Or Tombstones

Durable facts and runtime facts should not be modeled the same way.

- durable facts can often be monotonic
- runtime facts go stale and need lease, epoch, or fencing discipline

Current backend direction:

> stale rows may exist, but stale rows must never be sufficient to project
> current truth

That is the right rule for presence, readiness, active transmit, wake targets,
and other call-critical runtime facts.

### 6. Invalid State Must Fail Closed

If the system cannot prove a capability, it should not project that capability.

Examples:

- do not show `ready` if backend/audio evidence does not support transmit
- do not authorize transmit from stale membership
- do not project receiving without joined/session evidence

### 7. Self-Healing Is A Real Design Tool

When a bad state is clearly invalid and safely recoverable:

- detect it at the authoritative seam
- emit a stable invariant ID
- run one bounded idempotent repair
- keep repair evidence in diagnostics
- prove both:
  - the bad state repairs
  - the nearby valid in-flight state does not repair

Use [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md) for the
repair rules.

## The Reliability Loop

This should be the default operating loop:

1. A human reports the failure in product language.
2. The agent collects diagnostics with `just reliability-intake` or
   `just reliability-intake-shake`.
3. The broken fact is classified by owner.
4. The contradiction is named as an invariant.
5. The narrowest failing proof is added.
6. The owning subsystem is fixed.
7. The narrow proof passes.
8. The appropriate gate or hosted verification is run.
9. The bug remains as a permanent regression.

Express bug reports in this shape when possible:

```text
observer -> subject -> initial conditions -> event sequence -> expected
invariant -> observed violation
```

## Proof Order

Use the narrowest proof that can actually prove the claim.

1. **Swift reducer/domain/property tests**
   - pure app rules
   - projection logic
   - idempotence and convergence rules
2. **Unison/backend tests or route probes**
   - backend-owned truth
   - route/store/projection semantics
3. **Deterministic simulator scenarios**
   - distributed app/backend journeys
   - reconnect, refresh, partial join, wake-capable flows, transport faults
4. **Strict merged diagnostics**
   - pair and convergence contradictions
5. **TLA+ model checks**
   - protocol interleavings
   - retries, duplicates, reordering, stale snapshots, lease expiry
6. **Physical-device checks**
   - only for Apple/PTT/audio/background/lock-screen boundaries

Do not use an expensive scenario or device loop to prove a pure reducer rule if
a fast property test can prove it better.

## Which Tool To Use When

### Field Or Device Report

Start here when the issue came from debug, TestFlight, production-like, or a
physical device:

- `just reliability-intake @handle [peer]`
- `just reliability-intake-shake @handle <incidentId> [peer]`

Use this to gather merged diagnostics, classify ownership, and produce a replay
candidate when possible.

### Pure App Rule

Use:

- `just swift-test-target <name>`
- `just swift-test-suite`

This is the first proof lane for reducer transitions, projections, local
invariants, and self-healing behavior.

### Backend-Owned Truth

Use:

- Unison MCP / UCM to inspect and update `turbo/main`
- backend tests
- `just route-probe`
- `just route-probe-local`

Use this when the backend owns the fact and the client is only rendering it.

### Distributed Control-Plane Journey

Use:

- `just simulator-scenario <name>`
- `just simulator-scenario-suite`
- `just simulator-scenario-merge-strict`

This is the main proof loop for app/backend behavior that does not require the
real Apple boundary.

### Generated Failure Families

Use:

- `just simulator-fuzz-local <seed> <count>`
- `just simulator-fuzz-replay <artifact-dir>`
- `just simulator-fuzz-shrink <artifact-dir>`

Use fuzzing for duplicates, drops, reordering, reconnects, refresh races,
restart, and timing perturbations. Promote stable minimized failures into
checked-in scenarios only after they are useful as regressions.

### Protocol Semantics

Use:

- `just protocol-model-checks`

Use TLA+ when the question is about protocol design rather than one specific
implementation trace.

### Hosted Confidence

Use:

- `just reliability-gate-regressions`
- `just reliability-gate-smoke`
- `just reliability-gate-full`
- `just reliability-gate-local`
- `just postdeploy-check`
- `just deploy-staging-verified`
- `just deploy-production`

Use the smallest gate that matches the risk of the change.

## Expected Working Style

### When Investigating A Bug

- start from the smallest authoritative docs and source
- classify ownership before editing
- add the invariant before or with the fix
- prefer fixing the source over adding UI masking
- keep the proof close to the owner seam

### When Designing New Behavior

- decide the canonical state machine first
- decide who owns each fact
- decide what is durable truth versus runtime truth
- define invalid states explicitly
- define retry/duplicate/reorder/reconnect semantics before coding
- define observability and correlation IDs as part of the feature

### When Shipping Risky Changes

- prefer feature flags for risky protocol work
- run the appropriate gate before deploy
- run hosted verification after deploy
- inspect artifacts rather than trusting a green command at face value

## What Good Reliability Work Looks Like

A good reliability fix usually leaves behind:

- one stable invariant ID
- one authoritative detector
- one lower-level proof at the owning seam
- one scenario, replay, or probe if the bug was distributed
- clear diagnostics evidence
- no new ambiguity about ownership

A weak fix usually looks like:

- UI-only masking of a backend bug
- another boolean added to represent a mode
- logs without a stable invariant ID
- a scenario added without a lower-level proof underneath it
- repeated manual reproduction instead of a checked-in regression

## Recommended Reliability Review Questions

Use these questions during design and implementation reviews:

- What exact fact can be wrong here?
- Who is authoritative for that fact?
- Is this state modeled as an ADT or as scattered flags?
- What stale runtime fact could be mistaken for current truth?
- What happens under retry, duplicate, reconnect, reorder, refresh, restart,
  and timeout?
- What invariant would name the contradiction?
- Where should that invariant be detected?
- What is the narrowest proof lane?
- Can the system repair this safely and idempotently?
- If this fails in production, what evidence will we have?

## References

- [`README.md`](/Users/mau/Development/Turbo/README.md)
- [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md)
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md)
- [`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md)
- [`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md)
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md)
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md)
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)
