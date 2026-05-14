# Workflow Model

This is the canonical thinking model for agents working in Turbo.

Use this file for the stable engineering rules. Use [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md) to decide what to read next, and use [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for exact commands.

## Core Loop

Turbo work should move through this loop:

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

In practice:

1. Restate the request as the fact that must become true or the fact that was broken.
2. Collect the smallest diagnostics needed to locate ownership.
3. Identify the authoritative owner before editing.
4. Encode impossible behavior as a named invariant or regression.
5. Fix the owning subsystem, not only the visible symptom.
6. Prove the fix with the narrowest useful automated proof.
7. Run the release check or broader gate that matches the blast radius.

## Ownership

Classify every nontrivial bug before editing:

- **Backend/shared truth**: identity, devices, direct channels, invites, membership, readiness, wake targeting, websocket signaling, and active transmit ownership. Fix in Unison/backend or the shared contract.
- **Client projection/reducer**: local derivation, selected-peer projection, UI state, coordinator transitions, and app-local idempotence. Fix in Swift state machines, coordinators, or typed projections.
- **Pair/convergence rule**: contradictions that require two device perspectives or device plus backend evidence. Detect in merged diagnostics or move the rule to the backend if the backend owns enough state.
- **Apple/PTT/audio adapter**: PushToTalk UI, microphone permission, backgrounding, lock-screen wake, audio-session activation, and real capture/playback. Prove shared logic below the adapter first, then verify on device when required.

Do not patch backend-owned contradictions only in Swift. Client changes may add guardrails, diagnostics, fail-closed projection, or safer recovery, but they do not replace the backend or contract fix.

## Modeling Rules

Model workflows as explicit state machines:

```text
State + Event -> NewState + Commands
```

Default preferences:

- Use ADTs/sum types for mutually exclusive modes.
- Put state-specific data inside the matching variant.
- Store canonical truth once and derive projections from it.
- Normalize UI gestures, backend updates, websocket notices, timers, and Apple callbacks into typed events.
- Keep side effects in adapters, clients, coordinators, or command runners.
- Make retries, duplicates, reconnects, refreshes, and stale completions idempotent or convergent.
- Treat durable facts and runtime facts differently; runtime facts often need leases, epochs, fencing, tombstones, or explicit invalidation.
- Fail closed when a capability cannot be proven.

Avoid boolean bundles, string status values, UI latches, duplicated projections, and precedence rules that hide real distributed states.

## Invariants

Use [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md) for ID naming, registry rules, and emission APIs.

Rules:

- `invariants/registry.json` is the central index for invariant identity, owner, detector, evidence, repair policy, and proof status.
- Put executable checks at the narrowest seam that has typed context: Swift reducer/projection, Unison route/service/projection, merged diagnostics, TLA+, or fuzz oracle.
- Production-capable failures must be visible or reconstructable from production-capable evidence.
- Emit expected/observed machine-readable facts, not only prose.
- For recoverable invalid states, pair the invariant with [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md): bounded, idempotent repair plus diagnostics and proof that nearby valid in-flight states do not repair.

Useful report shape:

```text
observer -> subject -> initial conditions -> event sequence -> expected invariant -> observed violation
```

## Proof Order

Use the narrowest proof that can prove the claim:

1. Swift reducer/domain/property tests for pure app rules, projection logic, and app-local convergence.
2. Unison/backend tests or route probes for backend-owned truth and route/store/projection semantics.
3. TLA+ model checks for protocol semantics, ownership, stale facts, ordering, retries, duplicate/drop/reorder, leases, and all-interleaving questions.
4. Deterministic simulator scenarios for distributed app/backend journeys that add evidence beyond the smaller proof.
5. Strict merged diagnostics for pair/convergence evidence and scenario artifact validation.
6. Seeded fuzzing for generated interleavings, duplicate/drop/reorder, reconnect, retry, restart, refresh, and timing perturbation families.
7. Physical-device checks only for Apple PushToTalk UI, microphone permission, backgrounding, lock-screen wake, audio-session activation, and actual audio capture/playback.

Do not add slow scenario coverage just because a bug was first seen on a device if a lower-level proof or TLA+ plus a lower-level regression proves the impossible state better.

## Common Task Lanes

Use these lanes after reading `AGENTS.md`:

- **Pure Swift/app rule**: `SWIFT.md`, `TESTING.md`, relevant Swift source, then `just swift-test-target <name>` or `just swift-test-suite`.
- **Backend route/storage/deploy rule**: `TOOLING.md`, `UNISON.md`, `BACKEND.md`, and `MIGRATIONS.md` if persisted shapes can change.
- **Mixed app/backend bug**: inspect both backend projection/route and client projection before deciding where to fix.
- **Distributed scenario**: `STATE_MACHINE_TESTING.md`, scenario JSON, simulator runner, merged diagnostics.
- **Fuzz failure**: `SIMULATOR_FUZZING.md`, replay, shrink, ownership classification, then promote only stable useful regressions.
- **Protocol/interleaving question**: `TLA_PLUS.md` and `specs/tla/`.
- **Telemetry/shake/field report**: `PRODUCTION_TELEMETRY.md`, reliability intake, merged diagnostics, and production replay.
- **Recoverable invalid state**: `INVARIANTS.md` plus `SELF_HEALING.md`.

## Definition Of Done

A nontrivial fix is done when:

- ownership is explicit
- the source subsystem is fixed
- the important invariant or regression is named
- diagnostics preserve the evidence needed to debug recurrence
- the narrow proof passes
- the broader gate matches the blast radius
- backend changes are deployed when live behavior depends on them
- device-only claims are clearly separated from automated proof
