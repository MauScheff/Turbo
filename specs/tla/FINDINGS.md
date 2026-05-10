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
