# Turbo

Turbo is an iOS Push-to-Talk app backed by a Unison control plane.

The app owns Apple PushToTalk, audio, local projection, and user interaction surfaces. The Unison backend owns shared control-plane truth: identity, devices, direct channels, invites, membership, readiness, wake targeting, websocket signaling, and active transmit ownership.

The backend is the control plane, not the media plane.

## For Humans

If you are reporting a bug, give the agent:

- reporter handle
- peer handle, if there was one
- incident ID, if shake-to-report produced one
- what each side did
- what should have happened
- what actually happened
- whether this was debug, TestFlight, production-like, simulator, or physical device

Good prompt:

```text
I reproduced a device issue. The handles were @a and @b.
I used shake-to-report. The incidentId was <id>.
Expected: ...
Actual: ...
Please run reliability intake, classify ownership, convert this into an invariant
or regression where possible, fix the owning seam, and prove the fix.
```

## Agent Entry

Agents start from [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md).

The canonical agent thinking model is [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md):

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Use [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for exact commands and operational details.

## Primary Commands

| Need | Command |
| --- | --- |
| Intake a two-device report | `just reliability-intake @mau @bau` |
| Intake a shake report | `just reliability-intake-shake @mau <incidentId> @bau` |
| Run one simulator scenario | `just simulator-scenario <name>` |
| Inspect strict simulator diagnostics | `just simulator-scenario-merge-strict` |
| Fast regression gate | `just reliability-gate-regressions` |
| Hosted smoke gate | `just reliability-gate-smoke` |
| Full hosted scenario gate | `just reliability-gate-full` |
| Local full scenario gate | `just reliability-gate-local` |
| Protocol model checks | `just protocol-model-checks` |
| Verify an existing deploy | `just postdeploy-check` |
| Staging-grade deploy and verify | `just deploy-staging-verified` |
| Production preflight | `just production-preflight` |
| Production deploy and verify | `just deploy-production` |

## Local Development

Use `just` for repeated workflows.

Backend entrypoints:

- `just serve-local-http`: local HTTP route checks
- `just serve-local`: local websocket-capable backend for simulator scenarios
- `just deploy-staging-verified`: day-to-day verified deploy path
- `just production-preflight`: strict local proof gate before production
- `just deploy-production`: strict production deploy plus hosted verification
- `just postdeploy-check`: hosted verification after a deploy

Set `TurboBackendBaseURL` in [`Turbo/Info.plist`](/Users/mau/Development/Turbo/Turbo/Info.plist) to the backend you are exercising:

- `http://localhost:8081/s/turbo` for local HTTP route checks
- `http://localhost:8090/s/turbo` for local websocket-backed simulator scenario work
- `http://<mac-lan-ip>:8081/s/turbo` for physical device against local HTTP
- `https://beepbeep.to` for the deployed backend

If local UI behavior looks impossible, restart the local backend and clear runtime state before drawing conclusions.

## Source Of Truth

- Swift app code: [`Turbo/`](/Users/mau/Development/Turbo/Turbo)
- Swift tests: [`TurboTests/`](/Users/mau/Development/Turbo/TurboTests)
- Unison backend code: local Unison codebase `turbo/main`, accessed through MCP/UCM
- scenarios: [`scenarios/`](/Users/mau/Development/Turbo/scenarios)
- invariant registry: [`invariants/registry.json`](/Users/mau/Development/Turbo/invariants/registry.json)
- operational commands: [`justfile`](/Users/mau/Development/Turbo/justfile)
- diagnostics and proof scripts: [`scripts/`](/Users/mau/Development/Turbo/scripts)
- TLA+ specs: [`specs/tla/`](/Users/mau/Development/Turbo/specs/tla)

Repo-root `.u` files are scratch/workflow artifacts, not the backend source of truth.

## Docs Map

Read only what the task needs:

- [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md): agent entrypoint and doc routing
- [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md): canonical agent thinking model
- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md): command selection and operational workflows
- [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md): Swift Testing selector and proof rules
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md): app architecture and Swift-side working rules
- [`SWIFT_DEBUGGING.md`](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md): simulator, device, PTT, and audio debugging
- [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md): Unison workflow and backend editing rules
- [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md): Unison syntax and semantics
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md): backend/storage/query/deploy guidance
- [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md): quick backend namespace map
- [`MIGRATIONS.md`](/Users/mau/Development/Turbo/MIGRATIONS.md): Unison Cloud storage schema changes
- [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md): invariant naming, placement, diagnostics, and regressions
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md): bounded repair for recoverable invalid states
- [`RELIABILITY_PLAN.md`](/Users/mau/Development/Turbo/RELIABILITY_PLAN.md): strategic reliability architecture and workstreams
- [`RELIABILITY_GUIDELINES.md`](/Users/mau/Development/Turbo/RELIABILITY_GUIDELINES.md): reliability review questions and companion guidance
- [`RELIABILITY_CHECKLIST.md`](/Users/mau/Development/Turbo/RELIABILITY_CHECKLIST.md): design, debugging, proof, and release checklists
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md): deterministic scenario workflow
- [`TLA_PLUS.md`](/Users/mau/Development/Turbo/TLA_PLUS.md): protocol model checking
- [`SIMULATOR_FUZZING.md`](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md): seeded distributed scenario fuzzing
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md): telemetry setup, alerts, and shake reports
- [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md): active session handoff conventions
- [`journal/README.md`](/Users/mau/Development/Turbo/journal/README.md): durable design/debugging notes

## Current Work State

Current blockers and active work state live in [`handoffs/`](/Users/mau/Development/Turbo/handoffs). Do not treat old handoffs as current truth without checking newer evidence.
