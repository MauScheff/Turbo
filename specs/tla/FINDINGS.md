# TLA+ Findings

This file records useful TLC counterexamples and modeling discoveries that
should graduate into Turbo's normal reliability system.

Findings here are not a substitute for `invariants/registry.json`, Swift/Unison
regressions, simulator scenarios, or merged diagnostics. They are the bridge
from formal-model exploration to those proof surfaces.

## 2026-05-10

### TLA-2026-05-10-001: local exit must clear live projection

TLC reached a state where a device left a direct channel while its client
projection still said `receiving`.

Classification: invalid.

Planned invariant: `selected.live_projection_after_membership_exit`

Promotion status: active runtime invariant.

Current detectors:

- `Turbo/AppDiagnostics.swift`
- `scripts/merged_diagnostics.py`

Current regression:

- `TurboTests/TurboTests.swift`

Scenario status:

- Existing `noInvariantViolations` scenario assertions will catch this if it
  appears in checked-in scenario journeys.
- A focused membership-exit scenario should be added only with a concrete
  app/backend trace for the route that leaves transmit live after exit.

Expected system rule:

- local leave, disconnect, stale-membership repair, or membership removal must
  clear live `transmitting` projection for the affected device
- `receiving` without local joined/session evidence is covered separately by
  `selected.receiving_without_joined_session`
- any active direct-channel transmit owned by or targeting that membership must
  be ended or made unreachable
- the regression should cover the concrete app/backend path that can remove
  membership while receive/transmit UI is live

### TLA-2026-05-10-002: offline wake target must not directly project receiving

After modeling token-backed wake addressability, TLC found that an offline
token-backed receiver could move directly to `receiving` from a transmit-start
notice or backend refresh.

Classification: invalid.

Planned invariant: `selected.receiving_without_joined_session`

Promotion status: active runtime invariant.

Current detectors:

- `Turbo/AppDiagnostics.swift`
- `scripts/merged_diagnostics.py`

Current regression:

- `TurboTests/TurboTests.swift`

Scenario status:

- `scenarios/background_wake_refresh_stability.json` already asserts
  wake-capable background state remains non-violating.
- `scenarios/background_wake_transmit_does_not_project_receiver.json` asserts
  the local backend wake-target lane does not directly project the background
  receiver as `receiving` without joined/session evidence.

Expected system rule:

- wake-token addressability is enough to target APNs/wake
- it is not enough to project local `receiving`
- local `receiving` requires a joined/session/activation fact owned by the app
  or Apple boundary
- a wake-capable offline peer should move through wake/reconnect/activation
  states before receive projection becomes live

### TLA-2026-05-10-003: transmit notices need freshness

The initial unversioned model allowed old transmit-ended notices to race with a
newer transmit attempt. The model now uses `transmitEpoch` and message `epoch`
fields so a stale `TransmitEnded` cannot clear a newer active transmit
projection.

Classification: invalid if the implementation has no equivalent freshness
guard.

Promoted invariant: `transmit.stale_end_overrides_newer_epoch`

Status: active runtime invariant.

Detectors:

- `Turbo/TransmitCoordinator.swift`
- `Turbo/AppDiagnostics.swift`

Regression:

- `TurboTests/TurboTests.swift`
- `scenarios/stale_transmit_stop_completion_emits_invariant.json`

Scenario status:

- `scenarios/stale_transmit_stop_completion_emits_invariant.json` injects the
  stale-stop/newer-active reducer state and asserts diagnostics emit the
  expected invariant. This is an expected-violation scenario; verify it with the
  scenario runner and non-strict merged diagnostics, not strict merge.

Expected system rule:

- transmit start/end notices and route snapshots need monotonic attempt,
  generation, lease, or epoch evidence
- stale end/completion events must be ignored when a newer active transmit is
  already known
- the app-side signal reducer and backend active-transmit projection should
  agree on the freshness key

### TLA-2026-05-10-004: lease expiry needs bounded convergence

When active transmit expires at the backend, clients may temporarily retain a
live local projection until an end notice, renew failure, timeout, or refresh is
processed. This is not a pure all-state safety invariant; it is a convergence
rule.

Classification: underspecified.

Promoted invariant: `transmit.live_projection_after_lease_expiry`

Status: active convergence diagnostic.

Detectors:

- `Turbo/AppDiagnostics.swift`
- `scripts/merged_diagnostics.py`

Regression:

- `TurboTests/TurboTests.swift`
- `scenarios/lease_expiry_renewal_delay_recovers.json`

Scenario status:

- `scenarios/lease_expiry_renewal_delay_recovers.json` delays the sender's
  first `renew-transmit` past backend active-transmit lease expiry. The sender
  and receiver may temporarily hold live projections, but the delayed renewal
  failure plus explicit channel refresh must converge both peers back to
  `ready` without emitting `transmit.live_projection_after_lease_expiry`.
- Verify with strict merged diagnostics after the scenario run:
  `just simulator-scenario-merge-local-strict`.

Expected system rule:

- backend lease expiry must become visible to the sender and receiver through a
  bounded path
- a sender must not continue outbound audio indefinitely after backend lease
  loss
- stale `transmitting` / `receiving` after expiry should produce diagnostics if
  it outlives the allowed grace window
- the regression models dropped end-notice visibility through delayed renewal
  failure plus eventual refresh

### TLA-2026-05-10-005: declined request must clear requester connection projection

The full simulator scenario suite found a concrete app/backend trace in
`request_decline`: after the recipient declines an incoming request, backend
truth converges to idle for both peers, the requester has no pending action, no
local joined state, and no system session, but the requester projection remains
`waitingForPeer(reason: pendingJoin)` with status `Connecting...`.

Classification: invalid.

Planned invariant: `selected.backend_idle_without_local_evidence_still_connecting`

Promotion status: active runtime invariant and focused regression.

Detector:

- `Turbo/AppDiagnostics.swift`

Regression:

- `TurboTests/TurboTests.swift`
- `scenarios/request_decline.json`

Reproduction:

- `just simulator-scenario-local request_decline`
- `just simulator-scenario-merge-local`

Observed latest snapshots:

- requester: `selectedPeerPhase=waitingForPeer`,
  `selectedPeerPhaseDetail=waitingForPeer(reason: pendingJoin)`,
  `pendingAction=none`, `isJoined=false`, `systemSession=none`,
  `backendChannelStatus=idle`, `backendSelfJoined=false`,
  `backendPeerJoined=false`
- recipient: idle, no pending action, no joined/session evidence, backend idle

Expected system rule:

- a declined request must clear the requester-side requested/connecting
  projection once backend request relationship and membership are gone
- timeout recovery must update both the phase and the status, not only emit a
  timeout diagnostic
- repeated backend idle refreshes must be idempotent and converge the selected
  peer to idle when there is no pending local action or local session evidence

### TLA-2026-05-10-006: local join failure can remove the only wake-addressable transmit target

Expanding the model from request/accept into local join and transmit exposed a
counterexample where:

1. Bob requests a connection to Alice.
2. Alice accepts, creating direct-channel membership for both peers and pending
   local join intent on both devices.
3. Alice completes local join.
4. Bob uploads a wake token while still pending local join, making him the only
   addressable receiver.
5. Alice begins transmitting.
6. Bob's local join fails and his channel membership is removed.

The first version of the expanded model left `activeTransmit=alice` after Bob
lost membership and wake addressability. That violates
`ActiveTransmitHasAddressablePeer`: an active transmit must either have a joined
receiver or a token-backed wake receiver that is still a member of the channel.

Classification: invalid protocol state; existing implementation ownership is
backend-side.

Promoted rule:

- membership loss and failed local join must re-evaluate active transmit
  addressability
- if the removed member is the transmitter, or the removed member was the only
  addressable receiver, the backend must clear active transmit and emit the same
  freshness-preserving transmit-ended evidence used by other membership-loss
  paths

Promotion status: modeled and covered by existing backend invariant family.

Model change:

- `FailLocalJoin` now uses `ShouldClearTransmitAfterMembershipLoss`
- `LeaveChannel` uses the same membership-loss helper instead of only clearing
  unconditionally
- the expanded model now includes `RequestConnection`, `DeclineRequest`,
  `AcceptRequest`, `CompleteLocalJoin`, and `FailLocalJoin`

Related detectors / proof surfaces:

- `channel.active_transmit_without_addressable_peer`
- `channel.active_transmit_sender_presence_drift`
- backend wake-target diagnostics
- `ActiveTransmitHasAddressablePeer`
- `ActiveTransmitRequiresBothDirectMembers`

Latest TLC result:

- `63332923 states generated`
- `3437005 distinct states found`
- depth `23`
- no invariant violations

Scenario gap:

- no focused simulator scenario currently forces "receiver was wake-addressable
  via token, sender begins transmit, receiver local join then fails"
- keep this as a scenario candidate only if a concrete app/backend route exposes
  that exact implementation trace

### TLA-2026-05-10-007: current-generation presence snapshots still require membership ownership

The focused session-generation model initially allowed a backend snapshot to
apply `presence=joined` for a current app session even when the device was not a
member of the channel. TLC found the two-step trace from empty membership to
joined presence through `ApplyPresenceSnapshot`.

Classification: invalid protocol state.

Promoted rule:

- session/device generations prevent stale snapshots from crossing app restart
  boundaries, but generation freshness is not enough by itself
- joined presence, active channel, receiver readiness, and active transmit must
  also be backed by current backend membership
- offline presence snapshots must clear dependent receiver-ready, active-channel,
  and active-transmit projections for the affected device/channel

Promotion status: modeled by `TurboSessionGeneration.tla` and covered by the
existing stale-session/presence invariant family.

Related detectors / proof surfaces:

- `channel.stale_membership_on_session_connect`
- `channel.stale_peer_presence_projected_live`
- `channel.stale_self_presence_projected_live`
- `presence.offline_retained_connected_session`
- `presence.stale_active_channel_on_session_connect`

Latest TLC result:

- `9057 states generated`
- `892 distinct states found`
- no invariant violations

Scenario status:

- restart and stale-session recovery scenarios already cover concrete
  app/backend traces in this family
- add a focused membershipless-current-presence scenario only if a backend route
  can apply a current-session joined snapshot without membership

### TLA-2026-05-10-008: wake-token revocation must re-evaluate active transmit addressability

`TurboCommunication.tla` already modeled `ClearWakeToken` and the
`ShouldClearTransmitAfterTokenClear` rule: if an active transmit only has an
addressable receiver because of a wake token, losing that token must clear the
backend active transmit.

Classification: invalid protocol state if implementation keeps the active
transmit after the last wake-addressable receiver token is revoked.

Promoted rule:

- token revocation is backend-owned because `turbo.store.tokens` owns
  channel/user/device PTT tokens
- revoking a receiver token must delete token and APNs-environment rows
- if the revoked device is the active transmit target and it is not currently
  receiver-ready for the current session, backend active transmit must be
  cleared
- if the target is still current-session receiver-ready, token revocation does
  not by itself make the active transmit unaddressable

Promotion status: backend route and focused local simulator scenario.

Implementation proof surfaces:

- `turbo.store.tokens.delete`
- `turbo.store.runtime.clearIfTargetDevice`
- `turbo.service.channels.revokeEphemeralToken`
- `scenarios/wake_token_revocation_clears_active_transmit.json`

Related detector:

- `channel.active_transmit_without_addressable_peer`

Scenario status:

- focused local scenario covers the wake-token-only active transmit path
- fuzz now generates `backgroundApp -> beginTransmit -> revokeEphemeralToken`
  interleavings so token revocation composes with restart, websocket reconnect,
  refresh, and transport-delay perturbations

### TLA-2026-05-11-009: active transmitter membership loss must clear transmit

The model's `ShouldClearTransmitAfterDisconnect` rule requires backend active
transmit to clear when the active transmitter loses joined presence. Otherwise
the system can retain a live `self-transmitting` / `peer-transmitting`
projection after the transmitter has left the channel.

Classification: invalid protocol state.

Promoted rule:

- disconnecting or leaving while actively transmitting must remove active
  transmit for that channel
- both sender and receiver projections must converge out of live transmit after
  explicit refresh/reconciliation
- diagnostics must not emit `channel.active_transmit_sender_presence_drift` or
  `selected.live_projection_after_membership_exit` after the recovery window

Proof surfaces:

- `ShouldClearTransmitAfterDisconnect`
- `ActiveTransmitterIsJoinedMember`
- `scenarios/active_transmit_sender_disconnect_clears_transmit.json`

Scenario status:

- focused local scenario added as the regression proof for the sender
  membership-loss route
- fuzz now generates `beginTransmit -> sender disconnect` interleavings so
  active-transmit membership loss composes with restart, websocket reconnect,
  refresh, and transport-delay perturbations
