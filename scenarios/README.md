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
  - one participant reconnects the full backend control plane while already `ready`; both sides must refresh, reconcile, and recover the same ready session without drifting off the backend `readiness` contract
- `restart_ready_session_recovery`
  - one participant restarts after a ready session is established, reopens the peer, refreshes control-plane state, and must restore the ready local session deterministically
- `restart_partial_join_recovery`
  - the requester restarts during the partial-join window; refresh and reconciliation must restore the requester to `peerReady`, preserve the recipient in `waitingForPeer`, and still allow the second join to converge to `ready`
- `websocket_ready_session_recovery`
  - one participant loses only the websocket transport while already `ready`; the disconnected side must remain locally usable, while the remote side degrades to `wakeReady` because `peerDeviceConnected` dropped, and an explicit websocket reconnect plus refresh must restore full readiness convergence

Use `websocket_ready_session_recovery` and `backend_reconnect_ready_session_recovery` to prove two different invariants:

- websocket transport loss does not tear down the local session, but it can still degrade the remote side's derived readiness through `peerDeviceConnected`
- full backend/control-plane reconnect must still reassert and recover the ready session deterministically
- `request_cancel_before_accept`
  - caller withdraws before the peer accepts
- `request_decline`
  - recipient declines an incoming request
- `simultaneous_request_conflict`
  - both peers press connect in the same step and the control plane converges to a single ready session

For scenarios that lead into transmit, the `ready` step should mean `phase=ready` and `canTransmitNow=true`. That keeps the suite aligned with the actual user journey instead of allowing a transient "Connected" label to pass before hold-to-talk is really available.

## Operating rule

When smoke testing finds a new distributed regression, prefer adding a checked-in scenario here if the behavior is reproducible in simulator. Add lower-level property or reducer tests underneath it for the invariant that should prevent recurrence.

Scenarios should increasingly assert typed machine projections instead of only selected-peer phase:

- selected-session state
- contact-list state
- backend-derived readiness
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
  - it also verifies `summaryStatus`, `conversationStatus`, and `readiness` through a real request -> ready -> transmit -> ready control-plane flow
  - the app now consumes `/readiness` directly when deriving selected-peer state, so readiness regressions should be asserted against that route rather than inferred only from `/channel-state`

`just simulator-scenario-suite-local` assumes `just serve-local` is already running on `http://localhost:8090/s/turbo`. If the backend is not up, the suite fails with connection-refused errors instead of scenario assertions.

To run the canonical checked-in suite:

- hosted: `just simulator-scenario-suite`
- hosted smoke subset: `just simulator-scenario-suite-hosted-smoke`
- local websocket backend: `just simulator-scenario-suite-local`

Scenarios with `"requiresLocalBackend": true` are only runnable through the local websocket backend lane. They are skipped from hosted suite runs unless explicitly targeted with a local base URL.

The hosted smoke subset is intentionally narrower than the local suite. Keep transport-fault and websocket-connectivity recovery scenarios in the local deterministic lane unless the deployed surface proves the same invariant reliably.

## Scenario Diagnostics

Scenario runs publish explicit diagnostics artifacts after the scenario completes. Those artifacts are what `just simulator-scenario-merge` and exact-device verification are meant to read back.

Normal debug builds may also auto-publish diagnostics during development, but simulator scenario view models disable that automatic publishing so the scenario-tagged artifact remains the authoritative write for the scenario lane.
