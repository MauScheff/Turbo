# Turbo

Turbo is an iOS Push-to-Talk app backed by a Unison control plane.

The app owns the Apple PushToTalk, audio, local projection, and user interaction surfaces. The Unison backend owns shared control-plane truth: identity, devices, direct channels, invites, membership, readiness, wake targeting, websocket signaling, and active transmit ownership.

The backend is the control plane, not the media plane.

## How We Work

Turbo's reliability loop is:

```text
report -> diagnostics -> owner -> invariant/regression -> fix -> prove -> release/check
```

Humans can describe a failure in product language. Agents should translate that report into typed evidence:

1. collect the best available diagnostics
2. classify who owns the broken fact
3. encode the broken truth as an invariant or regression
4. fix the owning subsystem
5. prove the fix with the narrowest automated proof
6. run the appropriate reliability gate or hosted check

Do not patch distributed or backend-owned bugs only in the frontend. Client changes can add guardrails, diagnostics, or better projection, but backend-owned truth must be fixed at the backend or shared contract.

## Reporting Bugs

When you reproduce a problem, give the agent:

- reporter handle
- peer handle, if there was one
- incident ID, if shake-to-report produced one
- what each side did
- what should have happened
- what actually happened
- whether this was debug, TestFlight, production-like, simulator, or physical device

Good agent prompt:

```text
I reproduced a device issue. The handles were @a and @b.
I used shake-to-report. The incidentId was <id>.
Expected: ...
Actual: ...
Please run reliability intake, classify ownership, convert this into an invariant
or regression where possible, fix the owning seam, and prove the fix.
```

## Reliability Intake

Use the facade command first for reports from physical devices, TestFlight, production-like builds, or normal debug sessions:

```bash
just reliability-intake @mau @bau
```

For a shake-to-report incident:

```bash
just reliability-intake-shake @mau <incidentId> @bau
```

The command writes a timestamped artifact under `/tmp/turbo-reliability-intake/` with:

- `intake-summary.md`
- `merged-diagnostics.txt`
- `merged-diagnostics.json`
- `production-replay/` when enough participant evidence exists
- `reproduce.sh`

The wrapper is intentionally thin. It runs [scripts/merged_diagnostics.py](/Users/mau/Development/Turbo/scripts/merged_diagnostics.py), asks for full metadata by default, captures both human and JSON output, and creates a best-effort replay draft through [scripts/convert_production_replay.py](/Users/mau/Development/Turbo/scripts/convert_production_replay.py) when possible.

## Debug vs TestFlight/Production

There are two observability lanes. Intake should use both whenever possible.

Telemetry is the compact event stream. It is for high-signal events, timings, route failures, invariant violations, production alerts, and shake-to-report markers. TestFlight and production-like reports depend heavily on this lane. Routine iOS diagnostics state captures stay local and are uploaded with the diagnostics transcript when needed, such as shake-to-report; raw state-capture telemetry is an explicit short-session debug opt-in.

Backend latest diagnostics is the full transcript and local-state anchor. It carries detailed app state, diagnostics transcript, and audio/session evidence that should not be emitted as high-volume telemetry. Current debug builds should auto-publish this after high-signal state transitions. Shake-to-report should also upload it.

Merged diagnostics combines both lanes. That is the agent-facing behavioral view:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata @mau @bau
```

Important interpretation rules:

- Missing Cloudflare credentials means telemetry may be absent, but backend latest diagnostics can still be useful.
- Missing backend latest diagnostics in a current debug build after fresh activity is itself a diagnostics/autopublish bug.
- In TestFlight or production-like reports, match the `incidentId` and `uploadedAt` before trusting a latest diagnostics URL, because the current URL points to the latest snapshot rather than an immutable incident record.
- For audio bugs, telemetry alone is not enough. Inspect backend latest transcript anchors for capture, enqueue, receive, scheduling, and playback events.

## Ownership Classification

After intake, classify the broken fact before editing:

- backend/shared truth: fix Unison domain, store, route, readiness, wake, websocket, or active-transmit ownership
- client projection/reducer: fix Swift state machines, coordinators, or typed projections
- Apple/PTT/audio adapter: fix the device boundary and prove shared logic separately where possible
- missing invariant: add detection at the authoritative seam before or with the fix
- recoverable bad state: follow [SELF_HEALING.md](/Users/mau/Development/Turbo/SELF_HEALING.md)

If the report is really a broken invariant, write it as:

```text
observer -> subject -> initial conditions -> event sequence -> expected invariant -> observed violation
```

Then encode the invariant using [INVARIANTS.md](/Users/mau/Development/Turbo/INVARIANTS.md).

## Proof Ladder

Prefer proof in this order:

1. Swift reducer, domain, or property tests for pure app rules
2. Unison/backend tests or route probes for backend-owned rules
3. deterministic simulator scenarios for distributed app/backend journeys
4. strict merged diagnostics for pair/convergence evidence
5. TLA+ model checks for protocol interleavings, ordering, retry, reconnect, or stale-projection questions
6. physical devices only for Apple PushToTalk UI, microphone permission, backgrounding, lock screen, audio-session activation, and actual audio capture/playback

Physical-device evidence is valuable. It should become an automated proof whenever the behavior is representable as app intents, backend routes, websocket events, simulator PushToTalk callbacks, timing, or transport faults.

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
| Deploy and verify | `just deploy-verified` |

## Deploy And Hosted Verification

Use one primary release path:

```bash
just deploy-verified
```

That command runs the raw backend deploy, then immediately runs the hosted
synthetic conversation canary and SLO dashboard against the live backend. A
failure after deploy means the deploy command returned, but the live
conversation path did not meet the product-facing SLOs. Inspect the printed
`postdeploy-check.json`, `synthetic-conversation-probe.json`, and
`slo-dashboard.json` artifact paths before deciding whether to roll forward,
roll back, or turn the failure into a regression.

If the deploy already happened and you only need to verify the live hosted
surface, run:

```bash
just postdeploy-check
```

Use lower-level probes only when diagnosing a specific layer:

- `just route-probe` checks route/websocket contract details on the hosted
  backend.
- `just route-probe-local` checks the same kind of route contract against the
  local websocket backend.
- `just synthetic-conversation-probe` and `just slo-dashboard` are building
  blocks behind `postdeploy-check`; use them directly only when you need one
  half of that pipeline or want to combine extra evidence sources.

Use [TOOLING.md](/Users/mau/Development/Turbo/TOOLING.md) for the expanded command catalog, local backend setup, APNs helpers, deploy details, route probes, fuzzing, and legacy/diagnostic tools.

## Source Of Truth

- Swift app code: [Turbo/](/Users/mau/Development/Turbo/Turbo)
- Swift tests: [TurboTests/](/Users/mau/Development/Turbo/TurboTests)
- Unison backend code: local Unison codebase `turbo/main`, accessed through MCP/UCM
- scenarios: [scenarios/](/Users/mau/Development/Turbo/scenarios)
- invariant registry: [invariants/registry.json](/Users/mau/Development/Turbo/invariants/registry.json)
- operational commands: [justfile](/Users/mau/Development/Turbo/justfile)
- diagnostics and proof scripts: [scripts/](/Users/mau/Development/Turbo/scripts)
- TLA+ specs: [specs/tla/](/Users/mau/Development/Turbo/specs/tla)

Repo-root `.u` files are scratch/workflow artifacts, not the backend source of truth.

## Docs Map

Read only what the task needs:

- [AGENTS.md](/Users/mau/Development/Turbo/AGENTS.md): repo-level agent rules
- [TOOLING.md](/Users/mau/Development/Turbo/TOOLING.md): command selection and operational workflows
- [STATE_MACHINE_TESTING.md](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md): canonical report-to-regression workflow
- [SWIFT.md](/Users/mau/Development/Turbo/SWIFT.md): app architecture and Swift-side working rules
- [SWIFT_DEBUGGING.md](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md): simulator, device, PTT, and audio debugging
- [UNISON.md](/Users/mau/Development/Turbo/UNISON.md): Unison workflow and backend editing rules
- [UNISON_LANGUAGE.md](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md): Unison syntax and semantics
- [BACKEND.md](/Users/mau/Development/Turbo/BACKEND.md): backend/storage/query/deploy guidance
- [BACKEND_STRUCTURE.md](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md): quick backend namespace map
- [MIGRATIONS.md](/Users/mau/Development/Turbo/MIGRATIONS.md): Unison Cloud storage schema changes
- [INVARIANTS.md](/Users/mau/Development/Turbo/INVARIANTS.md): invariant naming, placement, diagnostics, and regressions
- [SELF_HEALING.md](/Users/mau/Development/Turbo/SELF_HEALING.md): bounded repair for recoverable invalid states
- [TLA_PLUS.md](/Users/mau/Development/Turbo/TLA_PLUS.md): protocol model checking
- [SIMULATOR_FUZZING.md](/Users/mau/Development/Turbo/SIMULATOR_FUZZING.md): seeded distributed scenario fuzzing
- [PRODUCTION_TELEMETRY.md](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md): telemetry setup, alerts, and shake reports
- [handoffs/README.md](/Users/mau/Development/Turbo/handoffs/README.md): active session handoff conventions
- [journal/README.md](/Users/mau/Development/Turbo/journal/README.md): durable design/debugging notes

## Local Development

Use `just` for repeated workflows.

Backend entrypoints:

- `just serve-local-http`: local HTTP route checks
- `just serve-local`: local websocket-capable backend for simulator scenarios
- `just deploy-verified`: normal deploy plus hosted verification
- `just postdeploy-check`: hosted verification after a deploy

Set `TurboBackendBaseURL` in [Turbo/Info.plist](/Users/mau/Development/Turbo/Turbo/Info.plist) to the backend you are exercising:

- `http://localhost:8081/s/turbo` for local HTTP route checks
- `http://localhost:8090/s/turbo` for local websocket-backed simulator scenario work
- `http://<mac-lan-ip>:8081/s/turbo` for physical device against local HTTP
- `https://beepbeep.to` for the deployed backend

If local UI behavior looks impossible, restart the local backend and clear runtime state before drawing conclusions.

## Current Status

As of 2026-05-10:

- `just reliability-gate-regressions` is the fast focused proof gate.
- Hosted simulator scenario infrastructure and strict merged diagnostics are the main distributed control-plane proof loop.
- Real PushToTalk UI, microphone permission, backgrounding, lock screen, audio-session activation, and actual capture/playback still require physical devices.
- Historical blockers live in [handoffs/](/Users/mau/Development/Turbo/handoffs); do not treat old handoffs as current truth without checking the latest status.
