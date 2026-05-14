# Purpose

This is the agent entrypoint for Turbo. Read this first, then load only the files needed for the task.

Humans mostly use [`README.md`](/Users/mau/Development/Turbo/README.md). Agents use this file as the routing layer.

# Repo Facts

- Turbo is an iOS Push-to-Talk app backed by a Unison control plane.
- Swift app code lives in [`Turbo/`](/Users/mau/Development/Turbo/Turbo); Swift tests live in [`TurboTests/`](/Users/mau/Development/Turbo/TurboTests).
- Backend source of truth is the local Unison codebase `turbo/main`, accessed through Unison MCP/UCM, not repo-root `.u` scratch files.
- Repeated operational flows should go through [`justfile`](/Users/mau/Development/Turbo/justfile) recipes when available.
- The invariant registry is [`invariants/registry.json`](/Users/mau/Development/Turbo/invariants/registry.json).

# Default Workflow

Use [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md) as the canonical thinking model:

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Default rules:

- Start from the smallest authoritative docs and source needed for the task.
- Classify ownership before editing distributed, shared-state, backend-contract, or selected-session projection bugs.
- Fix the source subsystem, not just the visible client symptom.
- Treat backend/shared truth as backend-owned unless proven otherwise.
- Convert impossible behavior into a named invariant or regression.
- Prove with the narrowest useful automated proof before broader gates.
- Ask for physical-device verification only for Apple/PTT/audio/hardware surfaces that cannot be exercised from repo tooling.

# What To Read

## Swift / iOS / UI

Read:

- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md)
- [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md)

Also read [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md) for simulator scenarios, PushToTalk, device, audio-session, or operational debugging.

Use `just swift-test-target <name>` for targeted Swift `@Test` proofs. Do not count raw `xcodebuild -only-testing` as proof unless it selected and ran a nonzero Swift Testing test; see [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md).

## Backend / Unison / Routes / Storage / Deploy

Read:

- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md)
- [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md)
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)

Read [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) when syntax or semantics matter.

For persisted Unison Cloud storage changes, read [`MIGRATIONS.md`](/Users/mau/Development/Turbo/MIGRATIONS.md). Decide `preserve`, `reset`, or `revert`; updating `turbo.schemaDrift.expectedHashes` is not a migration by itself.

When searching backend structure broadly, start with [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md), then use Unison MCP/UCM for authoritative definitions.

## Mixed App / Backend Bugs

Read:

- [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md)
- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md)
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md)
- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md)
- [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md)
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)

Inspect both backend projection/route ownership and client projection before deciding where to fix. A frontend-only patch is incomplete when backend truth is wrong.

## Invariants / Diagnostics / Reliability

Read:

- [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md)
- [`RELIABILITY_PLAN.md`](/Users/mau/Development/Turbo/RELIABILITY_PLAN.md) for strategic reliability architecture or workstream planning
- [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md)
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md) when the bad state is safely recoverable
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) when the proof is scenario-backed
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md) for telemetry, shake reports, and production intake

## Scenario / Fuzz / Protocol Work

Read:

- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) for deterministic simulator scenario workflow
- [`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md) for generated interleavings, replay, shrink, and promotion
- [`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md) for protocol model checks
- [`scenarios/README.md`](/Users/mau/Development/Turbo/scenarios/README.md) for checked-in scenario format and catalog

## Product / Copy / Human-Facing Narrative

Read:

- [`PRODUCT_BRIEF.md`](/Users/mau/Development/Turbo/PRODUCT_BRIEF.md)
- [`BRAND.md`](/Users/mau/Development/Turbo/BRAND.md) when brand or visual language matters

# Handoffs And Journal

- Use [`handoffs/`](/Users/mau/Development/Turbo/handoffs) for active work state. If asked to write a handoff, create a new timestamped file from [`handoffs/TEMPLATE.md`](/Users/mau/Development/Turbo/handoffs/TEMPLATE.md).
- Use [`journal/`](/Users/mau/Development/Turbo/journal) for durable design/debugging lessons. If asked to write a journal entry, create a new timestamped file from [`journal/TEMPLATE.md`](/Users/mau/Development/Turbo/journal/TEMPLATE.md).
- When starting fresh on an existing thread of work, read [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md) and the latest relevant handoff. Do not treat old handoffs as current truth without checking newer evidence.

# Repo Defaults

- Prefer structural fixes over tactical patches that increase coupling.
- Prefer existing repo interfaces before inventing bespoke flows: `just`, Unison MCP/UCM, Xcode/simulator tooling, and checked-in scripts.
- Treat observability, verification, and repeatable debug loops as part of implementation.
- Treat documentation and testing as part of the definition of done for core Unison/backend work.
- Keep backend scope control-plane-only unless the user explicitly changes it.
- Use automated simulator scenarios and probes before physical-device debugging when the bug is not obviously Apple/PTT/audio-specific.
