# TLA+ Specs

This directory contains small formal models for Turbo communication behavior.

For the repo-level workflow, see
[`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md).
Useful counterexamples and follow-up invariants are tracked in
[`FINDINGS.md`](/Users/mau/Development/Turbo/specs/tla/FINDINGS.md).
Coverage across the model, scenarios, fuzzing, and diagnostics is tracked in
[`COVERAGE.md`](/Users/mau/Development/Turbo/specs/tla/COVERAGE.md).

The goal is invariant discovery and protocol validation. These specs do not
replace Swift tests, backend regressions, simulator scenarios, or diagnostics.
They sit one level above those proof loops: if TLC finds a counterexample, turn
the abstract event trace into a checked-in simulator scenario and a repo-native
regression.

## Current Specs

`TurboCommunication.tla` models the direct-channel communication kernel:

- direct channel membership
- request, decline, accept, and local join success/failure
- joined/offline device presence
- receiver audio readiness
- token-backed wake addressability
- transmit epochs for stale-message rejection
- one active transmitter per channel
- unreliable control-message delivery
- stale client projections and explicit refresh

The default `TurboCommunication.cfg` bounds the model to two devices and one
direct channel. That is intentional: direct 1:1 communication is the current
product surface, and small traces are much easier to promote into
`scenarios/*.json`. It also bounds each device inbox with `MaxInboxLength` so
duplicate delivery remains a finite model instead of an infinite queue-growth
exercise.

`TurboSessionGeneration.tla` models a narrower restart/session-generation
kernel:

- app session generation increments on restart
- joined presence and active-channel facts carry generation evidence
- receiver-ready facts carry generation evidence
- active transmit requires a current-session joined sender
- backend snapshots are only accepted when their generation and membership
  evidence match the current app session

This is deliberately separate from `TurboCommunication.tla`. Session generation
is a high-risk protocol boundary, but mixing it into the full signal-delivery
model made the state space too broad for the default check.

## Repo Mapping

| TLA+ variable | Repo owner |
| --- | --- |
| `request` | backend invite/request relationship |
| `localJoinIntent` | Swift pending local PTT join action |
| `members` | `turbo.store.memberships` |
| `presence` | `turbo.store.presence` |
| `receiverReady` | `turbo.store.receiverAudioReadiness` |
| `wakeToken` | `turbo.store.tokens` |
| `activeTransmit` | `turbo.store.runtime` |
| `transmitEpoch` | `turbo.store.runtime` active-transmit attempt/lease generation |
| `inbox` | `turbo.service.ws`, APNs wake notices, route refresh gaps |
| `knownTransmit` | Swift selected-session/backend snapshot projection |
| `knownEpoch` | Swift selected-session/backend freshness projection |
| `clientPhase` | Swift selected peer/session phase projection |

`TurboSessionGeneration.tla` adds:

| TLA+ variable | Repo owner |
| --- | --- |
| `sessionGeneration` | app/backend session identity and reconnect ownership |
| `connected` | app websocket/session liveness abstraction |
| `presenceGeneration` | backend/app evidence that presence belongs to the current app session |
| `activeChannelGeneration` | backend/app evidence that active-channel projection belongs to the current app session |
| `receiverReadyGeneration` | backend/app evidence that readiness belongs to the current app session |

The spec intentionally abstracts over HTTP, Unison storage mechanics, SwiftUI,
audio frames, PushToTalk system UI, and APNs internals.

## Running TLC

Use the repo harness for the standard check:

```sh
just protocol-model-checks
```

That validates this config, runs TLC, and runs the Swift property tests that
cover the implementation-side projection and transport-fault rules.

Run the focused session-generation model with:

```sh
just protocol-session-generation-model-check
```

Install or download `tla2tools.jar` if you want to run TLC directly, then run
from this directory:

```sh
java -cp /path/to/tla2tools.jar tlc2.TLC \
  -deadlock \
  -config TurboCommunication.cfg \
  TurboCommunication.tla
```

If you use the VS Code TLA+ extension, open `TurboCommunication.tla` and run the
model with `TurboCommunication.cfg`.

## How To Use Counterexamples

When TLC finds a trace:

1. Decide whether the reached state is invalid, valid, or underspecified.
2. If invalid, name the broken truth as an invariant.
3. Add the invariant to the TLA+ spec.
4. Add the runtime-visible invariant to `invariants/registry.json` when it can
   be detected by app, backend, or merged diagnostics.
5. Convert the trace into a deterministic `scenarios/*.json` regression when it
   crosses app/backend behavior.
6. Add a lower-level Swift or Unison regression for the pure rule that should
   prevent the bad state.

A counterexample is not automatically a product bug. Sometimes it means the
system is missing a typed state or a documented ownership rule. That is still a
useful result: turn the ambiguity into an explicit invariant or ADT case.

## Invariants In The Initial Model

The first model checks:

- direct channels have at most two members
- wake tokens only exist for current channel members
- receiver readiness only exists for joined devices
- an active transmitter is a joined channel member
- every active transmit has an addressable peer
- a client can only project `receiving` with local transmit evidence
- a client can only project `transmitting` with local transmit evidence
- a disconnected client cannot project `receiving` or `transmitting`

The session-generation model checks:

- joined presence must belong to the current app session and current membership
- active channel must belong to the current app session and current membership
- receiver readiness must belong to a current joined session
- active transmit must be owned by a current joined sender

These are deliberately conservative first-pass rules. Stronger convergence
properties should be added after the safety model is stable.

## Design Notes

The model treats websocket/APNs/control delivery as unreliable through:

- `DeliverSignal`
- `DropSignal`
- `DuplicateSignal`
- `RefreshClient`

That lets us ask whether stale, missing, or duplicated control notices can move
the client into an illegal projection.

The first TLC run found exactly this kind of modeling gap: a device could leave
a direct channel while its local projection still said `receiving`. The model now
treats local leave as clearing that device's projection and ending any active
direct-channel transmit. If the implementation does not already enforce that
same rule, promote it into a runtime invariant and simulator regression.

The second expansion added transmit epochs and found two additional follow-ups:
offline wake targets must not directly project `receiving`, and backend lease
expiry is a bounded-convergence problem rather than an all-state safety rule.
These are recorded in `FINDINGS.md` and `invariants/registry.json` as planned
invariant work.

## Last Verified

`TurboCommunication.tla` verified on 2026-05-10 with TLC 2.19:

```text
63332923 states generated
3437005 distinct states found
0 states left on queue
No error has been found
```

The same result is captured by `scripts/protocol_model_check.py` in
`/tmp/turbo-protocol-model-checks-accept-join-transmit/protocol-model-checks.json`.

`TurboSessionGeneration.tla` verified on 2026-05-10 with TLC 2.19:

```text
9057 states generated
892 distinct states found
0 states left on queue
No error has been found
```
