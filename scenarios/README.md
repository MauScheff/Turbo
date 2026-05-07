# Simulator Scenario Suite

The simulator scenario runner owns distributed control-plane journeys that span:

- app reducer and coordinator logic
- backend invite and channel state
- simulator PushToTalk shim behavior
- diagnostics publication and merged timeline inspection

Use it for end-to-end stories, not for every invariant.

The `just simulator-scenario*` commands run through `scripts/run_simulator_scenarios.py`, which owns the temporary runtime config, serializes access to the simulator scenario lane, and retries transient XCTest bootstrap failures.

For the repo-wide workflow and architectural intent behind these scenarios, read [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md).

## Layering

- `scenarios/*.json`
  - canonical user journeys and regression stories
- reducer and domain tests in `TurboTests.swift`
  - invariants, idempotence, convergence, and duplicate-effect suppression
- physical-device smoke checks
  - only for Apple PushToTalk UI, microphone permission, backgrounding, lock screen, and real audio

## Active scenarios

- `presence_online_projection`
  - baseline projection story: both peers establish a direct channel, heartbeat, refresh summaries, and each side observes the other as online
- `presence_open_peer_projection`
  - fresh-contact projection regression: opening a peer before any direct channel exists must still surface backend presence correctly, so the selected peer shows online instead of offline
- `foreground-ptt`
  - canonical foreground control-plane path: both peers open, converge to `ready`, then each side transmits once and returns to `ready`
- `background_wake_refresh_stability`
  - one ready peer backgrounds and publishes `receiver-not-ready(app-background-media-closed)`; the foreground peer must degrade to `wakeReady`, and explicit refresh/reconcile must preserve that wake-capable state instead of regressing to `waitingForPeer`
- `peer_disconnect_before_second_join`
  - recipient accepts and joins first, then disconnects before the requester finishes the second join; both sides must converge back to idle without a stuck half-session
- `request_accept_ready`
  - baseline happy path: request, accept, ready, transmit, stop, disconnect
- `request_accept_ready_disconnect_initiator`
  - ready session torn down by the initiator without a transmit step
- `request_accept_ready_disconnect_receiver`
  - ready session torn down by the receiver without a transmit step
- `request_accept_ready_refresh_stability`
  - both peers reach `ready`, then explicit summary/invite/channel refresh plus reconciliation must preserve the ready session instead of tearing it down
- `request_accept_ready_receiver_ready_gate`
  - delays the first `receiver-ready` delivery on both sides during the final join so the handshake must remain in `waitingForPeer` until backend/audio readiness really converges instead of drifting to `ready`, `wakeReady`, or optimistic hold-to-talk too early
- `request_accept_ready_peer_transmit`
  - ready session where the recipient becomes the transmitter, then returns to `ready` and disconnects cleanly; this used to be a disabled regression and is now part of the default suite
- `duplicate_connect_request_deduplicates`
  - duplicate connect intents from the requester must still converge to a single outstanding request before the peers continue to `ready`
- `disconnect_refresh_convergence`
  - after a ready session disconnects, explicit summary/invite/channel refresh plus reconciliation must converge both sides back to idle instead of reviving stale joined state
- `delayed_accept_refresh_race`
  - the requester performs stale refresh/reconcile work while the recipient acceptance is delayed; the flow must still converge through `peerReady` into `ready` without tearing down the session
- `dropped_transmit_start_poll_recovery`
  - local-only transport-fault regression: the receiver drops the next `transmit-start` websocket signal and must still converge to `receiving` after explicit refreshes repair the state from backend truth
- `duplicate_transmit_stop_delivery_recovers`
  - local-only transport-fault regression: the receiver processes a duplicated `transmit-stop` websocket signal and must still converge back to `ready` without tearing down the live session incorrectly
- `reordered_transmit_signals_refresh_recovery`
  - local-only transport-fault regression: the receiver reorders the next `transmit-start` and `transmit-stop` websocket notices; explicit refresh and reconciliation must still restore both peers to `ready`
- `backend_reconnect_ready_session_recovery`
  - one participant reconnects the full backend control plane while already `ready`; both sides must refresh, reconcile, and recover the same ready session without drifting off the backend `readiness` or `audioReadiness` contract
- `restart_ready_session_recovery`
  - one participant restarts after a ready session is established, reopens the peer, refreshes control-plane state, and must restore the ready local session deterministically with backend `audioReadiness` back at `ready`
- `restart_ready_session_recovery_with_offline_repair`
  - local-only fuzz regression promoted from seed 124: the recipient restarts from a ready session, the pair transmits with delayed receiver signaling, then a background/foreground disconnect must converge without `presence.offline_retained_connected_session`
- `disconnect_clears_stale_peer_presence_during_state_refresh`
  - local-only fuzz regression promoted from seed 123: a receiver disconnect races with repeated channel-state refreshes; backend stale-presence repair must clear raw active-channel pointers and strict merged diagnostics must stay clean
- `restart_partial_join_recovery`
  - the requester restarts during the partial-join window where backend channel membership is already present but the requester's local PTT session is not joined; refresh and reconciliation must restore the requester to `peerReady`, preserve the recipient in `waitingForPeer`, and still allow the second join to converge to `ready`
- `websocket_ready_session_recovery`
  - one participant loses only the websocket transport while already `ready`; the disconnected side must preserve its joined local PTT session but may block transmit readiness while the backend marks its active device/readiness stale, the remote side degrades to `wakeReady` because `peerDeviceConnected` dropped and backend peer `audioReadiness` falls back, and an explicit websocket reconnect plus refresh must restore full readiness convergence

Use `websocket_ready_session_recovery` and `backend_reconnect_ready_session_recovery` to prove two different invariants:

- websocket transport loss does not tear down the local session, but it can still block local transmit readiness and degrade the remote side's derived readiness through `peerDeviceConnected`
- full backend/control-plane reconnect must still reassert and recover the ready session deterministically
- `request_cancel_before_accept`
  - caller withdraws before the peer accepts
- `request_decline`
  - recipient declines an incoming request
- `simultaneous_request_conflict`
  - both peers press connect in the same step and the control plane converges to a single ready session

For scenarios that lead into transmit, the `ready` step should mean `phase=ready` and `canTransmitNow=true`. That keeps the suite aligned with the actual user journey instead of allowing a transient "Connected" label to pass before hold-to-talk is really available.

For physical-device foreground smoke tests, also keep this distinction clear:

- scenario `ready` proves shared readiness and local gating semantics
- real device smoke must still prove actual first-press audio, which depends on the Apple audio boundary and the sender/receiver media route setup

In other words, simulator scenarios prove "hold-to-talk is enabled at the right time," while device smoke still proves "the first real transmit produced audible audio."

## Operating rule

When smoke testing finds a new distributed regression, prefer adding a checked-in scenario here if the behavior is reproducible in simulator. Add lower-level property or reducer tests underneath it for the invariant that should prevent recurrence.

Scenarios should increasingly assert typed machine projections instead of only selected-peer phase:

- selected-session state
- contact-list state
- backend-derived readiness
- backend-derived audio readiness
- effect-safe convergence after retries or delays

## Running a scenario

- `just simulator-scenario <scenario>`
  - runs `TurboTests/SimulatorScenarioTests`
  - the runtime filter in `.scenario-runtime-config.json` selects which checked-in JSON scenario to execute
- `just simulator-scenario-suite`
  - runs the same `TurboTests/SimulatorScenarioTests` entrypoint with no filter
  - every checked-in `scenarios/*.json` file runs automatically in sorted order
- `just simulator-scenario-merge`
  - merges the latest exact-device diagnostics for `sim-scenario-avery` and `sim-scenario-blake`
- `just simulator-scenario-merge-strict`
  - runs the same merge read, but exits non-zero if invariant violations are present

The scenario DSL supports both user-intent actions and control-plane forcing actions such as refreshes, waits, presence heartbeats, direct-channel establishment, websocket disconnect/reconnect, backend reconnect, and `restartApp`. Each action can also opt into deterministic fault scheduling with:

- `delayMilliseconds`
  - deliver the action later within the current step; use this to model races and explicit reordering across actors
- `repeatCount`
  - deliver the same action more than once
- `repeatIntervalMilliseconds`
  - spacing between duplicate deliveries
- `drop`
  - omit an action entirely without removing it from the checked-in scenario description

Use those when needed to model distributed bugs deterministically instead of relying on manual timing.

The DSL now also supports transport-fault actions at the backend adapter boundary:

- `resetTransportFaults`
  - clears all configured HTTP and websocket transport faults for that actor
- `setHTTPDelay`
  - delays the next `count` requests for a typed route such as `contact-summaries`, `incoming-invites`, `outgoing-invites`, `channel-state`, or `channel-readiness`
- `setWebSocketSignalDelay`
  - delays the next `count` inbound websocket deliveries for a typed `signalKind`
- `dropNextWebSocketSignals`
  - drops the next `count` inbound websocket deliveries for a typed `signalKind`
- `duplicateNextWebSocketSignals`
  - duplicates the next `count` inbound websocket deliveries for a typed `signalKind`
- `reorderNextWebSocketSignals`
  - buffers the next `count` inbound websocket deliveries for an optional `signalKind`, then flushes them in reverse order to model cross-delivery reordering

These actions are intentionally typed and limited. If a route or signal kind is not part of the checked-in contract, the scenario runner fails instead of accepting arbitrary strings.

Compact reference:

- `setHTTPDelay`
  - requires `route`, `milliseconds`, optional `count`
- `setWebSocketSignalDelay`
  - requires `signalKind`, `milliseconds`, optional `count`
- `dropNextWebSocketSignals`
  - requires `signalKind`, optional `count`
- `duplicateNextWebSocketSignals`
  - requires `signalKind`, optional `count`
- `reorderNextWebSocketSignals`
  - requires `count >= 2`, optional `signalKind`
- `resetTransportFaults`
  - no extra fields; clears all configured HTTP and websocket delivery faults for that actor

Current typed HTTP routes:

- `contact-summaries`
- `incoming-invites`
- `outgoing-invites`
- `channel-state`
- `channel-readiness`

Current typed websocket signal kinds:

- use the backend signal kind names already exercised by the app and tests, for example `transmit-start` and `transmit-stop`
- if a signal kind is not recognized by the checked-in runner, the scenario fails fast instead of silently accepting a typo or unsupported transport hook

In simulator scenarios, `disconnectWebSocket` now means "suspend websocket reconnection until an explicit `reconnectWebSocket` step". That keeps transport-fault scenarios deterministic instead of letting background polling immediately reconnect the socket.

When you add or rename a checked-in scenario JSON file, update this README and verify the loop with:

- `just simulator-scenario <scenario>`
- `just simulator-scenario-merge`

## Generated Scenario Inputs

The XCTest runner still defaults to checked-in `scenarios/*.json`, but the
runtime config also accepts generated inputs:

- `scenarioFile`
  - runs one JSON file outside the repo
- `scenarioDirectory`
  - runs every `*.json` file in a temporary directory

The Python wrapper exposes these as `--scenario-file` and
`--scenario-directory` on `scripts/run_simulator_scenarios.py`. This is used by
the fuzz lane so failing seeds can be replayed from `/tmp/turbo-scenario-fuzz`
without copying artifacts into the repo.

## Fuzz Lane

Use the local websocket backend for high-volume fuzzing:

1. Start the backend with `just serve-local`.
2. Run `just simulator-fuzz-local 123 3` for a smoke pass.
3. Run `just simulator-fuzz-local-overnight 12345 500` for a longer pass.
4. On failure, use the printed replay and shrink commands.

Each seed directory stores:

- `scenario.json`
- `metadata.json`
- `xcode-output.txt`
- `merged-diagnostics.txt`
- `merged-diagnostics.json`
- `merged-diagnostics-strict.txt`
- `result.json`
- `minimized.json` when shrinking preserves the failure

Promotion is explicit: inspect the minimized scenario and diagnostics, fix the
authoritative subsystem, then copy a stable regression into `scenarios/` with a
clear name and README entry.

For the full generator, artifact, replay, shrink, and promotion workflow, read
[`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md).

## Local backend loop

When production-backed scenario runs are noisy because the hosted backend is returning intermittent `internal server error`, use the local control-plane path:

- start the backend with `just serve-local-http`
- run `just simulator-scenario-local <scenario>`
- inspect `just simulator-scenario-merge-local`

`serve-local-http` points the simulator at `http://localhost:8081/s/turbo/`, which is the stable local HTTP-only service exposed by `turbo.serveHttpLocal`.

For full ready/transmit flows and control-plane convergence scenarios, prefer the websocket-capable local service:

- start it with `just serve-local`
- run `just simulator-scenario-local <scenario>`
- inspect `just simulator-scenario-merge-local`
- run `just route-probe-local` when you also changed backend route composition or websocket semantics; the local probe now also checks the nested `requestRelationship` and `membership` contract fields exposed by the backend routes
  - it also verifies `summaryStatus`, `conversationStatus`, `readiness`, `audioReadiness`, and `wakeReadiness` through a real request -> receiver-ready -> token upload -> ready -> transmit -> ready control-plane flow
  - the app now consumes `/readiness` directly when deriving selected-peer state, so readiness regressions should be asserted against that route rather than inferred only from `/channel-state`

`just simulator-scenario-suite-local` assumes `just serve-local` is already running on `http://localhost:8090/s/turbo`. If the backend is not up, the suite fails with connection-refused errors instead of scenario assertions.

To run the canonical checked-in suite:

- hosted: `just simulator-scenario-suite`
- hosted smoke subset: `just simulator-scenario-suite-hosted-smoke`
- local websocket backend: `just simulator-scenario-suite-local`

Scenarios with `"requiresLocalBackend": true` are only runnable through the local websocket backend lane. They are skipped from hosted suite runs unless explicitly targeted with a local base URL.

The hosted smoke subset is intentionally narrower than the local suite. Keep transport-fault and websocket-connectivity recovery scenarios in the local deterministic lane unless the deployed surface proves the same invariant reliably.

## Scenario Diagnostics

Scenario runs publish explicit diagnostics artifacts after the scenario completes. Those artifacts are what `just simulator-scenario-merge`, `just simulator-scenario-merge-strict`, and exact-device verification are meant to read back.

Normal debug builds may also auto-publish diagnostics during development, but simulator scenario view models disable that automatic publishing so the scenario-tagged artifact remains the authoritative write for the scenario lane.

The merged diagnostics analyzer now reads explicit `INVARIANT VIOLATIONS` transcript sections, derives additional pair-level rules, and supports `--json` plus `--fail-on-violations` for agent and automation workflows.
