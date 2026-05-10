# State-Machine Testing

This repo's default iteration model for distributed product behavior is:

1. describe the bug as a violated invariant
2. encode it as a checked-in deterministic scenario
3. reproduce it against the local or hosted control plane
4. inspect merged diagnostics and state projections
5. fix the reducer / coordinator / backend projection seam
6. keep the scenario as a regression

Do not start with manual device tap-through debugging when the behavior can be expressed as a state-machine scenario.

## Core model

Turbo should be reasoned about as explicit state machines plus adapters:

- domain and coordinator state machines decide product behavior
- the UI is a thin projection layer over those machines
- buttons emit intents; they do not own business logic
- backend routes, websocket notices, timers, and PTT callbacks are normalized into typed events
- side effects are explicit commands emitted by machines and run by adapters

The result is that most app/backend correctness should be provable without a physical device.

## Modeling rules

Prefer explicit ADTs over boolean bundles when a thing can be in one of a small number of meaningful modes.

Good:

- `PairRelationshipState.none`
- `PairRelationshipState.outgoingRequest(requestCount:)`
- `PairRelationshipState.incomingRequest(requestCount:)`
- `PairRelationshipState.mutualRequest(requestCount:)`

Bad:

- `hasIncomingRequest: Bool`
- `hasOutgoingRequest: Bool`
- ad hoc precedence rules spread across the UI and coordinators

The important property is that weird distributed cases like simultaneous requests stay representable instead of being flattened away by whichever boolean is checked first.

## Proof hierarchy

Use this order:

1. reducer / domain tests for invariants
2. deterministic simulator scenarios for distributed journeys
3. merged diagnostics for state drift analysis
4. route probes for backend semantics
5. physical devices only for Apple boundary conformance

Physical devices are still required for:

- real PushToTalk UI behavior
- microphone permission
- backgrounding / lock screen wake delivery
- audio session activation and actual audio playback / capture

They are not the source of truth for core control-plane correctness.

For foreground audio smoke verification, treat this as the current known-good boundary contract:

- both devices converge to `ready`
- local hold-to-talk remains disabled while that device is still `Preparing audio...`
- local hold-to-talk also remains disabled until backend `audioReadiness.peer.kind == ready`
- `wakeReady` should only appear when backend `wakeReadiness.peer.kind == wake-capable`
- first press plays the Apple start beep and reaches `transmitting` quickly
- the receiver reaches `receiving` and hears audio on that first press
- release returns both sides to `ready`

When that breaks, use merged exact-device diagnostics to localize whether the failure is:

- control-plane state
- sender capture / route binding
- receiver playback / activation

For background and lock-screen wake work, the current proof split is:

- backend/probe proof should establish wake-capable targeting and incoming push delivery
- Swift tests should establish the local wake-activation state machine and fallback rules
- physical-device testing is still required for the final Apple boundary:
  - incoming push
  - `PTT audio session activated`
  - lock-screen playback

That means a wake failure is now expected to be classified more precisely:

- no wake target
- no push sent
- no incoming push received
- incoming push received but no system activation
- system activation succeeded but playback still failed

The shared state-machine and scenario loop should still be used to prove any control-plane part of the fix, but the final proof for actual audio remains a physical-device boundary check.

## Scenario design

Scenarios in [`scenarios/`](/Users/mau/Development/Turbo/scenarios) should model distributed event flows, not just UI taps.

Good scenario ingredients:

- multiple actors
- explicit action order
- optional waits, delayed deliveries, duplicates, drops, or forced refreshes
- transport-fault hooks on typed HTTP routes and websocket signal kinds when the bug is really about delivery semantics
- expectations on selected-session state
- expectations on contact-list projections
- expectations on backend-derived readiness
- diagnostics artifacts that survive failure

Each new reproducible distributed bug should produce:

- one end-to-end scenario
- at least one lower-level reducer / projection test for the broken invariant
- inclusion in the default suite via `just simulator-scenario-suite` if the file is checked in as `scenarios/*.json`

## Seeded fuzzing

Turbo also has a deterministic simulator fuzz lane for finding distributed
state-machine regressions before there is a human-written scenario.

The dedicated reference is
[`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md).
It covers generator shape, local commands, artifact layout, replay, shrinking,
oracles, and promotion from fuzz failure to checked-in regression.

## TLA+ formal modeling

Turbo also has a TLA+ lane for protocol-level invariant discovery before a bug
has a concrete implementation repro. Use it when the question is about
distributed interleavings, stale projections, dropped/duplicated/reordered
signals, reconnects, lease expiry, wake targeting, or ownership of shared truth.

The dedicated reference is
[`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md). The current model is
under [`specs/tla/`](/Users/mau/Development/Turbo/specs/tla). A TLC
counterexample should be classified as valid, invalid, or underspecified;
invalid states should become named invariants, lower-level Swift/Unison
regressions, and deterministic simulator scenarios or fuzz oracles where
appropriate.

Run `just protocol-model-checks` for the executable harness. It validates the
TLA+ config, runs TLC against the bounded communication model, then runs the
Swift property tests that prove the corresponding implementation-side pure
rules. `reliability-gate-regressions` runs the static model validation so broken
spec/config wiring is caught even on machines without TLC installed.

### Fuzz Failure To Regression

When fuzzing finds a failure:

1. Replay it with `just simulator-fuzz-replay <artifact-dir>`.
2. Shrink it with `just simulator-fuzz-shrink <artifact-dir>`.
3. Inspect `minimized.json` if present, otherwise `scenario.json`.
4. Read `merged-diagnostics.txt` and `merged-diagnostics.json` for invariant
   IDs, typed projections, backend readiness, and pair convergence evidence.
5. Identify the authoritative owner of the broken fact.
6. Add or strengthen the invariant if the oracle did not name the broken truth.
7. Fix the source subsystem, not just the visible projection.
8. Promote the minimized scenario into `scenarios/` only after it is stable and
   useful as a regression.
9. Add a lower-level Swift or Unison property regression for the pure rule that
   should prevent the scenario from failing again.

### Production Failure To Replay

When a field or physical-device failure has merged diagnostics JSON:

1. Convert it with
   `just production-replay /path/to/merged-diagnostics.json /tmp/turbo-production-replay`.
2. Read `production-replay.json` for the redacted source timeline, invariant
   IDs, inferred actions, and suggested final expectations.
3. Run `/tmp/turbo-production-replay/reproduce.sh`.
4. Treat `scenario-draft.json` as best-effort until strict merged diagnostics
   reproduces the same invariant.
5. Minimize noisy or nonessential steps before promoting the replay into
   `scenarios/`.

### Production Report To Regression

The intended production loop is:

1. The human describes the observed failure in product terms.
2. The agent collects or asks for the relevant shake-to-report handles/device
   identities, then runs merged diagnostics.
3. The agent classifies ownership of the broken fact:
   - backend/shared truth
   - client projection or reducer state
   - Apple/PTT/audio adapter boundary
   - ambiguous in-flight state that needs a stronger invariant
4. The agent turns the failure into the narrowest permanent proof:
   - reducer/property test for a pure app rule
   - simulator scenario for a distributed app/backend journey
   - Unison/backend test or route probe fixture for backend-owned truth
   - TLA+ update when the bug is about interleavings, ordering, or protocol
     semantics
   - physical-device checklist only for the Apple or hardware boundary
5. The agent fixes the owning subsystem, then runs the narrow proof and the
   appropriate reliability gate.
6. Before or after release, the agent runs `just postdeploy-check` or
   `just deploy-verified` so the live hosted surface has a fresh SLO artifact.

This is how a production observation becomes part of Turbo's semantics. The
goal is not to preserve every tap literally; it is to encode the invariant that
was violated so the same class of bug fails automatically next time.

### Synthetic Conversation Probes

Use `just synthetic-conversation-probe` for route-level confidence before or
between app scenario runs. It executes the semantic route probe with synthetic
caller/callee identities, checks that the two-device conversation loop still
covers websocket registration, receiver readiness, begin transmit, push target
selection, and end transmit, and writes iteration artifacts that can be attached
to a reliability report.

Use `just slo-dashboard <synthetic-conversation-probe.json>` after synthetic
probes when you need the same evidence expressed as product SLOs. The dashboard
keeps the route-level checks visible, but the pass/fail surface is phrased as
conversation success, full-probe latency, critical transition latency, and
optionally invariant health from merged diagnostics.

## What You Can Tell The Agent

In simple terms: yes, this machinery is intended to let an agent take a report from physical-device testing and turn it into a deterministic multi-device + backend regression.

The useful bug report shape is:

- who observed it
- who the peer was
- what each side did
- what order things happened in
- what should have happened
- what actually happened

A good instruction to give the agent is:

> I reproduced a production/device issue. The handles were `@a` and `@b`.
> I used shake-to-report on both devices. Please run reliability intake,
> classify the owner, convert this into an invariant or regression where
> possible, fix it, and prove the fix.

The default intake command is:

```bash
just reliability-intake-shake @a <incidentId> @b
```

If there is no shake incident, use:

```bash
just reliability-intake @a @b
```

Example:

- `@avery` opens `@blake`
- `@blake` accepts on the other device
- `@avery` backgrounds and foregrounds
- `@blake` starts transmitting
- `@avery` never enters `receiving`; it stays `ready`

If the bug lives in the shared control-plane or state-machine path, the expected workflow is:

1. encode that story as a checked-in scenario
2. run it against the local websocket backend or the hosted smoke lane
3. inspect typed projections and merged diagnostics
4. reproduce the failure deterministically
5. fix the broken reducer / coordinator / backend projection seam
6. rerun the scenario, lower-level tests, probes, and suite
7. keep the scenario as the regression

This is not magic. It works when the behavior is representable as:

- app intents
- backend routes / summaries / readiness
- websocket deliveries
- simulator PushToTalk callbacks
- deterministic timing or transport faults

It is less direct when the bug depends on:

- real microphone permission UI
- Apple PushToTalk system UI behavior
- lock screen / wake timing
- true device audio capture / playback quirks

For those, the agent can still often narrow the problem and prove the shared logic, but the final boundary verification may still need devices.

## Assertion targets

Prefer asserting typed projections, not labels alone.

Typical assertion surfaces:

- selected peer phase / status / join state
- contact list state per handle
- backend channel readiness as seen by the app
- emitted effects or forbidden effects
- convergence after retries, reordering, or duplicate signals

The same machine-readable projection should feed both:

- scenario assertions
- diagnostics snapshots

That keeps the debug loop and the proof loop aligned.

## Backend contract rule

The app/backend boundary should also be ADT-shaped.

When the backend is representing a mutually exclusive distributed fact such as request relationship or channel membership, it should expose a canonical nested variant on the wire instead of forcing the client to reconstruct meaning from unrelated booleans.

Current examples:

- `requestRelationship`
  - `kind: none | incoming | outgoing | mutual`
  - `requestCount`
- `membership`
  - `kind: absent | self-only | peer-only | both`
  - `peerDeviceConnected`
- `summaryStatus`
  - `kind: offline | online | requested | incoming | connecting | ready | talking | receiving`
  - `activeTransmitterUserId`
- `conversationStatus`
  - `kind: idle | requested | incoming-request | connecting | waiting-for-peer | ready | self-transmitting | peer-transmitting`
  - `activeTransmitterUserId`
- `readiness`
  - `kind: waiting-for-self | waiting-for-peer | ready | self-transmitting | peer-transmitting`
  - `activeTransmitterUserId`
- `audioReadiness`
- `wakeReadiness`
  - `self.kind: unknown | waiting | ready`
  - `peer.kind: unknown | waiting | ready`
  - `peerTargetDeviceId`

The canonical nested contract is now required by the client. Flat compatibility fields may still be present on the wire for diagnostics or redundancy, but Swift no longer derives behavior from them when the nested ADTs are missing or malformed. That is a contract failure.

For readiness-sensitive bugs, scenarios and probes should assert the backend `readiness`, `audioReadiness`, and `wakeReadiness` contracts directly. Do not rely only on older `channel-state` booleans, token presence, or ephemeral websocket delivery when the backend already exposes the stronger readiness ADTs the app consumes in production.

Transport-fault scenarios should stay typed too. If the harness is delaying or dropping something, that should be a known route or a known signal kind, not an arbitrary string bag.

## Incident workflow

When a report arrives, write it as:

- observer
- subject
- initial conditions
- event sequence
- expected invariant
- observed violation

Example:

`@avery` should see `@blake` as online after both devices heartbeat and refresh summaries, but the contact summary remains offline.

That should become a checked-in scenario before patching the code.

When the report came from physical devices, do not copy the taps literally unless the taps matter. Convert the report into the smallest event/story that expresses the invariant failure in the shared machines.

## Adapter boundary rule

If the bug reproduces in simulator or local backend, fix it in the shared state-machine path.

If it only reproduces on a physical device after the simulator and route probes are green, classify it as an adapter-conformance issue and debug the Apple / device boundary directly.

Local-only transport-fault scenarios are valid checked-in regressions. They belong in the local websocket suite, while the hosted lane should stay a small smoke subset that proves deployed contract alignment without depending on local-only fault injection.

## Diagnostics Rule

Scenario runs and normal app debug runs both use the diagnostics backend, but they do not play the same role.

- normal debug builds may auto-publish diagnostics after high-signal state transitions
- simulator scenarios publish explicit scenario-tagged diagnostics artifacts at the end of the run
- simulator scenario view models disable automatic diagnostics publishing so the explicit scenario artifact remains authoritative for exact-device verification

When diagnosing a scenario failure, trust the scenario artifact and merged scenario diagnostics first. Treat ad hoc debug uploads as supporting material, not as the proof source.
