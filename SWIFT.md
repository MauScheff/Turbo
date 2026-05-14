# Swift / iOS Guide

Status: active guide.
Canonical home for: Swift/iOS architecture rules, app-side implementation expectations, component boundaries, and Swift ADT patterns.
Related docs: [`APP_STATE.md`](/Users/mau/Development/Turbo/APP_STATE.md) owns app-visible state semantics; [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md) owns simulator/device/PTT/audio debugging loops.

This file contains the app-side architecture and working rules for Swift, SwiftUI, PushToTalk integration, and client-side state management.

Use [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md) for the canonical state-machine, ownership, invariant, and proof model.

For simulator/device/PTT debugging loops and operational debugging guidance, use:

- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md)
- [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md) for targeted Swift Testing command syntax and zero-test guardrails
- [`APP_STATE.md`](/Users/mau/Development/Turbo/APP_STATE.md) for the app-visible session states and happy-path transition examples

## Product engineering expectations

- Improve the shape of the system as you solve a bug. If the fix leaves the overall structure worse, it is not done.
- Do not describe work as "hardening" unless the underlying design is already sound. First investigate the failure deeply, identify the real invariant that is broken, and solve that cleanly.
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
- For targeted Swift `@Test` runs, use `just swift-test-target <name>` by default. If raw `xcodebuild -only-testing` is unavoidable, use `TurboTests/<suite>/<function>()` with the trailing parentheses and confirm a nonzero Swift Testing test executed.
- Prefer tests at the highest-leverage seam:
  - pure reducer / domain tests first
  - coordinator / client integration tests second
  - physical-device checks only for the Apple/PTT/audio surface that cannot be simulated
- For iOS refactors, prefer extracting small dedicated types/files over growing `ContentView.swift`.
- For backend and app integration, keep repeatable probes and smoke checks checked into the repo when they materially improve iteration speed.

## App Architecture Pattern

Apply the global workflow model this way on the app side:

- Keep the UI thin.
  - views render derived state
  - views emit user intents
  - views should not own business-state truth
- Normalize every input into typed events before it reaches the core.
  - UI gestures, backend updates, websocket signals, and Apple/PTT callbacks should all become explicit domain events
  - reducers or transition functions should decide the next valid state
- Make the system observable at the state-machine seam.
  - log meaningful transitions, invariants, and rejected events
  - prefer diagnostics that explain why a transition happened or was ignored

When a code path does not currently match this shape, the preferred direction is to move more logic into typed state, typed events, and derived projections rather than adding another local flag or UI workaround.

## Swift ADT Patterns

Use Swift enums and structs to model ADTs consistently:

| ADT concept | Swift construct |
| --- | --- |
| Sum type: one of many variants | `enum`, usually with associated values |
| Product type: fields that coexist | `struct` |
| Recursive type | `indirect enum` |
| Open/extensible family | `protocol` |

Use an enum with associated values for any closed set of variants:

```swift
enum Result<Value> {
    case success(Value)
    case failure(Error)
}
```

Always handle enums with exhaustive `switch` statements. Prefer associated values over optional fields when data only exists in one case.

Use structs for product data:

```swift
struct User {
    let id: Int
    let name: String
}
```

Prefer immutable stored values where practical. Use `indirect enum` for recursive domains:

```swift
indirect enum Tree<Value> {
    case empty
    case node(left: Tree, value: Value, right: Tree)
}
```

Use protocols when the set of cases must be open and extensible:

```swift
protocol Shape {
    func area() -> Double
}
```

Mental model:

- `AND` means `struct`.
- `OR` means `enum`.
- `Optional` is already an ADT: `.none` or `.some(Wrapped)`.
- Invalid states should be unrepresentable.

Good:

```swift
enum Payment {
    case cash
    case card(number: String)
}
```

Bad:

```swift
struct Payment {
    let isCash: Bool
    let cardNumber: String?
}
```

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
