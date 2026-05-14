# State-Machine Testing

Status: active workflow guide.
Canonical home for: report-to-regression workflow, scenario-worthiness decisions, and proof boundary guidance for distributed app/backend behavior.
Related docs: [`scenarios/README.md`](/Users/mau/Development/Turbo/scenarios/README.md) owns scenario catalog, DSL, commands, generated inputs, probes, and diagnostics details; [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md) owns the global ownership/invariant/proof model.

Do not start with manual device tap-through debugging when the behavior can be expressed as a state-machine scenario.

## Scenario Loop

Default distributed behavior loop:

1. Restate the bug as a violated invariant or broken projection.
2. Encode the smallest useful story as a checked-in deterministic scenario.
3. Reproduce it against the local or hosted control plane.
4. Inspect merged diagnostics and typed state projections.
5. Fix the owning reducer, coordinator, backend route, or backend projection seam.
6. Keep the scenario as a regression when it adds evidence beyond lower-level proof.

Most app/backend correctness should be provable without a physical device. Physical devices are still required for Apple boundary conformance:

- real PushToTalk UI behavior
- microphone permission
- backgrounding / lock screen wake delivery
- audio session activation and actual audio playback / capture

## When To Add A Scenario

Add a checked-in scenario when the bug depends on a distributed app/backend journey:

- multiple actors
- explicit action order
- backend routes or websocket notices
- simulator PushToTalk callbacks
- deterministic waits, delays, duplicates, drops, reordering, or forced refreshes
- selected-session, contact-list, backend-readiness, or diagnostics expectations

Do not add a slow scenario when a lower-level reducer, domain, backend, or TLA+ proof captures the whole invariant better.

Each new reproducible distributed bug should usually leave behind:

- one end-to-end scenario when the journey matters
- at least one lower-level reducer, projection, backend, or property test for the broken rule underneath it
- a named invariant or regression that explains the class of failure

The scenario file format, active catalog, commands, typed fault actions, invariant expectation fields, generated inputs, fuzz lane, production replay conversion, synthetic probes, local backend loop, and scenario diagnostics rules live in [`scenarios/README.md`](/Users/mau/Development/Turbo/scenarios/README.md).

## Report Shape

When a report arrives, write it as:

- observer
- subject
- initial conditions
- event sequence
- expected invariant
- observed violation

Example:

`@avery` should see `@blake` as online after both devices heartbeat and refresh summaries, but the contact summary remains offline.

When the report came from physical devices, do not copy the taps literally unless the taps matter. Convert the report into the smallest event story that expresses the invariant failure in the shared machines.

Useful prompt shape:

```text
I reproduced a production/device issue. The handles were @a and @b.
I used shake-to-report on both devices. Please run reliability intake,
classify the owner, convert this into an invariant or regression where
possible, fix it, and prove the fix.
```

## Assertion Targets

Prefer asserting typed projections, not labels alone.

Typical assertion surfaces:

- selected peer phase, status, and join state
- contact list state per handle
- backend channel readiness as seen by the app
- backend audio readiness and wake readiness
- emitted effects or forbidden effects
- convergence after retries, reordering, or duplicate signals

The same machine-readable projection should feed both scenario assertions and diagnostics snapshots. That keeps the debug loop and the proof loop aligned.

Backend contract details for request relationship, membership, summary status, conversation status, readiness, audio readiness, and wake readiness live in [`APP_STATE.md`](/Users/mau/Development/Turbo/APP_STATE.md). Scenarios and probes should assert those nested backend ADTs directly when readiness or projection semantics are the bug.

## Apple Boundary

If the bug reproduces in simulator or local backend, fix it in the shared state-machine path.

If it only reproduces on a physical device after simulator scenarios and route probes are green, classify it as an adapter-conformance issue and debug the Apple/device boundary directly.

For foreground audio smoke verification, the current known-good boundary contract is:

- both devices converge to `ready`
- local hold-to-talk remains disabled while that device is still `Preparing audio...`
- local hold-to-talk remains disabled until backend `audioReadiness.peer.kind == ready`
- `wakeReady` appears only when backend `wakeReadiness.peer.kind == wake-capable`
- first press plays the Apple start beep and reaches `transmitting` quickly
- the receiver reaches `receiving` and hears audio on that first press
- release returns both sides to `ready`

For background and lock-screen wake work, split proof this way:

- backend/probe proof establishes wake-capable targeting and incoming push delivery
- Swift tests establish local wake-activation state machine and fallback rules
- physical-device testing proves final Apple boundary behavior: incoming push, `PTT audio session activated`, and lock-screen playback

Expected wake-failure classification:

- no wake target
- no push sent
- no incoming push received
- incoming push received but no system activation
- system activation succeeded but playback still failed

## Adjacent Proof Lanes

Use these docs for specialized mechanics:

- [`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md): generated interleavings, artifact layout, replay, shrinking, and promotion from fuzz failure to checked-in regression.
- [`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md): protocol-level invariant discovery for stale projections, dropped/duplicated/reordered signals, reconnects, lease expiry, wake targeting, and ownership of shared truth.
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md): telemetry, shake reports, reliability intake, and production evidence.
- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md): exact commands for scenarios, probes, gates, production replay, and hosted verification.

## Diagnostics Authority

Scenario runs and normal app debug runs both use the diagnostics backend, but they do not play the same role.

- normal debug builds may auto-publish diagnostics after high-signal state transitions
- simulator scenarios publish explicit scenario-tagged diagnostics artifacts at the end of the run
- simulator scenario view models disable automatic diagnostics publishing so the explicit scenario artifact remains authoritative for exact-device verification

When diagnosing a scenario failure, trust the scenario artifact and merged scenario diagnostics first. Treat ad hoc debug uploads as supporting material, not as the proof source.
