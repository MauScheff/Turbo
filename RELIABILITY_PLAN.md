# Reliability Plan

This is the execution plan for making Turbo reliable by design.

[`RELIABILITY_GOALS.md`](/Users/mau/Development/Turbo/RELIABILITY_GOALS.md)
defines the north star. This document turns that goal into a staged roadmap
that can be tackled step by step.

The target structure is:

> Product behavior is represented by explicit ADTs and reducer transitions;
> invalid states are made unrepresentable when practical; remaining
> contradictions are detected at authoritative seams, reported with stable
> invariant IDs, repaired when safe, and proven by one integrated test and
> diagnostics loop.

## Current Assessment

Turbo already has strong reliability building blocks:

- Swift domain and coordinator ADTs for conversations, selected peers,
  transmit, wake, receive, backend sync, and control-plane projections.
- Backend Unison ADTs for request relationship, channel membership, channel
  status, readiness, audio readiness, wake readiness, and active transmitter.
- Reducer-style state machines and lower-level Swift tests.
- Checked-in simulator scenarios for distributed control-plane journeys.
- Merged diagnostics that can combine app snapshots, backend invariant events,
  telemetry, and exact-device scenario artifacts.
- Reliability gates in the `justfile`.
- A self-healing model for bounded, idempotent repairs.

The main weakness is not absence of reliability systems. It is fragmentation:

- several state machines own overlapping pieces of session, transmit, wake,
  receive, and backend projection truth
- some older state remains boolean-shaped or string-shaped beside newer ADTs
- diagnostics flatten typed state into text too early
- invariant IDs are spread across Swift, Python, backend code, tests, and docs
- simulator scenarios assert projections, but not invariants as first-class
  expectations
- reporting exists, but the system does not yet have a single typed spine from
  reducer transition to diagnostics artifact to merged report to regression

## Design Principles

Every reliability change should move the system toward these properties:

- **Single owner for each fact.** Backend truth, client-local truth, Apple
  framework truth, and derived UI projection should not compete.
- **ADT-first modeling.** Mutually exclusive modes should be sum types, not
  boolean bundles, nullable fields, or string status values.
- **Pure transition core.** Reducers decide state transitions and emit explicit
  effects. Adapters execute side effects and report typed events back.
- **Structured diagnostics.** Diagnostics should carry typed, machine-readable
  state first and human-readable text second.
- **Stable invariant IDs.** Every recurring contradiction should have one stable
  ID registered in one place.
- **Scenario-backed distributed proof.** Distributed bugs become deterministic
  simulator scenarios whenever the Apple boundary is not the thing being
  tested.
- **Safe repair only.** Self-healing is allowed only for provably invalid,
  recoverable states with a bounded, idempotent owner.
- **Production to regression.** Production failures should become replayable
  local artifacts, checked-in scenarios, probes, or reducer tests.

## Target Architecture

The reliable system should have this flow:

1. UI, backend responses, websocket notices, PTT callbacks, timers, audio
   events, and lifecycle events are normalized into typed events.
2. Reducers consume typed events and produce:
   - next state
   - explicit effects
   - optional invariant violations
   - optional repair intents
3. Effects are executed by adapters.
4. Adapter results come back as typed events.
5. A structured diagnostics projection is emitted for each important state
   transition and scenario artifact.
6. Merged diagnostics consumes the same structured projection shape used by
   tests.
7. Scenario expectations can assert both product state and invariant outcomes.
8. Reliability gates verify registry consistency, regressions, scenarios,
   merged diagnostics, and backend contract parity.

## Workstreams

### 1. Invariant Registry

- [x] Create one checked-in invariant registry and make it the source of truth.

Candidate path:

- `invariants/registry.json`

Each entry should include:

- `id`
- `scope`: `local`, `backend`, `pair`, or `convergence`
- `owner`: app, backend, merged diagnostics, Apple boundary, or mixed
- `authoritativeSeam`
- `predicate`
- `evidenceFields`
- `detectors`
- `regressions`
- `repairPolicy`: none, app repair, backend repair, or manual boundary
- `alertPolicy`
- `status`: planned, active, deprecated

- [x] Add a checker that:

- scans Swift, Python, backend-facing artifacts, docs, and tests for invariant
  IDs
- fails when an emitted or asserted invariant is not registered
- fails when a registered active invariant has no detector
- fails when a registered active invariant has no regression or explicit
  exception

- [ ] Add the checker to:

- [x] `just reliability-gate-regressions`
- [ ] CI when available

Definition of done:

- [x] every existing invariant ID is registered
- [x] `INVARIANTS.md` points to the registry instead of manually duplicating the
  active catalog
- [x] app-side diagnostics, merged diagnostics, and tests use IDs that pass the
  registry checker

### 2. Structured Diagnostics Spine

- [ ] Make typed diagnostics the canonical reporting surface.

Current useful seed:

- `StateMachineProjection`
- `SelectedSessionDiagnosticsSummary`
- `ContactDiagnosticsSummary`
- scenario diagnostics artifacts
- merged diagnostics JSON output

Plan:

- [x] Make the main projection types `Codable`.
- [x] Add a versioned diagnostics envelope:
   - schema version
   - app version
   - device ID
   - handle
   - scenario name and run ID when present
   - timestamp
   - typed state-machine projection
   - explicit invariant violations
   - reducer transition trace when available
- [x] Publish the structured envelope in scenario artifacts.
- [ ] Keep the text snapshot as a rendered view of the structured envelope.
- [x] Update `scripts/merged_diagnostics.py` to prefer structured fields and fall
   back to text only for older artifacts.

Definition of done:

- [x] merged diagnostics does not need to parse current state from text snapshots
  when a structured artifact is available
- [x] scenario artifacts include structured projection JSON
- [x] strict merged diagnostics can fail from structured invariant data

### 3. Scenario Invariant Assertions

- [x] Make invariants first-class in the simulator scenario DSL.

Add expectation fields such as:

- `noInvariantViolations: true`
- `expectInvariant: ["selected.ready_without_join"]`
- `eventuallyNoInvariant: ["selected.backend_ready_ui_not_live"]`
- `allowInvariantDuringStep: [...]` for transitional states that are expected
  and bounded

Rules:

- default scenario steps should eventually have no active invariant violations
  unless the scenario is explicitly testing a violation
- a scenario that reproduces a bug should assert the invariant ID before the fix
  and assert absence after the fix
- local-only transport-fault scenarios stay in the local websocket suite

Definition of done:

- [x] scenario failures can say which invariant was expected or unexpected
- [ ] new distributed bug regressions require projection assertions plus invariant
  assertions
- [x] strict merged diagnostics and scenario assertions agree on invariant outcome

### 4. ADT Hardening

- [ ] Replace remaining boolean and string seams with domain types.

High-priority targets:

- `PTTSessionState`
  - replace `systemChannelUUID`, `activeContactID`, `isJoined`, and
    `isTransmitting` combinations with a session ADT
- receiver audio readiness reasons
  - replace string reasons with `ReceiverAudioReadinessReason`
- transmit ownership
  - model foreground app press, foreground system callback, background wake
    handoff, and rejected/unowned system begin as a typed origin/ownership ADT
- selected peer aggregation
  - keep projection broad, but make more inputs typed before they enter
    `SelectedPeerSessionState`
- backend payload conversion
  - keep raw string `kind` values at decoding boundaries only
  - convert to Swift ADTs immediately after validation

Definition of done:

- [x] impossible PTT session combinations are not representable in the core state
- [x] reason strings do not decide behavior inside reducers
- [x] recent stuck-transmit and unowned system-begin rules are encoded as typed
  transition rules, not only callback guards
- [x] tests cover the new illegal-state boundaries

### 5. Unified Reducer Transition Reporting

- [ ] Every important coordinator should emit the same transition report shape.

Transition report fields:

- reducer name
- event name
- previous state summary
- next state summary
- effects emitted
- invariant violations emitted
- repair intents emitted
- correlation IDs, channel IDs, contact IDs, and attempt IDs when relevant

Candidate reducers/coordinators:

- selected peer session
- PTT session
- transmit reducer
- transmit execution
- transmit task coordinator
- wake execution
- receive execution
- backend sync
- control plane

Definition of done:

- [ ] a two-device failure can be read as a timeline of typed transitions, not a
  pile of unrelated logs
- [ ] merged diagnostics can group events by session, contact, channel, attempt, and
  scenario run
- [ ] reducer tests can assert transition reports for critical invariants

### 6. Backend Contract Parity

- [ ] Prove the app and backend agree on shared domain variants.

Plan:

- [ ] Keep Unison domain ADTs as the shared-truth model for backend-owned facts.
- [ ] Add a backend contract manifest or probe output describing emitted variant
   kinds and required fields.
- [ ] Add Swift tests that verify:
   - every backend variant decodes
   - required payload fields are enforced
   - unknown variants fail loudly or are handled by an intentional `unknown`
     compatibility path
- [ ] Add backend tests or probes that verify contract examples are produced from
   real domain projections.

Definition of done:

- [ ] changing a backend variant requires updating the app contract test
- [ ] changing a Swift decoder requires proving backend examples still decode
- [ ] readiness, membership, request relationship, wake readiness, and audio
  readiness remain aligned across app and backend

### 7. Reliability Gates And Reporting

- [ ] Make gates explicit confidence levels.

Recommended gate stack:

- [ ] `reliability-gate-regressions`
  - Python syntax checks
  - invariant registry check
  - focused Swift regressions
  - backend contract parity tests that do not require a running backend
- [ ] `reliability-gate-smoke`
  - regressions
  - hosted smoke scenarios
  - strict merged diagnostics
- [ ] `reliability-gate-full`
  - regressions
  - full hosted scenario catalog
  - strict merged diagnostics
- [ ] `reliability-gate-local`
  - regressions
  - full local websocket scenario catalog
  - strict local merged diagnostics
- [ ] nightly or long-running local gate
  - local scenario suite
  - simulator fuzz seeds
  - minimized failure replay
  - production diagnostic replay artifacts when available
- [x] `postdeploy-check`
  - hosted synthetic conversation canary
  - SLO dashboard
  - timestamped artifacts for agent inspection
- [x] `deploy-verified`
  - raw backend deploy
  - postdeploy hosted canary and SLO proof

Definition of done:

- [ ] each gate has a clear purpose and failure interpretation
- [ ] focused development can run the narrowest useful gate
- [ ] long-running gates produce artifacts that can be replayed locally
- [x] the normal production release path has one command that deploys and then
  verifies the live surface
- [x] the raw deploy primitive remains available for deliberate low-level use

### 8. Self-Healing Integration

- [ ] Connect invariants to bounded repair actions only when safe.

For each recoverable invariant:

- [ ] classify ownership:
   - backend stale
   - app stale
   - Apple-held session stale
   - ambiguous in-flight state
- [ ] define one idempotent repair action
- [ ] add suppression rules for valid in-flight states
- [ ] emit repair diagnostics:
   - repair requested
   - repair executed
   - repair suppressed
   - repair failed
   - repair converged
- [ ] prove both:
   - the invalid state repairs
   - nearby valid in-flight states are not repaired incorrectly

Definition of done:

- [ ] repair policies are listed in the invariant registry
- [ ] repair actions are observable in merged diagnostics
- [ ] every active repair has regression coverage

### 9. Production Replay And SLOs

- [ ] Turn production evidence into local proof artifacts.

Plan:

- [ ] add per-session correlation IDs across app, backend, push, and media
- [ ] store enough structured diagnostics to reconstruct a session timeline
- [ ] add scripts that convert production traces into:
  - scenario JSON when possible
  - reducer replay fixtures
  - route probe fixtures
  - invariant report fixtures
- [ ] define product-facing SLOs:
  - request-to-ready success rate
  - time to ready
  - first transmit success
  - stuck transmit rate
  - background wake success
  - reconnect recovery success
  - repair success and repair recurrence

Definition of done:

- [ ] a production failure can become a checked-in replay artifact
- [x] dashboards report product reliability, not only route-level uptime
- [ ] recurring production invariant IDs have owners and regressions

### 10. Workflow Simplification

- [ ] Keep one primary path for each reliability job and demote overlapping
  tools to diagnostic-only or retirement-candidate status.

Primary paths:

- [x] `just deploy-verified` for normal production releases.
- [x] `just postdeploy-check` for live hosted canary/SLO verification after an
  existing deploy.
- [x] `just diagnostics-merge-pair` or `scripts/merged_diagnostics.py --json`
  for physical-device/shake-to-report intake.
- [x] `just production-replay` when merged diagnostics JSON should become a
  scenario draft or replay artifact.
- [x] `just reliability-gate-regressions` for focused local confidence.
- [x] `just protocol-model-checks` for protocol/interleaving changes.

Diagnostic or building-block tools:

- [x] `just synthetic-conversation-probe` and `just slo-dashboard`, now wrapped
  by `postdeploy-check` for the common path.
- [x] `just route-probe` and `just route-probe-local`, retained as route-contract
  diagnostics and as the underlying synthetic canary engine.
- [x] `just backend-stability-probe`, retained for hosted route availability
  evidence and Unison Cloud escalation.

Removed overlapping probes:

- [x] old direct production probe recipe
- [x] old hosted smoke probe recipe

Retirement candidates:

- [ ] legacy APNs bridge helpers once the deployed wake path and diagnostics
  surface fully replace them

Definition of done:

- [x] tooling docs say which commands are primary, diagnostic-only, and
  retirement candidates
- [x] removed hosted-probe commands have no remaining primary docs pointing users
  at them
- [ ] remaining retirement candidates have no primary docs pointing users at
  them
- [x] older overlapping hosted probes are removed

## Recommended Execution Order

### Phase 1: Reporting Spine

Goal: make reliability work measurable and non-duplicative.

Do first:

- [x] Create the invariant registry.
- [x] Add the invariant registry checker.
- [x] Add the checker to `reliability-gate-regressions`.
- [x] Make diagnostics projection types `Codable`.
- [x] Publish structured scenario diagnostics artifacts.
- [x] Teach merged diagnostics to prefer structured artifacts.

Why first:

- later state-machine work needs one place to register and prove invariants
- diagnostics should become the integration surface before more rules are added
- this is low-risk compared with changing runtime behavior

### Phase 2: Scenario And Gate Integration

Goal: make the simulator proof loop assert the same rules diagnostics reports.

Do next:

- [x] Add invariant assertions to scenario expectations.
- [x] Update existing ready/request/reconnect scenarios to assert no unexpected
   invariant violations.
- [x] Add focused scenarios for recent PTT foreground/background regressions where
   simulator can model the control-plane part.
- [x] Make reliability gates run registry and scenario invariant checks.

### Phase 3: ADT Hardening

Goal: reduce the number of invalid states that can be represented.

Do next:

- [x] Refactor `PTTSessionState` into a stronger ADT.
- [x] Replace receiver audio readiness reason strings with an ADT.
- [x] Add a transmit ownership/origin ADT.
- [x] Move callback-only stuck-transmit protections into transition-level rules
   where possible.
- [x] Add reducer tests and invariant tests for each refactor.

### Phase 4: Cross-Coordinator Cohesion

Goal: make session, transmit, wake, receive, and backend projection behave like
one explainable system.

Do next:

- [x] Add unified transition reports to reducers.
- [x] Add a composed local session projection that derives cross-coordinator
   invariants.
- [x] Move cross-field checks out of text parsing and into typed projection checks.
- [x] Add merged diagnostics grouping by scenario run, session, channel, contact,
   and attempt.

### Phase 5: Backend Contract And Repair

Goal: make app/backend agreement and recoverability explicit.

Do next:

- [x] Add backend contract parity tests or manifest generation.
- [x] Move backend-owned invariant detection into backend seams where missing.
- [x] Connect recoverable invariants to self-healing repair policies.
- [x] Prove repairs with reducer tests, scenarios, and merged diagnostics.

### Phase 6: Production Replay And Formal Confidence

Goal: catch reliability problems before users do and replay those that escape.

Do later:

- [x] Add production replay conversion.
- [x] Add synthetic two-device conversation probes.
- [x] Add SLO dashboards.
- [x] Add property or model-checking harnesses for the core session protocol.

## Near-Term Backlog

These are the concrete first tickets that should come out of this plan:

- [x] Add `invariants/registry.json` with all currently known invariant IDs.
- [x] Add `scripts/check_invariant_registry.py`.
- [x] Wire registry checking into `just reliability-gate-regressions`.
- [x] Make `StateMachineProjection` and nested diagnostics summaries `Codable`.
- [x] Add structured projection JSON to simulator diagnostics artifacts.
- [x] Update merged diagnostics to read structured artifacts first.
- [x] Add `noInvariantViolations` to the simulator scenario DSL.
- [x] Refactor `ReceiverAudioReadinessIntent.reason` into an ADT.
- [x] Refactor `PTTSessionState` into a session ADT.
- [x] Add transmit ownership/origin modeling for system begin callbacks.

## Definition Of Reliable By Design

Turbo is moving toward reliable by design when these are true:

- shared truth has one authoritative owner
- user-visible state is derived from typed domain facts
- impossible states are unrepresentable in core models
- remaining invalid states emit stable invariant IDs automatically
- diagnostics are structured, replayable, and correlated across devices
- every distributed regression has a scenario or replay artifact
- every backend-owned contradiction is detected at a backend or contract seam
- every safe repair is bounded, idempotent, observable, and tested
- reliability gates prove the same rules that production reporting observes
- physical-device testing is reserved for Apple and hardware boundaries, not
  ordinary control-plane correctness

## Relationship To Other Documents

- [`RELIABILITY_GOALS.md`](/Users/mau/Development/Turbo/RELIABILITY_GOALS.md)
  defines the north-star guarantees and architecture target.
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md)
  defines the scenario-driven proof workflow.
- [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md)
  defines how invariant rules are named and emitted.
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md)
  defines repair ownership and proof requirements.
- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md)
  defines commands and gates.
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md)
  defines production reporting and operator query workflow.
