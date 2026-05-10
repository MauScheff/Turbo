# Reliability Goals

Turbo's product promise depends on feeling like infrastructure: easy to start,
easy to talk, and predictable under real mobile conditions.

This document describes the reliability target for Turbo if the system were
designed with maximum freedom: architecture can change, technologies can be
replaced, and operational process can be rebuilt. It is a north-star document,
not a claim that software can literally be 100% reliable across Apple
PushToTalk, APNs, carrier networks, radios, batteries, permissions, and user
behavior.

The practical goal is:

> Every impossible state should be made unrepresentable, detected at the
> authoritative seam, or repaired automatically within a bounded path.

## Product Guarantees

Reliability should be expressed as product-level invariants, not vague uptime
language.

Turbo should aim for these guarantees:

- A user is never stuck transmitting after letting go, backgrounding, locking,
  proximity interruption, route churn, or app lifecycle interruption.
- Two users are never both authorized speakers for the same channel turn.
- The UI never claims a conversation is ready unless the system has enough
  evidence to support that claim.
- Harmless control-plane reconnects do not destroy an already established
  conversation.
- A user can always cancel, leave, or recover from a local bad state.
- Every shared-state command is retry-safe and duplicate-safe.
- Every recoverable bad state has one bounded, idempotent repair action owned by
  a clear subsystem.
- Every distributed contradiction appears in structured diagnostics with a
  stable invariant ID.
- Every recurring failure becomes a checked-in regression or a production replay
  case.

## Authority Model

Turbo should treat the backend as the authority for shared truth and the client
as a replayable replica with local authority only over local facts.

Backend-owned facts:

- users and devices
- channel identity and membership
- session identity and lifecycle
- readiness derived from backend-visible state
- active speaker lease / transmitter exclusivity
- wake targets and push eligibility
- transport negotiation metadata

Client-owned facts:

- gesture state
- local audio engine state
- local route and permission state
- local display smoothing
- device capability and Apple framework callbacks
- optimistic user intent waiting to be confirmed

The client can cache, derive, and optimistically display state, but shared truth
must converge back to backend authority after reconnect, relaunch, duplicate
delivery, or retry.

## Control Plane

The backend should remain a control plane, not a media plane.

The reliable control-plane shape is:

- typed commands with explicit preconditions and outcomes
- idempotency keys for user intents and transport commands
- monotonic session attempts where possible
- active-speaker leases instead of loose boolean transmitter flags
- append-log or event-sourced session history for replay and debugging
- projections derived from durable events rather than treated as the source of
  truth
- schema migrations that preserve, reset, or revert deliberately
- probes that continuously verify production semantics

The important design property is replayability: after a crash, reconnect, stale
push, duplicate HTTP response, or delayed websocket notice, the system should be
able to replay facts and converge to the same valid state.

## Client State Machine

The app should model conversation behavior as deterministic state machines plus
adapters.

Preferred shape:

- UI emits intents; it does not own business rules.
- PushToTalk callbacks, backend responses, websocket notices, timers, route
  changes, and app lifecycle events are normalized into typed events.
- Reducers produce a new state plus explicit commands.
- Commands are executed by adapters and reported back as typed events.
- State-specific fields live inside the state that makes them valid.
- Mutually exclusive modes use sum types instead of boolean bundles.

This is the client equivalent of the backend authority model: local behavior is
inspectable, replayable, and testable without a physical device unless the bug
is specifically about Apple's boundary.

## Media Reliability

Direct peer-to-peer transport should be an optimization, not the reliability
foundation.

The north-star media architecture is:

- encrypted direct transport when available
- encrypted relay transport always available as fallback
- media relay infrastructure separate from the Unison control plane
- automatic direct-to-relay and relay-to-direct path switching
- no user-visible call-state reset when the media path changes
- jitter buffering, packet-loss handling, and adaptive bitrate
- per-session media diagnostics correlated with backend and client traces

End-to-end encryption remains mandatory. A relay can carry audio, but it should
not be able to understand it.

## Wake And Resume

iOS wake delivery is not fully under Turbo's control. The system should treat
wake as a probabilistic boundary and design recovery paths around it.

Layered wake strategy:

- PushToTalk/APNs wake for background and lock-screen cases
- foreground websocket/control connection when available
- resume and reconcile on app open
- backend-visible device liveness and wake eligibility
- explicit stale-session detection
- bounded repair for stale Apple-held sessions or stale backend membership
- user-visible fallback only when the user can act

The product should distinguish "request sent" from "peer device has definitely
joined." Reliability improves when the UI does not imply certainty the system
does not have.

## Failure Model

Failures should be represented as states, not hidden behind ambiguous booleans.

Important state categories:

- joining
- joined
- connecting media
- ready
- transmitting
- receiving
- reconnecting control plane
- reconnecting media path
- wake pending
- wake unconfirmed
- repairing
- disconnected but session held
- ended

Each state should define:

- what evidence created it
- what user actions are allowed
- what backend commands are allowed
- what timers apply
- what events can leave the state
- which subsystem owns repair if the state expires

## Proving Reliability

Reliability work should follow this proof order:

1. Encode local rules as reducer or domain tests.
2. Encode distributed behavior as checked-in simulator scenarios.
3. Use merged diagnostics to prove cross-device convergence or contradiction.
4. Use backend route probes to prove control-plane semantics.
5. Use physical devices only for Apple-specific behavior such as PushToTalk UI,
   background wake, lock screen, audio session activation, microphone capture,
   and actual playback.

The preferred proof loop is:

1. Translate a bug report into a broken invariant.
2. Decide which subsystem owns the broken fact.
3. Add detection at the authoritative seam.
4. Emit a stable invariant ID into diagnostics.
5. Reproduce with a deterministic scenario or production replay.
6. Fix the source subsystem.
7. Keep the scenario, reducer test, property test, or probe as a regression.

For deeper protocol confidence, Turbo should eventually add model checking or a
small formal state-model harness for the session protocol. The goal is to answer
whether an impossible-looking state can be generated by any legal transition
sequence.

## Current Reliability Gates

These gates are the current pre-device proof surface:

- `just reliability-gate-regressions`
  - typechecks the scenario/diagnostics wrappers
  - runs the focused Swift regressions for signaling join drift, requester
    auto-join idle gaps, in-flight backend connect timeouts, and monotonic
    scenario expectation matching
- `just reliability-gate-smoke`
  - runs the focused regressions
  - runs the hosted simulator smoke scenarios with fixed simulator identities
  - runs strict merged diagnostics and fails on invariant violations
- `just reliability-gate-full`
  - runs the focused regressions
  - runs every checked-in hosted simulator scenario
  - runs strict merged diagnostics and fails on invariant violations
- `just reliability-gate-local`
  - runs the focused regressions
  - runs every checked-in scenario against a local `just serve-local` backend
  - runs strict local merged diagnostics without Cloudflare telemetry

The full hosted scenario catalog is allowed one catalog-level retry per scenario
to absorb hosted timing noise. Focused single-scenario runs remain strict, so a
scenario being debugged still fails immediately when its own expectation is not
met.

These gates do not replace physical-device proof for Apple-owned boundaries:
real PushToTalk UI, background wake, lock screen behavior, audio-session
activation, microphone capture, route changes, real playback, and entitlement
dependent Direct QUIC identity behavior still require device testing.

## Observability And Operations

Reliability is an operational system, not just code shape.

Turbo should operate with:

- service-level indicators for request-to-ready success, time-to-ready, wake
  delivery, first-transmit success, stuck-transmit rate, reconnect recovery, and
  repair success
- error budgets tied to product-facing reliability
- synthetic two-device conversations
- production probes for backend route semantics
- canary deploys and instant rollback
- feature flags for risky protocol changes
- per-session trace IDs across app, backend, push, and media
- production diagnostics replay into local tests
- runbooks for known failure classes

The most important operational outcome is that a production failure can become a
deterministic local artifact instead of a story that depends on memory.

## CTO-Level Roadmap

The reliable version of Turbo is built in layers:

1. Make simulator scenarios green and trusted.
2. Promote recurring bugs into typed invariants.
3. Add self-healing for provably recoverable bad states.
4. Make all shared-state commands idempotent and replayable.
5. Strengthen the backend session model around durable attempts, leases, and
   explicit lifecycle events.
6. Add production replay for diagnostics and traces.
7. Build a relay-backed encrypted media path so direct transport is an
   optimization instead of a dependency.
8. Add synthetic conversation probes and SLO dashboards.
9. Model-check or property-test the core session protocol.

Changing technologies before the state model is airtight mostly moves
uncertainty into a new system. The priority is to make ownership, transitions,
and recovery explicit first, then change infrastructure where it removes a
specific reliability limit.

## Related Documents

- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md)
- [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md)
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md)
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md)
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md)
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)
