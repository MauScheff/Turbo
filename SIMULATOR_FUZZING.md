# Simulator Fuzzing

Turbo's simulator fuzz lane generates deterministic, model-based scenario JSON
from integer seeds, runs those scenarios through the existing simulator scenario
XCTest harness, and leaves replayable artifacts under `/tmp` when a seed fails.

Use this lane for distributed control-plane and state-machine bugs that can be
expressed with app intents, backend refreshes, websocket delivery faults, HTTP
delays, restart/reconnect events, and simulator PushToTalk shim behavior. It is
not the final proof for real Apple PushToTalk UI, microphone permission,
lock-screen wake, or actual device audio capture/playback.

## Entry Points

Start the local backend separately:

```sh
just serve-local
```

Run a short smoke batch:

```sh
just simulator-fuzz-local 123 3
```

Run a longer local batch that stops on the first failure:

```sh
just simulator-fuzz-local-overnight 12345 500
```

Replay a saved seed artifact:

```sh
just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

Shrink a saved failing seed:

```sh
just simulator-fuzz-shrink /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

The default base URL is `http://localhost:8090/s/turbo`. The local fuzz lane
assumes `just serve-local` is already running.

## Components

- `scripts/run_simulator_fuzz.py`
  - owns seed expansion, scenario generation, artifact writing, replay, and
    shrinking
- `scripts/run_simulator_scenarios.py`
  - owns the simulator scenario runtime config, simulator lane lock, and
    transient XCTest retry loop
- `TurboTests/SimulatorScenarioTests`
  - loads checked-in scenarios by default, or generated scenarios via
    `scenarioFile` / `scenarioDirectory`
- `scripts/merged_diagnostics.py`
  - merges exact-device diagnostics for the generated actor/device pair and
    can fail the fuzz run on strict invariant violations
- `TurboTests` property helpers
  - provide the in-repo deterministic Swift property harness used by focused
    pure tests such as `conversationProjectionProperties` and
    `transportFaultPlannerProperties`

There is no SwiftCheck dependency. Swift property tests use `PropertyRunConfig`,
`SeededRNG`, and failure messages that include seed, iteration, generated input
summary, expected invariant, and observed state.

## Generated Scenario Flow

Each seed creates one two-actor scenario. By default the actors are:

- `a`: `@avery`, device id `sim-fuzz-<seed>-avery`
- `b`: `@blake`, device id `sim-fuzz-<seed>-blake`

The generator is model-based, not random tapping. It builds a mostly valid
journey through:

1. both peers open each other
2. requester sends a connection request
3. recipient accepts and joins
4. requester completes the join
5. optional websocket reconnect or app restart perturbation
6. one peer transmits
7. that peer ends transmit
8. optional background / foreground perturbation
9. one peer disconnects

The generator injects controlled noise around that journey:

- refreshes for contact summaries, invites, and channel state
- delayed and repeated action delivery
- HTTP delays on typed routes
- websocket signal delay, drop, duplicate, and reorder faults
- redundant commands and stale refreshes
- app restart, websocket reconnect, background, and foreground events where the
  simulator scenario DSL supports them

The generated scenario uses the same JSON DSL as checked-in scenarios. It is run
through `scenarioFile`, so it does not need to be copied into `scenarios/`.

## Oracle

A fuzz seed fails if either of these fails:

- the simulator scenario XCTest run exits non-zero
- strict merged diagnostics exits non-zero because invariant violations were
  published by the app/backend diagnostics path

That means failures can come from either direct scenario expectations or from
diagnostics-backed invariants. Both are useful. The preferred long-term shape is
for important distributed contradictions to have typed invariant IDs in merged
diagnostics, not only a timeout or label mismatch.

Fuzz diagnostics are collected with local telemetry disabled, so local TLS or
Cloudflare telemetry availability does not decide the result.

## Artifact Layout

Each run creates:

```text
/tmp/turbo-scenario-fuzz/<run-id>/
  run-metadata.json
  seed-<seed>/
    scenario.json
    metadata.json
    result.json
    reproduce.sh
    xcode-output.txt
    merged-diagnostics.txt
    merged-diagnostics.json
    merged-diagnostics-strict.txt
    minimized.json                 # present after a successful shrink
    minimized-xcode-output.txt      # present after a successful shrink
    shrink-result.json              # present after shrink
    shrink-candidates/
      candidate-0001/
        scenario.json
        metadata.json
        result.json
        xcode-output.txt
        merged-diagnostics.txt
        merged-diagnostics.json
        merged-diagnostics-strict.txt
```

Important files:

- `scenario.json`
  - the generated scenario for that seed
- `metadata.json`
  - seed, scenario name, base URL, actor handles, device IDs, and replay command
- `result.json`
  - scenario exit code, strict diagnostics exit code, and overall failed flag
- `xcode-output.txt`
  - full simulator scenario test output
- `merged-diagnostics.txt`
  - readable merged exact-device diagnostics
- `merged-diagnostics.json`
  - machine-readable merged diagnostics
- `merged-diagnostics-strict.txt`
  - strict invariant pass/fail output
- `minimized.json`
  - the preferred repro after shrink succeeds
- `reproduce.sh`
  - exact simulator scenario command for the artifact

Artifacts are intentionally outside the repo. The fuzz lane never promotes a
failing scenario into `scenarios/` automatically.

## Replay

Replay always uses the preferred scenario in an artifact directory:

1. `minimized.json`, if it exists
2. otherwise `scenario.json`

Use replay to confirm a failure is stable before investigating or promoting it:

```sh
just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-<seed>
```

Replay rewrites the output and diagnostics files in that artifact directory.
Copy anything you need to preserve before repeated replay runs.

## Shrinking

The shrinker tries candidate scenarios while preserving the same failure oracle:
a candidate must fail the simulator scenario run or strict diagnostics.

Shrink passes are deliberately conservative:

- remove whole steps only when the step has no `expectEventually` assertion and
  contains no core journey action
- remove individual actions only when they are not core journey actions
- simplify fault parameters:
  - action delays to `0`
  - repeat counts to `1`
  - repeat intervals to `0`
  - HTTP/websocket delay milliseconds to `0`
  - fault counts to `1`, except reorder faults keep `count = 2`

Core journey actions are preserved during removal:

- `openPeer`
- `connect`
- `beginTransmit`
- `endTransmit`
- `backgroundApp`
- `foregroundApp`
- `disconnect`
- `restartApp`

Shrink candidates that fail because the scenario program became invalid are
rejected. Examples include removing the selected peer before
`refreshChannelState`, removing required actor setup, or producing an unknown
scenario action.

The shrinker is a v1 reducer, not a full delta-debugging engine. It is useful
when it removes obvious noise and leaves a shorter valid repro. It is acceptable
to stop a long shrink once it has produced a useful `minimized.json`.

## Scenario File And Directory Inputs

Checked-in scenario behavior is unchanged: `SimulatorScenarioTests` still runs
`scenarios/*.json` by default.

Generated scenarios use runtime config fields instead:

- `scenarioFile`
  - run one JSON scenario outside the repo
- `scenarioDirectory`
  - run every `*.json` file in a generated directory

The Python wrapper exposes these as:

```sh
python3 scripts/run_simulator_scenarios.py \
  --scenario-file /tmp/example/scenario.json \
  --scenario fuzz_seed_123 \
  --base-url http://localhost:8090/s/turbo
```

Use this path for generated or temporary scenarios. Promote only stable,
human-readable regressions into `scenarios/`.

## Failure To Regression

When fuzzing finds a failure:

1. Replay the artifact.
2. Shrink it.
3. Inspect `minimized.json` if present, otherwise `scenario.json`.
4. Read `xcode-output.txt` for the scenario step and assertion failure.
5. Read `merged-diagnostics.txt` and `merged-diagnostics.json` for invariant
   IDs, selected-peer projection, backend readiness, audio readiness, wake
   readiness, and pair convergence evidence.
6. Identify the authoritative owner of the broken fact.
7. Add or strengthen the invariant if the oracle did not name the broken truth.
8. Fix the source subsystem, not just the visible projection.
9. Promote the minimized scenario into `scenarios/` only after it is stable and
   useful as a regression.
10. Add a lower-level Swift or Unison property regression for the pure rule that
    should prevent recurrence.

Promotion should leave a checked-in scenario with a descriptive name and an
entry in `scenarios/README.md`. Keep seed artifacts as debug evidence, not as
source-controlled test cases.

## Focused Property Tests

The simulator fuzz lane is expensive because it runs XCTest, the simulator, the
local backend, and merged diagnostics. Keep pure invariants covered underneath
it.

Useful Swift property targets:

```sh
just swift-test-target conversationProjectionProperties
just swift-test-target transportFaultPlannerProperties
```

`conversationProjectionProperties` checks ADT-heavy pure derivations around:

- `ConversationStateMachine.selectedPeerState`
- `ConversationStateMachine.projection`
- `ConversationStateMachine.reconciliationAction`
- projection/detail phase alignment
- selected-contact gating for reconciliation effects
- duplicate reconciled teardown suppression

`transportFaultPlannerProperties` checks scenario transport-planning helpers:

- dropped actions are not scheduled
- repeated actions produce the expected scheduled count
- scheduled actions are monotonic by delivery time
- HTTP delay faults are consumed exactly `count` times
- websocket drop faults are consumed exactly `count` times

Backend/domain invariants should be covered with Unison pure tests when the
truth belongs to backend ADTs or app/backend contracts. Keep effectful store
fuzzing out of this lane unless there is a specific reason; the local simulator
fuzz lane already exercises backend route/store behavior through the real local
service.

## Smoke Checklist

Use this after changing the fuzz machinery:

1. Run the Swift property smoke:

   ```sh
   just swift-test-target conversationProjectionProperties
   just swift-test-target transportFaultPlannerProperties
   ```

2. Run one generated scenario file through the generated input path:

   ```sh
   just serve-local
   python3 scripts/run_simulator_fuzz.py run --seed 123 --count 1
   just simulator-fuzz-replay /tmp/turbo-scenario-fuzz/<run-id>/seed-123
   ```

3. Run one generated scenario directory through `scenarioDirectory` if that path
   changed.

4. Verify checked-in scenarios still use the default path:

   ```sh
   just simulator-scenario-suite-local
   ```

5. For a failure-path proof, replay and shrink a known failing artifact, then
   verify `minimized.json`, `shrink-result.json`, and diagnostics artifacts were
   produced.

Stop the local backend when the smoke is finished.

## Limitations

- Generated scenarios are intentionally two-peer scenarios today.
- Shrinking is conservative and may leave redundant but valid actions.
- The simulator can prove control-plane readiness and projection behavior, but
  not real audio or Apple UI boundary behavior.
- A fuzz failure is not automatically a regression test. It becomes one only
  after an agent or human minimizes, names, reviews, fixes, and promotes it.
