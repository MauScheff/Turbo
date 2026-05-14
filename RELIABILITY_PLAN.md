# Reliability Sprint Plan

Status: active sprint plan.

Canonical home for the current reliability push: the concrete work we intend to execute next to move Turbo toward reliable-by-design behavior.

This is not the reliability philosophy, not the everyday checklist, and not the command catalog:

- [`RELIABILITY_GUIDELINES.md`](/Users/mau/Development/Turbo/RELIABILITY_GUIDELINES.md): core reliability idea, math framing, tool ladder, iteration rule
- [`RELIABILITY_CHECKLIST.md`](/Users/mau/Development/Turbo/RELIABILITY_CHECKLIST.md): repeatable review checklists
- [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md): canonical agent loop
- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md): exact commands and gates

When this sprint is complete, either delete this file or replace it with the next sprint plan. Do not let it become a stale roadmap.

## Sprint Goal

Make call-critical app/backend behavior harder to get wrong and easier to prove:

> stale facts must not project current truth, important claims must have an owner and invariant, and distributed regressions must have a fast lower-level proof beneath any scenario.

## Non-Goals

- Do not rewrite the whole state model.
- Do not add broad scenario coverage without a lower-level invariant or reducer/backend proof underneath it.
- Do not treat Apple/PTT/audio physical-device checks as substitutes for proving shared app/backend logic.
- Do not turn this file into a permanent backlog.

## Exit Criteria

This sprint is done when:

- call-critical backend facts are classified as durable/monotonic or leased/epoched runtime truth
- at least the highest-risk backend projection path has typed current-state predicates instead of raw-row truth
- every serious bug touched during the sprint has a registered invariant or explicit reason it does not need one
- at least one distributed scenario has a lower-level Swift, Unison, TLA+, or fuzz/property proof for the core invariant underneath it
- reliability intake, strict merged diagnostics, and the relevant gate still pass
- the final handoff says whether this plan should be deleted or rolled into the next sprint

## Track 1: Backend Stale-Truth Audit

Purpose: stale rows may exist, but stale rows must never be sufficient to project current truth.

Work:

- [ ] List call-critical backend facts: presence, readiness, signaling authorization, wake target, active transmit, relay/session facts.
- [ ] For each fact, classify it as `durable/monotonic` or `leased/epoched runtime`.
- [ ] Identify which route/store/projection currently reads raw rows where it should call a typed current-state predicate.
- [ ] Pick the highest-risk projection path first, likely readiness/wake/transmit target selection.
- [ ] Add or strengthen the typed predicate that answers "is this fact current for this user/device/channel/session/epoch?"
- [ ] Replace direct raw-row projection in that path with the typed predicate.
- [ ] Add a backend invariant or route/projection proof that stale rows are insufficient to authorize or project current truth.

Proof:

- [ ] Unison/backend test, route probe, or focused MCP/UCM proof for the changed predicate.
- [ ] Strict diagnostics or scenario proof only if the change affects app/backend journey behavior.

## Track 2: Invariant-First Bug Conversion

Purpose: serious reliability bugs should become named, owned rules.

Work:

- [ ] Review recent handoffs and current active bugs for reliability failures that are still only described as symptoms.
- [ ] For each candidate, restate the symptom as a broken fact.
- [ ] Identify the owner: backend, client reducer, pair/convergence, or Apple boundary.
- [ ] Add or update an entry in [`invariants/registry.json`](/Users/mau/Development/Turbo/invariants/registry.json).
- [ ] Put the detector at the authoritative seam, not where the symptom is merely visible.
- [ ] Add expected/observed machine-readable evidence to diagnostics where needed.
- [ ] Add the narrowest useful regression.

Proof:

- [ ] `python3 scripts/check_invariant_registry.py`
- [ ] one focused Swift, Unison, merged-diagnostics, TLA+, fuzz, or scenario proof per new invariant

## Track 3: Lower-Level Proof Beneath Scenarios

Purpose: scenarios are valuable but expensive; the pure invariant underneath should usually have a fast proof.

Work:

- [ ] Pick one or two high-value simulator scenarios that currently carry too much proof burden.
- [ ] Identify the invariant each scenario is really proving.
- [ ] Add a focused Swift reducer/property test, Unison backend test/probe, TLA+ check, or fuzz oracle for that invariant.
- [ ] Keep the scenario only for the cross-boundary journey evidence it uniquely provides.
- [ ] Document in the invariant registry or handoff why the lower-level proof is sufficient.

Proof:

- [ ] focused lower-level proof passes
- [ ] existing scenario still passes
- [ ] strict merged diagnostics agrees with scenario invariant outcome

## Track 4: Typed Reducer And Projection Hardening

Purpose: UI should render derived state, not own truth.

Work:

- [ ] Identify one remaining boolean, nullable, or stringly seam that affects selected-session, transmit, wake, receive, or backend projection behavior.
- [ ] Replace behavior-driving strings/flags with a typed state, typed reason, or typed transition input.
- [ ] Keep raw strings only at decode or compatibility boundaries.
- [ ] Add preconditions and postconditions around the transition that owns the behavior.
- [ ] Emit diagnostics in terms of the typed state/reason.

Proof:

- [ ] focused Swift reducer/property test for the illegal-state boundary
- [ ] scenario only if the typed change affects a distributed journey

## Track 5: Self-Healing As Formal Repair

Purpose: repair invalid state without hiding bugs.

Work:

- [ ] Pick one recoverable invariant that already exists or emerges from Tracks 1-4.
- [ ] Classify ownership: backend stale, app stale, Apple-held session stale, or ambiguous in-flight state.
- [ ] Define one bounded idempotent repair action.
- [ ] Define suppression rules for nearby valid in-flight states.
- [ ] Emit repair diagnostics: requested, executed, suppressed, failed, converged.
- [ ] Connect the repair policy back to the invariant registry.

Proof:

- [ ] invalid state repairs
- [ ] nearby valid in-flight state does not repair incorrectly
- [ ] merged diagnostics makes the repair decision reconstructable

## Track 6: Production Replay And SLO Feedback

Purpose: field failures should become local proof artifacts.

Work:

- [ ] Run reliability intake on the next suitable field/TestFlight/debug-device issue.
- [ ] Confirm the diagnostics JSON contains enough correlation IDs to reconstruct the session.
- [ ] Convert the evidence into one artifact: scenario JSON, reducer replay fixture, route probe fixture, invariant report fixture, or fuzz/model seed.
- [ ] Check whether the issue maps to an existing SLO or needs a new product-facing reliability metric.
- [ ] Add the artifact or document why the boundary is Apple/PTT/audio-only and cannot be replayed locally.

Proof:

- [ ] replay/probe/scenario/model artifact runs locally, or physical-device-only boundary is explicitly documented
- [ ] relevant SLO/probe output is attached to the handoff

## Suggested Order

1. Start with Track 1 because stale backend truth can invalidate every higher-level proof.
2. Run Track 2 in parallel with any bug work encountered during the sprint.
3. Use Track 3 to reduce scenario burden once the first backend predicate or invariant is in place.
4. Use Track 4 for the highest-risk app-side seam discovered by Tracks 1-3.
5. Only do Track 5 after a recoverable invariant is clearly owned.
6. Use Track 6 when real field evidence arrives; do not manufacture production replay work without a useful report.

## Sprint Gate

Before closing the sprint, run the narrow proofs for changed areas plus the smallest broad gate that matches the blast radius:

- backend-only route/store/projection work: backend proof plus `just reliability-gate-regressions`
- Swift reducer/projection work: focused Swift test plus `just reliability-gate-regressions`
- distributed app/backend behavior: focused proof, scenario, strict merged diagnostics, then `just reliability-gate-smoke`
- release-bound backend behavior: `just deploy-staging-verified` or `just deploy-production` as appropriate

## Closeout

At closeout:

- [ ] Update the latest handoff with completed tracks, proofs, and remaining risk.
- [ ] Delete this sprint plan if the work is complete.
- [ ] If work remains, replace this file with the next concrete sprint plan rather than appending an old roadmap.
