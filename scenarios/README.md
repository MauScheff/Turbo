# Simulator Scenario Suite

The simulator scenario runner owns distributed control-plane journeys that span:

- app reducer and coordinator logic
- backend invite and channel state
- simulator PushToTalk shim behavior
- diagnostics publication and merged timeline inspection

Use it for end-to-end stories, not for every invariant.

## Layering

- `scenarios/*.json`
  - canonical user journeys and regression stories
- reducer and domain tests in `TurboTests.swift`
  - invariants, idempotence, convergence, and duplicate-effect suppression
- physical-device smoke checks
  - only for Apple PushToTalk UI, microphone permission, backgrounding, lock screen, and real audio

## Active scenarios

- `request_accept_ready`
  - baseline happy path: request, accept, ready, transmit, stop, disconnect
- `request_accept_ready_disconnect_initiator`
  - ready session torn down by the initiator without a transmit step
- `request_accept_ready_disconnect_receiver`
  - ready session torn down by the receiver without a transmit step
- `request_cancel_before_accept`
  - caller withdraws before the peer accepts
- `request_decline`
  - recipient declines an incoming request
- `simultaneous_request_conflict`
  - both peers press connect in the same step and the control plane converges to a single ready session

For scenarios that lead into transmit, the `ready` step should mean `phase=ready` and `canTransmitNow=true`. That keeps the suite aligned with the actual user journey instead of allowing a transient "Connected" label to pass before hold-to-talk is really available.

## Pending regression scenarios

- `request_accept_ready_peer_transmit.disabled`
  - ready session where the recipient becomes the transmitter
  - currently reproduces a real bug: once the recipient begins transmitting, the initiator refreshes channel state, gets `channel not found`, and tears down the local session
  - keep this file as the next scenario to re-enable after fixing receiver-side transmit

## Operating rule

When smoke testing finds a new distributed regression, prefer adding a checked-in scenario here if the behavior is reproducible in simulator. Add lower-level property or reducer tests underneath it for the invariant that should prevent recurrence.

## Local backend loop

When production-backed scenario runs are noisy because the hosted backend is returning intermittent `internal server error`, use the local control-plane path:

- start the backend with `just serve-local-http`
- run `just simulator-scenario-local <scenario>`
- inspect `just simulator-scenario-merge-local`

`serve-local-http` points the simulator at `http://localhost:8081/s/turbo/`, which is the stable local HTTP-only service exposed by `turbo.serveHttpLocal`.

For full ready/transmit flows, prefer the websocket-capable local service:

- start it with `just serve-local`
- run `just simulator-scenario-local <scenario> base=http://localhost:8080/s/turbo`
- inspect `just simulator-scenario-merge-local base=http://localhost:8080/s/turbo`

To run the canonical checked-in suite:

- hosted: `just simulator-scenario-suite`
- local websocket backend: `just simulator-scenario-suite-local`
