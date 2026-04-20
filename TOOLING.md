# Tooling Guide

This file describes the main tooling and operational infrastructure in this repo so an agent can choose the fastest safe workflow.

## Core idea

Turbo is not a single-tool repo.

It has:

- a Swift/iOS app built and tested with Xcode tooling
- a Unison backend whose source of truth lives in the Unison codebase `turbo/main`
- a `justfile` that wraps the common local, simulator, deploy, and debugging loops
- helper scripts for probes, APNs/PTT wake testing, and scenario support

Use the thinnest tool that answers the question or performs the change.

For app-side distributed behavior, the preferred proof loop is not ad hoc manual simulator use. It is the automated simulator scenario infrastructure: checked-in scenario JSON, Swift test execution via `xcodebuild`, and merged diagnostics inspection.

Treat [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) as the higher-level workflow contract for how that infrastructure should be used.

## Source of truth by area

- Swift app code:
  - checked-in files under [`Turbo/`](/Users/mau/Development/Turbo/Turbo)
- Unison backend code:
  - the Unison codebase `turbo/main`
  - access through UCM / Unison MCP, not repo `.u` files as primary source
- scenario specs and helper scripts:
  - checked-in files under [`scenarios/`](/Users/mau/Development/Turbo/scenarios) and [`scripts/`](/Users/mau/Development/Turbo/scripts)

## Main tools

### `just`

`just` is the preferred entrypoint for repeated workflows.

Use it for:

- deploys
- route probes
- local backend serving
- simulator scenarios
- merged diagnostics reads
- APNs/PTT wake helpers

If a task sounds like an established operational flow, check the [`justfile`](/Users/mau/Development/Turbo/justfile) before inventing a bespoke command sequence.

### Unison MCP / UCM

Use the Unison MCP tools and UCM for backend codebase work.

Use this path when you need to:

- inspect backend definitions
- read docs for backend types/functions
- typecheck Unison scratch files
- update the Unison codebase
- run backend entrypoints such as `turbo.serveLocal`

Important:

- backend source is not primarily represented as normal repo files
- repo-root `.u` files are scratch / workflow artifacts, not the deployed backend source of truth

### Xcode / simulator tooling

Use Xcode build/test flows for app-side work.

Use this path when you need to:

- build or test the iOS app
- run simulator scenarios
- inspect Swift test failures
- debug device-only Apple/PTT/audio behavior

Important:

- the repo has an automated simulator scenario test path, not just manual simulator usage
- this is the preferred way to iterate and prove distributed control-plane behavior when a physical device is not required
- physical devices are still required for real Apple PushToTalk UI, microphone permission, backgrounding, lock screen behavior, and actual audio behavior

### Helper scripts

The repo includes scripts for recurring backend and diagnostics flows, especially under [`scripts/`](/Users/mau/Development/Turbo/scripts).

Common examples include:

- route probing
- APNs/PTT wake bridging
- direct APNs push sending

Prefer the checked-in helper over rebuilding the same logic ad hoc.

## Common entrypoints

Important backend entrypoints:

- `turbo.serveLocal`
- `turbo.deploy`

Important operational commands:

- `just deploy`
- `just route-probe`
- `just route-probe-local`
- `just serve-local`
- `just simulator-scenario`
- `just simulator-scenario-suite`
- `just simulator-scenario-suite-hosted-smoke`
- `just simulator-scenario-merge`
- `just simulator-scenario-merge-strict`
- `just simulator-scenario-local`
- `just simulator-scenario-suite-local`
- `just simulator-scenario-merge-local`
- `just simulator-scenario-merge-local-strict`
- `just swift-test-target <name>`
- `direnv exec . just ptt-push-target <channel_id> <backend> <sender>`
- `direnv exec . just ptt-apns-worker`
- `direnv exec . just ptt-apns-bridge`

For deploys, the distinction is:

- if no interactive `ucm` process is already occupying the local codebase, use `just deploy`
- if you are already working inside a live `ucm` session, `just deploy` can block on that codebase lock; in that case keep using the existing codebase session and run `turbo.deploy` there via MCP/UCM

In either case, if you changed backend behavior in the local Unison codebase, that change is not live on `https://beepbeep.to` until `turbo.deploy` has actually run.

For APNs credentials, keep the `.p8` file outside the repo and expose either `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY` in the local deploy environment. `turbo.deploy` resolves the path locally when present and stores the PEM text in cloud config as `TURBO_APNS_PRIVATE_KEY`, so deployed backend code should never depend on filesystem access.

For current real-device background/lock-screen wake testing, do not assume hosted Unison Cloud can send APNs directly yet. Direct APNs-from-Unison is the intended end state, but it is currently waiting on the upstream runtime rollout. Use the interim Cloudflare sender plan in [APNS_DELIVERY_PLAN.md](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md) for the production-shaped path.
Set `TURBO_APNS_TEAM_ID`, `TURBO_APNS_KEY_ID`, and either `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY` in the deploy environment before `turbo.deploy`. Optional `TURBO_APNS_BUNDLE_ID` and `TURBO_APNS_USE_SANDBOX` are also copied into cloud config when present.
For the current Cloudflare sender path, `TURBO_APNS_WORKER_SECRET` and `TURBO_APNS_WORKER_BASE_URL` must also be present in the deploy environment before `turbo.deploy`.
`ptt-apns-bridge` and `ptt-apns-worker` still exist as legacy/debug helpers. They are not the preferred interim production path.
Wake-send attempts should still be uploaded to the backend dev diagnostics surface so `merged_diagnostics.py` includes them in the merged timeline as `[wake:apns] ...` events.

## Deploying new backend env vars

When introducing a new backend environment variable, treat it as a three-part change:

1. Add the variable to the local deploy environment.
2. Update `turbo.deploy` so the variable is copied into the named cloud environment.
3. Add or extend a small runtime config surface so the deployed service can report whether it sees the new value.

Do not stop at step 1. A variable existing in the local shell does not make it live in the deployed backend. New backend env vars are not fully wired until deploy-time sync and runtime visibility are both in place.

## Preferred app-side testing infrastructure

For distributed app/backend flows that do not require a physical device, prefer this stack:

- checked-in scenario specs in [`scenarios/`](/Users/mau/Development/Turbo/scenarios)
- Swift test execution of `TurboTests/SimulatorScenarioTests`
- `just simulator-scenario <scenario>` or `just simulator-scenario-suite`
- merged diagnostics via `just simulator-scenario-merge`
- strict invariant checking via `just simulator-scenario-merge-strict`
- typed state-machine projections captured in diagnostics snapshots and asserted by scenarios

`just simulator-scenario-suite` is the canonical full run. It executes the dedicated simulator scenario suite with no runtime filter, which means every checked-in `scenarios/*.json` file is exercised automatically.

`just simulator-scenario-suite-hosted-smoke` is the deployed-surface subset. Use it when you want a fast hosted confidence pass without running the entire scenario catalog against `https://beepbeep.to`. It intentionally excludes transport-fault recovery scenarios whose websocket/device-connectivity invariants are only modeled deterministically in the local websocket lane.

`just simulator-scenario-suite-local` is the deterministic local websocket-backed catalog run. It assumes `just serve-local` is already running on `http://localhost:8090/s/turbo`.

The simulator scenario commands are backed by `scripts/run_simulator_scenarios.py`, which owns the temporary runtime config, serializes scenario runs with a repo-local lock, and retries transient XCTest bootstrap failures. Prefer the `just` recipes over direct `xcodebuild` for the scenario loop.

`just swift-test-target <name>` is the supported targeted Swift Testing loop. It runs the full non-UI bundle and fails if the requested test name never appears in the output, which prevents the false-green "0 tests executed" cases that can happen with direct `-only-testing` invocations against Swift Testing tests in this repo.

This is the preferred way to iterate and prove:

- request / accept / ready flows
- disconnect flows
- distributed state-machine bugs
- simulator-backed PushToTalk shim behavior
- typed transport-fault regressions such as dropped, delayed, or duplicated backend/websocket deliveries

Escalate to physical devices only when the behavior depends on:

- the real Apple PushToTalk framework/UI surface
- microphone permission
- backgrounding or lock-screen behavior
- actual audio capture/playback behavior

## Environment helpers

### `direnv`

Use `direnv exec . ...` when running commands that depend on repo-local environment configuration, especially APNs/PTT helper flows.

### Diagnostics infrastructure

Debug builds publish structured diagnostics, and the backend supports exact-device diagnostics reads, including simulator identities.

This makes the standard loop:

1. reproduce
2. run the scenario or probe
3. merge diagnostics
4. inspect timeline and invariant violations

Prefer that over guessing from screenshots or manual tap-through notes.

Scenario runs are stricter than normal app debugging:

- normal debug builds may auto-publish diagnostics opportunistically
- simulator scenarios publish explicit scenario-tagged diagnostics artifacts and verify exact-device reads against those artifacts
- scenario view models disable automatic diagnostics publishing so scenario verification does not get overwritten by later background uploads from the same simulator identity
- merged diagnostics now also parse explicit `INVARIANT VIOLATIONS` sections, derive pair-level violations, support `--json`, and can fail non-zero with `--fail-on-violations`

`just route-probe` should be treated as a semantic probe, not just a route-existence check. In particular, diagnostics upload/latest routes should round-trip the exact `deviceId` and `appVersion` that were just written.

Use `just route-probe-local` when iterating on the local websocket-backed backend. It exercises the same semantic checks against `ws://` / `http://` routes instead of the deployed `wss://` / `https://` surface.

Local-only transport-fault scenarios belong in the local websocket lane. The scenario runner enforces `"requiresLocalBackend": true`, so hosted runs fail fast if you explicitly ask for a local-only scenario without a local base URL.

## How to choose the right tool

- frontend-only UI or app-state task:
  - start with checked-in Swift files and Xcode/simulator tooling
- frontend/backend distributed behavior that can be simulated:
  - start with `just simulator-scenario`
  - inspect `just simulator-scenario-merge`
- backend route/storage/query/deploy task:
  - start with Unison MCP/UCM plus `just`
- distributed control-plane bug:
  - start with `just simulator-scenario` and `just simulator-scenario-merge`
- APNs wake or lock-screen receive issue:
  - start with `ptt-push-target`, then a deployed backend, then devices

## Related docs

- [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md)
- [`handoffs/README.md`](/Users/mau/Development/Turbo/handoffs/README.md)
- [`handoffs/TEMPLATE.md`](/Users/mau/Development/Turbo/handoffs/TEMPLATE.md)
- [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md)
- [`SWIFT.md`](/Users/mau/Development/Turbo/SWIFT.md)
- [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md)
