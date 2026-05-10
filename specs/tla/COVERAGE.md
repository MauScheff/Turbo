# TLA+ Communication Coverage

This file maps Turbo's formal communication model to the repo-native proof
surfaces that keep the implementation honest. It is intentionally a coverage
map, not a second invariant registry.

Use this when deciding what to model next, what scenario should exist for a TLC
counterexample, and whether a reliability failure already has a detector,
scenario, fuzz lane, and owner.

## Proof Lanes

| Lane | Command | Purpose |
| --- | --- | --- |
| TLA+ model plus pure Swift properties | `just protocol-model-checks` | Validate the bounded communication kernel and implementation-side pure rules. |
| Static model wiring | `just reliability-gate-regressions` | Validate TLA+ spec/config wiring on machines without TLC. |
| Local deterministic scenario catalog | `just simulator-scenario-suite-local` | Exercise app/backend communication journeys against local Unison Cloud. |
| Strict local merged diagnostics | `just simulator-scenario-merge-local-strict` | Fail if merged scenario diagnostics contain invariant violations. |
| Local fuzz smoke | `just simulator-fuzz-local 123 3` | Generate deterministic scenario variants for replay/shrink/promotion. |
| Local fuzz overnight | `just simulator-fuzz-local-overnight 12345 500` | Broader stochastic search for distributed interleavings. |

## Current Model Scope

`TurboCommunication.tla` models the direct-channel control kernel:

- direct-channel membership
- joined/offline presence
- receiver audio readiness
- token-backed wake addressability
- one active transmitter per channel
- transmit freshness through `transmitEpoch`
- unreliable control delivery through drop, duplicate, and refresh actions
- client live projections derived from local evidence

It does not model SwiftUI, audio frames, APNs internals, Unison storage
mechanics, HTTP transport details, or Apple PushToTalk callbacks. When a TLA+
trace crosses those boundaries, promote it into a simulator scenario, Swift
property regression, backend invariant, or device-only smoke check as
appropriate.

## Coverage Matrix

| Failure family | TLA+ surface | Invariant / detector | Scenario coverage | Fuzz / search coverage | Owner | Status / gap |
| --- | --- | --- | --- | --- | --- | --- |
| Dropped transmit-start notice | `DropSignal`, `RefreshClient`, `DeliverSignal` | selected/backend projection diagnostics | `dropped_transmit_start_poll_recovery` | `scripts/run_simulator_fuzz.py` can generate transmit drops and refreshes | mixed | Covered by model, scenario, and fuzz lane. |
| Duplicated transmit-stop notice | `DuplicateSignal`, `DeliverSignal` | transmit reducer idempotence and selected-session diagnostics | `duplicate_transmit_stop_delivery_recovers` | fuzz transport noise includes duplicate websocket signals | app | Covered by scenario and fuzz lane; TLA covers duplicate queue behavior abstractly. |
| Reordered transmit start/stop notices | inbox plus `DropSignal`/`DuplicateSignal`/`DeliverSignal`; ordering is represented by delivery interleavings | `transmit.stale_end_overrides_newer_epoch` for stale-end freshness | `reordered_transmit_signals_refresh_recovery`, `stale_transmit_stop_completion_emits_invariant` | fuzz transport noise includes reordered websocket signals | app | Covered. Expected-violation stale-stop scenario uses non-strict merge. |
| Stale transmit epoch / attempt evidence | `transmitEpoch`, `knownEpoch`, `LiveProjectionHasCurrentEpochEvidence` | `transmit.stale_end_overrides_newer_epoch` | `stale_transmit_stop_completion_emits_invariant` | fuzz can produce signal reorderings but reducer injection is the focused proof | app | Covered; keep epoch/freshness mapping aligned with backend transmit IDs. |
| Backend lease expiry convergence | `ExpireTransmit`, `RefreshClient`; convergence is outside pure safety invariants | `transmit.live_projection_after_lease_expiry` in app and merged diagnostics | `lease_expiry_renewal_delay_recovers` | fuzz has `renew-transmit` transport delays | mixed | Covered as a convergence diagnostic; strict merged diagnostics must remain clean after recovery scenario. |
| Offline wake targeting must not project receiving | `wakeToken`, `CanReceiveTransmit`, `DisconnectedClientIsNotLive` | `selected.receiving_without_joined_session` | `background_wake_refresh_stability`, `background_wake_transmit_does_not_project_receiver` | fuzz includes background/foreground and transmit steps | app / Apple boundary | Covered for local backend wake-target path; physical-device smoke still owns Apple wake activation. |
| Local membership exit while live | `LeaveChannel`, `DisconnectedClientIsNotLive`, `ReceivingHasLocalTransmitEvidence` | `selected.live_projection_after_membership_exit`, `selected.receiving_without_joined_session` | Covered broadly by `noInvariantViolations`; no focused scenario yet | fuzz includes disconnect and refresh races | mixed | Open focused scenario gap. Add only when a concrete app/backend trace identifies the failing route. |
| Disconnect/reconnect while ready | `Disconnect`, `Reconnect`, `RefreshClient` | presence/session diagnostics including stale-presence invariants | `websocket_ready_session_recovery`, `backend_reconnect_ready_session_recovery`, `disconnect_refresh_convergence` | fuzz includes disconnect, reconnect, restart, refresh | mixed | Covered by scenarios and fuzz; model abstracts reconnect without websocket session IDs. |
| Restart with stale backend membership/presence | not directly modeled; approximated by `Disconnect`, `Reconnect`, `RefreshClient` | `channel.stale_membership_on_session_connect`, `channel.stale_peer_presence_projected_live`, `presence.offline_retained_connected_session` | `restart_ready_session_recovery`, `restart_ready_session_recovery_with_offline_repair`, `disconnect_clears_stale_peer_presence_during_state_refresh`, `restart_partial_join_recovery` | fuzz seeds 123 and 124 promoted to scenarios | backend / mixed | Covered outside TLA; model expansion would need session/device identity generations. |
| Receiver readiness drift | `receiverReady`, `MarkReceiverReady`, `MarkReceiverNotReady`, `ReceiverReadyRequiresJoinedPresence` | receiver-readiness and selected-session diagnostics | `request_accept_ready_receiver_ready_gate`, `background_wake_refresh_stability` | fuzz includes delayed receiver signaling | mixed | Covered; TLA keeps readiness conservative but does not model audio warmup details. |
| Backend refresh drift | `RefreshClient`, `PhaseFromBackend` | backend projection invariants in registry and merged diagnostics | `request_accept_ready_refresh_stability`, `delayed_accept_refresh_race`, `disconnect_refresh_convergence` | fuzz generates summary/invite/channel refreshes | mixed | Covered by scenarios; TLA abstracts refresh as authoritative and instantaneous. |
| Active transmit sender loses presence | `Disconnect`, `ShouldClearTransmitAfterDisconnect`, `ActiveTransmitterIsJoinedMember` | `channel.active_transmit_sender_presence_drift` | Partially covered by disconnect/restart scenarios | fuzz includes disconnect during active flows | backend | Open model-expansion candidate: add a focused membership/presence-loss active-transmit trace if backend diagnostics identify a gap. |
| Wake token loss during addressable transmit | `ClearWakeToken`, `ShouldClearTransmitAfterTokenClear`, `ActiveTransmitHasAddressablePeer` | backend wake target and live projection diagnostics | Background wake scenarios cover stable wake-ready state, not token revocation during active transmit | fuzz does not explicitly revoke tokens today | backend / Apple boundary | Open scenario/fuzz gap. Needs a repo action for token revocation or backend-side probe before scenario promotion. |

## Open Modeling Backlog

1. **Membership or presence loss during active transmit**
   - Add a TLA trace target around `Disconnect` / `LeaveChannel` while
     `activeTransmit` is set.
   - Promote to a scenario only after identifying the concrete implementation
     route: explicit disconnect, stale session repair, backend presence repair,
     or app restart.

2. **Session/device identity generations**
   - Current model has devices but not websocket session IDs, app restarts, or
     active-device ownership epochs.
   - This would let TLA reason about stale presence and stale active-channel
     repairs instead of leaving them entirely to backend diagnostics and fuzz.

3. **Wake-token revocation during transmit**
   - Current model has `ClearWakeToken`, but the scenario suite has no direct
     action for revoking an APNs/PTT token mid-flow.
   - Add only after deciding whether the backend, app, or Apple boundary owns
     the revocation event.

4. **Bounded liveness classes**
   - Lease expiry is currently represented as a convergence diagnostic rather
     than a temporal liveness property.
   - Add temporal checks only after the safety model remains stable and the
     bound can be mapped to concrete app/backend timers.

## Promotion Rule

When TLC finds a counterexample:

1. Classify it as invalid, valid, or underspecified in `FINDINGS.md`.
2. Name the broken truth as an invariant when it is invalid.
3. Add or update the TLA invariant when it belongs in the model.
4. Add the runtime-visible invariant to `invariants/registry.json` when app,
   backend, or merged diagnostics can detect it.
5. Convert the abstract trace into a deterministic `scenarios/*.json`
   regression when it crosses app/backend behavior.
6. Add a lower-level Swift or Unison regression for the pure rule that should
   prevent the bad state.
7. Run the appropriate merge mode:
   - strict merge for recovery scenarios that should end cleanly
   - non-strict merge for expected-violation scenarios that intentionally emit
     an invariant
