# Purpose

This is the repo entrypoint for agent instructions.

Detailed guidance lives in:

- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md): tooling, entrypoints, and operational infrastructure
- [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md): Unison workflow, mode rules, documentation/testing rules
- [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md): Unison syntax, semantics, and language guide
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md): app/client architecture and client-side working rules
- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md): simulator/device/PTT/audio debugging loops
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md): backend/control-plane/storage/query guidance
- [`PRODUCT_BRIEF.md`](/Users/mau/Development/Turbo/PRODUCT_BRIEF.md): product framing, positioning, and audience-facing narrative
- [`journal/README.md`](/Users/mau/Development/Turbo/journal/README.md): engineering journal conventions for dense design/debugging notes

# Core Rules

- Be pragmatic and act decisively when the correct path is clear.
- Teach as you go.
- Prefer structural improvements over tactical patches that increase coupling or ambiguity.
- For Unison syntax and semantics, treat [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) as authoritative.
- The structure is the answer.
- When a bug report is really a broken invariant, translate the plain-language report into a typed invariant using [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md), add detection at the authoritative seam, and make it show up in merged diagnostics plus a regression.
- When searching broadly, use [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md) as a quick backend index, then use the Unison MCP to explore the backend authoritatively when you need the current structure or deeper detail.
- Investigate first and fix problems at their source—never patch backend issues in the frontend.
- For distributed, shared-state, or app/backend contract bugs, identify which subsystem owns the broken fact before editing code. Do not stop at the client seam if backend truth may be wrong.
- Client changes may add guardrails, diagnostics, or better projection, but they do not replace a backend fix when the backend owns the incorrect state.


# How To Work

- Start from the smallest set of authoritative docs and source needed for the task.
- Do not load every instruction file by default.
- Use existing repo interfaces before inventing bespoke flows:
  - `just` for repeated operational commands
  - Unison MCP/UCM for backend codebase work
  - Xcode/simulator tooling for app-side work
- Prefer proving behavior automatically with the repo's testing and scenario infrastructure whenever possible.
- Only ask the user to do things that cannot be done from the repo and tooling available to the agent, such as physical-device-only verification.
- Prefer the automated simulator scenario/test infrastructure when a task can be proven without a human on a physical device.
- Treat observability, verification, and repeatable debug loops as part of the implementation.
- If the task crosses boundaries, load the docs for those boundaries before changing code.
- For mixed app/backend bugs, inspect both the client projection and the backend projection path before deciding where to fix the issue.
- When ownership is unclear, add or improve diagnostics/invariants at the authoritative seam first, then fix the subsystem that violates them.
- Do not accept a frontend-only patch as complete for a distributed-state bug unless you have verified that backend truth is already correct and the defect is purely client-side derivation.

Prefer agent-driven development where it fits: turn behavior reports or requested changes into checked-in scenarios, run the automated proof loop, make the code change, and prove the result automatically. The canonical workflow lives in [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md).

# Preferred Proof Order

1. Prove behavior with automated tests and checked-in scenarios.
2. Use local reproducible tooling and diagnostics.
3. For mixed app/backend bugs, use diagnostics, backend route/projection inspection, and hosted or prod-like probes to prove where the contradiction originates before patching.
4. Ask for manual or physical-device verification only when the relevant surface cannot be exercised from the repo and tooling.

# Engineering Principles

- Model the system as explicit state machines and transitions, not as scattered callbacks and implicit coordination.
- Treat the backend as the authority for distributed or shared truth. Treat client state as derived, cached, local, or optimistic unless it is explicitly authoritative.
- Model shared domain truth in Unison types first when it is part of backend truth or app/backend contracts.
- Treat shared domain types in Unison as the canonical source of truth for distributed behavior and app/backend contracts.
- Use precise ADTs to make illegal states unrepresentable.
- When a thing can be in exactly one of several modes, model it as a sum type so it can only be one case at a time.
- Use product types for data that must coexist together, and sum types for states, phases, outcomes, and protocol variants.
- Do not model mutually exclusive states with combinations of booleans, nullable fields, or string status values.
- Put state-specific fields inside the corresponding variant so they only exist when that state is active.
- Prefer domain variants and typed transitions over booleans, stringly-typed flags, and implicit coordination.
- When app and backend both represent the same concept, the backend/domain model should lead and the client should derive from it.
- Drive behavior through explicit events and reducer-style transitions where possible. State changes should be inspectable, replayable, and explainable.
- Let transition functions pattern-match on the current state and event to produce the next valid state.
- Define and preserve invariants. Be explicit about preconditions, postconditions, and failure modes for critical flows.
- Validate at the boundary, then convert into stronger internal types as early as possible. Do not let raw or weakly-validated input leak deep into the system.
- Prefer a functional core / imperative shell split: pure derivation and transition logic in testable units, side effects isolated in adapters, coordinators, and clients.
- Prefer derived views over duplicated state. Store canonical state once and compute secondary or display state from it.
- Prefer designs that support equational reasoning: pure functions, explicit inputs, explicit outputs, and local reasoning by substitution.
- Prefer total functions where possible. When a function can fail or be partial, make that explicit in the types and call sites.
- Decouple subsystems so each one can be reasoned about, tested, and replaced independently. Think in systems and systems-of-systems: local changes should improve the behavior of the whole.
- Divide problems into small components with clear responsibilities. Keep files and functions small enough that intent, ownership, and transition logic remain auditable.
- Prefer pure transformations, explicit data flow, and functional composition over hidden mutation and side-effect-heavy orchestration.
- Prefer operations that are safe under retry, replay, and duplicate delivery (`idempotence`).
- Prefer update composition that remains valid when regrouped (`associativity`).
- Prefer reconciliation rules that do not depend on arbitrary ordering when the domain allows it (`commutativity`).
- Prefer update models with a clear identity or no-op case (`identity element`; often monoid-like composition).
- Design distributed state so replicas move toward agreement after replay, retry, reconnect, or partial failure (`convergence`, `monotonicity` where possible).
- Prefer the simplest design that preserves these properties. Do not add abstraction, indirection, or theory unless it improves clarity, correctness, or verifiability.

# Modes

These are general repo workflow modes:

- `DISCOVERY`: search for existing libraries, capabilities, or prior art
- `LEARN`: familiarize yourself with a subsystem, library, or code area before editing
- `BASIC`: handle narrow, well-defined tasks
- `DEEP WORK`: design and stage larger or underspecified tasks before implementation
- `DOCUMENTING`: improve or add documentation
- `TESTING`: add, improve, or restructure tests

When the task involves Unison code, follow the mode-specific rules in [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md).

# Architecture Snapshot

Turbo has two main surfaces:

- the iOS client in [`Turbo/`](/Users/mau/Development/Turbo/Turbo)
- the Unison backend/control plane, whose source of truth lives in the Unison codebase `turbo/main`, not in checked-in `.u` files

Important operational facts:

- Unison code is edited and queried through the Unison codebase and MCP tools
- the main local/backend entrypoints are `turbo.serveLocal` and `turbo.deploy`
- the repo [`justfile`](/Users/mau/Development/Turbo/justfile) is the preferred interface for repeated flows such as deploys, probes, local serving, simulator scenarios, and APNs/PTT helpers
- the preferred non-device proof loop for distributed app/backend behavior is the automated simulator scenario infrastructure built around `just simulator-scenario`, checked-in scenario JSON, Swift tests, and merged diagnostics

# Starting A New Session

If you do not have prior conversation context, read this core set first:

1. [`README.md`](/Users/mau/Development/Turbo/README.md), especially **AI agents / handoff notes**
2. [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md)
3. this file

Then load additional docs only as needed:

- read [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for tooling or infrastructure context
- read [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md) for iOS app architecture and client-side implementation work
- read [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md) for simulator scenarios, device debugging, PushToTalk wake behavior, audio-session debugging, or other operational app debugging
- read [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md) for Unison code, backend contracts, or Unison-specific workflow rules
- read [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) only when you need Unison syntax, semantics, or language-reference details
- read [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md) for routes, cloud storage, deploy/probe flows, APNs wake delivery, or backend schema/query design
- read [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md) for invariant IDs, diagnostics-backed rule encoding, and regression workflow
- read [`PRODUCT_BRIEF.md`](/Users/mau/Development/Turbo/PRODUCT_BRIEF.md) for product messaging, positioning, or user/audience context

For backend architecture background, also read:

- [`Server/unison_ptt_handoff.md`](/Users/mau/Development/Turbo/Server/unison_ptt_handoff.md)
- [`Server/backend_architecture.md`](/Users/mau/Development/Turbo/Server/backend_architecture.md)

# File Ownership

Use [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for:

- tool selection
- operational flows
- Unison MCP/UCM vs checked-in files
- simulator/diagnostics/APNs helper infrastructure

Use [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md) for:

- Unison-specific execution rules for DISCOVERY / LEARN / BASIC / DEEP WORK / DOCUMENTING / TESTING
- scratch-file and typechecking workflow
- `.doc` conventions
- testing expectations for core Unison code
- transcript guidance

Use [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) for:

- Unison syntax and semantics
- pattern matching, effects, records, collections, and core language rules
- language-level style guidance

Use [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md) for:

- app-side architecture
- state-machine / reducer / coordinator guidance

Use [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md) for:

- simulator scenario workflow
- physical-device escalation rules
- Apple PushToTalk / AVAudioSession iteration notes
- app-side debugging loops

Use [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md) for:

- control-plane-only backend scope
- OrderedTable and schema/query modeling rules
- route/deploy/probe loops
- APNs wake-target and backend transmit-target debugging

Use [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md) for:

- invariant naming and scope rules
- where invariant checks belong
- how to emit typed invariant violations into diagnostics
- how to connect violations to simulator scenarios and lower-level regressions

Use [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md) and [`handoffs/TEMPLATE.md`](/Users/mau/Development/Turbo/handoffs/TEMPLATE.md) for:

- session handoff conventions
- the timestamped project-state log
- historical operational memory

# Load Only What You Need

- frontend / SwiftUI / iOS / PushToTalk / simulator / device task:
  - read [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md)
  - read [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) if the task is operational
  - read [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md) if the task is primarily debugging, simulator-driven, device-specific, or PushToTalk/audio-session related
  - read [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md) only if the task also touches backend behavior, Unison APIs, or shared app/backend contracts
  - read [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) only if you need language-level Unison reference
- backend / routes / storage / deploy / probes / APNs wake path:
  - read [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md)
  - read [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md)
  - read [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) when syntax or semantics matter
  - read [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)
- mixed app/backend bug:
  - read [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md), [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md), [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md), [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md), and [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)
  - read [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) only when needed
- invariant or diagnostics-rule task:
  - read [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md)
  - read [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) when the invariant is distributed or scenario-backed
  - read [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md) and/or [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md) for the subsystem that owns the rule

# Repo Defaults

- Treat documentation and testing as part of the default definition of done for core Unison work.
- Treat the backend as control-plane-only unless the user explicitly changes scope.
- Prefer the automated simulator scenario/test loop to prove behavior whenever a physical device is not required.
- Prefer simulator scenario and probe loops before physical-device debugging when the bug is not obviously Apple/PTT/audio-specific.
- If asked to write a handoff, create a new timestamped file in [`handoffs/`](/Users/mau/Development/Turbo/handoffs) using [`handoffs/TEMPLATE.md`](/Users/mau/Development/Turbo/handoffs/TEMPLATE.md) instead of overwriting an existing handoff.
- If asked to write a journal entry, create a new timestamped file in [`journal/`](/Users/mau/Development/Turbo/journal) using [`journal/TEMPLATE.md`](/Users/mau/Development/Turbo/journal/TEMPLATE.md) instead of overwriting an existing journal entry.
