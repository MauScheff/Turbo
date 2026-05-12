# Invariant Rules

This repo treats reliability bugs as broken named truths, not as ad hoc log strings.

Use this file when a bug report says some state "should be impossible", especially for distributed state, backend truth, app/backend contracts, selected-session projection, reconnect/retry behavior, or stale state. For recoverable invalid states, pair this with `SELF_HEALING.md`.

## Core Model

An invariant has one stable identity in `invariants/registry.json`, but the executable check belongs at the narrowest seam that can prove the truth.

- `invariants/registry.json`: canonical index for ID, owner, detector location, evidence, repair policy, and proof status.
- Swift reducer/projection: app-owned transition and derived-state rules.
- Unison/backend route/service/projection: backend-owned shared truth.
- `scripts/merged_diagnostics.py`: pair and convergence rules that require multiple device/backend perspectives.
- TLA+ or fuzz oracle: protocol interleavings, stale facts, ordering, monotonicity, or convergence classes.

Do not build a detached runtime that reads the registry and tries to enforce every rule generically. Most rules need typed local context; the state machine or backend seam that has that context is where the predicate should live.

Use these terms when they help:

- `precondition`: what must be true before accepting an event or command.
- `postcondition`: what must be true after a transition, route, projection, or repair.
- `invariant`: what must remain true for every valid state in that subsystem.

Prefer typed state machines and total transitions that make illegal states unrepresentable. Use explicit runtime invariant checks for cross-boundary, distributed, stale, or recoverable states that the type system cannot rule out alone.

## Intake Workflow

The user should be able to describe the failure in product/debug language:

- "Avery still sees Blake online after Blake disconnected."
- "Both devices look ready in the backend, but one UI is still stuck in requested."
- "The sender can hold to talk even though the peer is not actually ready."

The agent converts that report into a durable rule:

1. Restate the report as the broken truth, not the UI symptom.
2. Identify the owner: app, backend, pair/convergence, Apple/PTT/audio boundary, or ambiguous in-flight state.
3. Choose or update a stable `invariantId`.
4. Add detection at the authoritative seam.
5. Emit expected/observed evidence with stable IDs.
6. Choose the narrowest proof lane.
7. Add bounded self-healing only when the state is provably invalid and safely repairable.
8. Fix the owning subsystem.
9. Verify with the selected proof and, when relevant, strict merged diagnostics.

The user should not need to ask separately for classification, registration, fuzzing, TLA+, scenarios, or proof selection.

## Production Visibility

Invariant detection is not only a local-development feature. If the same bug can happen in TestFlight or production, the invariant must be visible or reconstructable from production-capable evidence.

Evidence paths:

- app diagnostics and invariant violations exported by shake-to-report
- iOS telemetry facts and telemetry events with `invariantId`
- Unison/backend telemetry facts and backend invariant events
- backend latest diagnostics snapshots and transcripts
- `just reliability-intake-shake`, `just reliability-intake`, and `just production-replay`

Single-runtime invariants should emit the `invariantId` where they are detected. True distributed invariants usually cannot be proven by one device; each runtime should emit correlated facts, and a later correlator should evaluate the pair/convergence predicate.

Required correlation fields, when available:

- user handle and device ID
- peer handle and peer device ID
- channel/session/attempt/transmit IDs
- selected phase and relationship
- backend readiness, membership, and transmit facts
- timestamps and capture reason

For distributed production invariants, choose one of these designs:

- Move the rule to the backend if the backend owns enough canonical state to prove it live.
- Emit per-device fact events and evaluate the predicate in telemetry, reliability intake, merged diagnostics, or a backend correlation job.
- Make shake-to-report preserve enough peer evidence for an on-demand merge.
- Mark the rule development-only only when production detection is explicitly not required.

## Where Rules Belong

Choose the smallest seam that can prove the rule.

- Put app-local rules in Swift diagnostics when one device can prove the contradiction from typed state or a backend snapshot.
- Put backend-owned rules in Unison when the backend owns the fact, such as canonical readiness, membership, request truth, wake-target selection, or transmitter exclusivity.
- Put pair/convergence rules in merged diagnostics when no single runtime has the whole predicate.

Do not treat a distributed-state bug as fully encoded if every invariant lives only in the UI or merged analyzer while the backend owns the broken fact. Client checks may fail closed, preserve evidence, or trigger safe repair, but they do not replace a backend fix for backend-owned truth.

## Naming And Evidence

Rule IDs must stay stable over time. They tie together diagnostics, telemetry, merged analysis, handoffs, bug reports, and regressions.

Use:

- `<subject>.<claim>`
- short factual names
- the broken truth, not the symptom
- `selected.*` for selected-session projection rules
- `pair.*` for merged multi-device rules
- `channel.*`, `backend.*`, or domain-specific prefixes for backend-owned rules

Good:

- `selected.ready_without_join`
- `selected.peer_joined_ui_not_connectable`
- `pair.backend_ready_ui_not_live`

Bad:

- `ui_broken_again`
- `weird-ready-bug`
- `fix-me`

Every emitted violation should include enough context to classify ownership and replay the failure. Prefer expected/observed facts over generic prose.

Good evidence:

- `selectedPeerPhase=ready while isJoined=false`
- `backendSelfJoined=true backendPeerJoined=true backendPeerDeviceConnected=false`
- `channelId=... deviceId=... attemptId=...`

## Encoding Rules

### App

Use `DiagnosticsStore.recordInvariantViolation(...)` for explicit app-side violations. Snapshot invariants may also be derived automatically in `Turbo/AppDiagnostics.swift`.

For state-machine code:

- Check event preconditions before applying events that should be rejected or ignored.
- Check transition postconditions after deriving next state when the reducer owns the fact.
- Check projection invariants where canonical state becomes UI or diagnostics state.

Do not crash production code for recoverable distributed invariant failures. Emit the invariant, fail closed in projection if needed, and use `SELF_HEALING.md` for bounded repair. Reserve debug assertions for programmer-only impossibilities.

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

### Backend

Use `turbo.service.internal.appendInvariantEvent` for backend-owned invariant events.

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

Keep backend emitters narrow and authoritative. Emit where the backend can prove the contradiction from its own state.

### Merged Diagnostics

Use `scripts/merged_diagnostics.py` for pair and convergence rules. It:

- parses app and backend invariant events
- merges iOS and backend telemetry
- converts complete telemetry state facts into snapshot facts
- derives pair/convergence violations
- supports `--json` and `--fail-on-violations`

If app/backend runtime already emits an invariant for the same broken truth, keep the merged rule aligned to the same `invariantId`. Use a new `pair.*` or `convergence.*` ID only when the merged view proves a broader contradiction.

## Proof Lanes

An invariant is not done when it only logs. Add the narrowest durable proof that would have failed before the fix.

Use:

- Swift or Unison reducer/property tests for pure transition or projection rules.
- Backend tests or route probes for backend-owned truth.
- TLA+ for protocol semantics, ownership, stale facts, monotonicity, convergence, or all interleavings.
- Seeded fuzzing for duplicate/drop/reorder/retry/reconnect/restart/timing families.
- Simulator scenarios when the concrete app/backend journey adds evidence beyond the smaller proof.
- Physical-device checks only for Apple/PTT/audio/hardware boundaries.

Useful commands:

- `just protocol-model-checks`
- `just simulator-fuzz-local <seed> <count>`
- `just simulator-fuzz-replay <artifact-dir>`
- `just simulator-fuzz-shrink <artifact-dir>`
- `python3 scripts/merged_diagnostics.py --json --fail-on-violations ...`

A scenario is valuable, but not mandatory for every physical-device discovery. If TLA+ plus a reducer/backend test proves the impossible state cannot be reached, and a simulator scenario would only restate the same pure rule slowly, document that decision in the registry or handoff.

## Registry

`invariants/registry.json` is the active catalog. Do not maintain a second hand-written list of current IDs in this file.

When adding or changing invariant IDs, update the registry and run:

```bash
python3 scripts/check_invariant_registry.py
```
