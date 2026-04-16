# Swift / iOS Guide

This file contains the app-side architecture and working rules for Swift, SwiftUI, PushToTalk integration, and client-side state management.

For simulator/device/PTT debugging loops and operational debugging guidance, use:

- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md)
- [`APP_STATE.md`](/Users/mau/Development/Turbo/APP_STATE.md) for the app-visible session states and happy-path transition examples

## Product engineering expectations

- Build toward a production-grade system by default:
  - explicit invariants
  - deterministic state transitions
  - strong observability
  - repeatable verification loops
  - minimal hidden coupling between app, backend, and Apple frameworks
- Improve the shape of the system as you solve a bug. If the fix leaves the overall structure worse, it is not done.
- Do not describe work as "hardening" unless the underlying design is already sound. First investigate the failure deeply, identify the real invariant that is broken, and solve that cleanly.
- Prefer the most elegant solution that fixes the issue both locally and globally over a narrow mitigation that only masks one symptom.
- Prefer explicit state machines or reducer-style state transition logic for session, signaling, and UX coordination problems.
- When the domain can be in exactly one of several modes, model it as an enum with associated values instead of a bag of booleans.
  - keep state-specific payloads inside the corresponding case
  - preserve weird but real distributed cases as first-class variants instead of flattening them away
  - example: simultaneous incoming and outgoing requests should be a real relationship case, not "incoming wins" or "outgoing wins" precedence hidden in call sites
- Prefer a functional core / imperative shell split when feasible:
  - pure derivation and transition logic in testable units
  - side effects isolated in coordinators, clients, or adapters
- Prefer component-driven development on the app side:
  - views render derived state
  - domain types own business rules
  - infrastructure clients own integration details
- Decouple by responsibility, not by arbitrary file splitting:
  - relationship state
  - selected-session state
  - backend transport
  - PushToTalk integration
  - media transport
  - diagnostics / developer tooling
  should have clear boundaries
- Remove demo or scaffold runtime behavior once a production-backed path exists. Do not keep hardcoded mock contact flows in the shipping path.
- Build observability in as part of the feature:
  - actionable error messages in Xcode logs and on-device
  - structured diagnostics with subsystem, timestamp, and relevant identifiers
  - quick local/prod verification tooling when applicable
  - automatic log capture when it materially improves debugging speed
- Use Red/Green TDD for core logic:
  - write or update a failing test first where practical
  - make it pass with the smallest structural change
  - refactor while keeping tests green
- Prefer tests at the highest-leverage seam:
  - pure reducer / domain tests first
  - coordinator / client integration tests second
  - physical-device checks only for the Apple/PTT/audio surface that cannot be simulated
- For iOS refactors, prefer extracting small dedicated types/files over growing `ContentView.swift`.
- For backend and app integration, keep repeatable probes and smoke checks checked into the repo when they materially improve iteration speed.

## Default architecture pattern

This is the default shape we want across the app, and usually across the system wherever it fits:

- Keep the UI thin.
  - views render derived state
  - views emit user intents
  - views should not own business-state truth
- Model each workflow around one canonical domain state machine.
  - use enums with associated values for mutually exclusive phases
  - keep phase-specific data inside the matching case
  - do not spread the same truth across parallel booleans, optional fields, and UI latches
- Normalize every input into typed events before it reaches the core.
  - UI gestures, backend updates, websocket signals, and Apple/PTT callbacks should all become explicit domain events
  - reducers or transition functions should decide the next valid state
- Prefer a functional core / imperative shell split.
  - the core should derive state and transitions with pure or mostly-pure functions
  - adapters, clients, and coordinators should contain framework calls and side effects
- Store canonical state once and derive projections from it.
  - selected-contact UI state, button labels, status text, and diagnostics summaries should be projections, not competing sources of truth
- Make important transitions idempotent and replay-safe.
  - duplicate delivery, retries, reconnects, and reordered signals should converge on the same valid state
  - explicit stop or release should dominate stale late-arriving events
- Make the system observable at the state-machine seam.
  - log meaningful transitions, invariants, and rejected events
  - prefer diagnostics that explain why a transition happened or was ignored

When a code path does not currently match this shape, the preferred direction is to move more logic into typed state, typed events, and derived projections rather than adding another local flag or UI workaround.

## Current app shape

The important boundaries are:

- [`Turbo/ConversationDomain.swift`](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift)
  - authoritative selected-peer derivation
  - relationship ADTs, selected-session detail ADTs, and projection rules
  - primary action derivation and reconciliation rules
- [`Turbo/SelectedPeerSession.swift`](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)
  - selected-session reducer / coordinator state
- [`Turbo/TransmitCoordinator.swift`](/Users/mau/Development/Turbo/Turbo/TransmitCoordinator.swift)
  - transmit lifecycle reducer
- [`Turbo/PTTCoordinator.swift`](/Users/mau/Development/Turbo/Turbo/PTTCoordinator.swift)
  - system PushToTalk reducer / callback state
- [`Turbo/PTTSystemClient.swift`](/Users/mau/Development/Turbo/Turbo/PTTSystemClient.swift)
  - real-device Apple PushToTalk client plus simulator shim
- [`Turbo/BackendClient.swift`](/Users/mau/Development/Turbo/Turbo/BackendClient.swift)
  - backend HTTP + websocket transport
- [`Turbo/BackendSyncCoordinator.swift`](/Users/mau/Development/Turbo/Turbo/BackendSyncCoordinator.swift)
  - summaries, invites, channel refresh, and reconciliation triggers
- [`Turbo/BackendCommandCoordinator.swift`](/Users/mau/Development/Turbo/Turbo/BackendCommandCoordinator.swift)
  - open peer / connect / accept / disconnect orchestration
- [`Turbo/AppDiagnostics.swift`](/Users/mau/Development/Turbo/Turbo/AppDiagnostics.swift)
  - structured diagnostics timeline and transcript export

`ContentView.swift` is still not tiny, but it is no longer the authority for session logic. New behavior should usually go into the domain, coordinators, or typed integration seams first.
