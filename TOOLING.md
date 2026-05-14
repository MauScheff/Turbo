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
- `just deploy-verified`
- `just postdeploy-check`
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
- `just reliability-intake <handle> [peer]`
- `just reliability-intake-shake <handle> <incidentId> [peer]`
- `just synthetic-conversation-probe`
- `just slo-dashboard <synthetic_conversation_json>`
- `just protocol-model-checks`
- `just swift-test-suite`
- `just swift-test-target <name>`
- `just reliability-gate-regressions`
- `just reliability-gate-smoke`
- `just reliability-gate-full`
- `just reliability-gate-local`
- `direnv exec . just ptt-push-target <channel_id> <backend> <sender>`
- `direnv exec . just ptt-apns-worker`
- `direnv exec . just ptt-apns-bridge`

For deploys, the distinction is:

- for the normal day-to-day verified deploy path, use
  `just deploy-staging-verified`; today it still targets the production-hosted
  base URL, but it is intentionally named for the future staging environment
- for the strict production release path, use `just deploy-production`; it runs
  `just production-preflight`, then deploys, then runs the hosted synthetic
  conversation canary and SLO dashboard
- if a deploy already happened and you only need live verification, use
  `just postdeploy-check`
- if no interactive `ucm` process is already occupying the local codebase and
  you deliberately want only the raw backend deploy primitive, use `just deploy`
- if you are already working inside a live `ucm` session, `just deploy` can block on that codebase lock; in that case keep using the existing codebase session and run `turbo.deploy` there via MCP/UCM

`just deploy` first runs `just backend-schema-drift-test`, which executes `turbo.schemaDrift.check`. This is the lightweight guard against accidentally changing the shape of values stored in Unison Cloud tables without an explicit migration/reset decision. If the guard fails, do not bypass it with an environment rotation as a normal workflow; follow [`MIGRATIONS.md`](/Users/mau/Development/Turbo/MIGRATIONS.md), then either revert the persisted type change, write and prove the migration/repair path, or deliberately approve the new baseline in `turbo.schemaDrift.expectedHashes` in the same change.

In either case, if you changed backend behavior in the local Unison codebase, that change is not live on `https://beepbeep.to` until `turbo.deploy` has actually run.

`just deploy-staging-verified` keeps raw deployment and live verification
separate but ties them into one human command. It currently points at the same
hosted environment as production until a dedicated staging environment exists.
The command runs `just swift-test-suite`, then deploys, then runs the hosted
verification canary.

`just production-preflight` is the expensive local proof gate before a
production release. It runs:

- `just swift-test-suite`
- `just reliability-gate-regressions`
- `just reliability-gate-full`

`just deploy-production` runs that preflight, then deploys, then verifies the
hosted surface. A failure after the deploy step means the deploy command
returned successfully, but the live production surface did not meet the hosted
conversation SLOs. Inspect the timestamped
`postdeploy-check.json`, `synthetic-conversation-probe.json`, and
`slo-dashboard.json` artifacts printed by the command before deciding whether to
roll forward, roll back, or convert the failure into a regression.

`just deploy-verified` remains as a compatibility alias for
`just deploy-staging-verified`.

For APNs credentials, keep the `.p8` file outside the repo and expose either `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY` in the local deploy environment. `turbo.deploy` resolves the path locally when present and stores the PEM text in cloud config as `TURBO_APNS_PRIVATE_KEY`, so deployed backend code should never depend on filesystem access.

For current real-device background/lock-screen wake testing, do not assume hosted Unison Cloud can send APNs directly yet. Direct APNs-from-Unison is the intended end state, but it is currently waiting on the upstream runtime rollout. Use the interim Cloudflare sender plan in [APNS_DELIVERY_PLAN.md](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md) for the production-shaped path.
Set `TURBO_APNS_TEAM_ID`, `TURBO_APNS_KEY_ID`, and either `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY` in the deploy environment before `turbo.deploy`. Optional `TURBO_APNS_BUNDLE_ID` and `TURBO_APNS_USE_SANDBOX` are also copied into cloud config when present.
For the current Cloudflare sender path, `TURBO_APNS_WORKER_SECRET` and `TURBO_APNS_WORKER_BASE_URL` must also be present in the deploy environment before `turbo.deploy`.
`ptt-apns-bridge` and `ptt-apns-worker` still exist as legacy/debug helpers. They are not the preferred interim production path.
Wake-send attempts should still be uploaded to the backend dev diagnostics surface so `merged_diagnostics.py` includes them in the merged timeline as `[wake:apns] ...` events.

## Deploying new backend env vars

When introducing a new backend environment variable, treat it as a three-part change:

1. Add the variable to the local deploy environment.
2. Add the key to `turbo.config.seedKeys` so `turbo.deploy` copies it into the named cloud environment.
3. If the value must be transformed before storage, extend `turbo.deploy.internal.seedCurrentOsEnv`.
4. Add or extend a small runtime config surface so the deployed service can report whether it sees the new value.

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

The simulator scenario commands are backed by `scripts/run_simulator_scenarios.py`, which owns the temporary runtime config, serializes scenario runs with a repo-local lock, shares the `/tmp/turbo-simulator-test.lock` simulator lane with targeted Swift tests, and retries transient XCTest bootstrap failures. Full catalog runs also allow one catalog-level retry per scenario to absorb hosted timing noise; focused single-scenario runs stay strict. Prefer the `just` recipes over direct `xcodebuild` for the scenario loop.

`just swift-test-suite` is the supported full `TurboTests` bundle loop. It runs the app-side Swift test bundle with the same serialized simulator lane used by targeted tests and scenario runs, writes an `.xcresult`, and fails if the result bundle reports zero executed tests.

`just swift-test-target <name>` is the supported targeted Swift Testing loop. It resolves the Swift Testing suite, invokes `xcodebuild` with the exact selector, and fails if the requested test name never appears in the output, which prevents the false-green zero-test cases that can happen with direct `-only-testing` invocations against Swift Testing tests in this repo.

If you must use raw `xcodebuild -only-testing`, Swift Testing selectors need the suite type and trailing function parentheses, for example `-only-testing:TurboTests/TurboTests/audioOutputPreferenceCyclesBetweenSpeakerAndPhone()`. The same selector without `()` can build and report success while selecting zero Swift Testing tests. See [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md) for the exact selector shape and proof rules.

Use the reliability gates when you need a named confidence level:

- `just reliability-gate-regressions` runs the focused Swift regressions and Python wrapper syntax checks.
- `just reliability-gate-smoke` runs those regressions, the hosted smoke scenarios, and strict merged diagnostics.
- `just reliability-gate-full` runs those regressions, the full hosted scenario catalog, and strict merged diagnostics.
- `just reliability-gate-local` runs those regressions, the full local scenario catalog, and strict local merged diagnostics. Start `just serve-local` first.

Use this command map to keep the reliability workflow small:

| Lane | Command | Status | Use when |
| --- | --- | --- | --- |
| Local regression gate | `just reliability-gate-regressions` | Primary | Proving focused code changes before deploy or before deeper scenario work. |
| Hosted smoke gate | `just reliability-gate-smoke` | Primary | Proving simulator-backed hosted control-plane behavior before a risky release. |
| Staging-grade verified deploy | `just deploy-staging-verified` | Primary | Day-to-day verified deploy path. Today it still targets the hosted production base URL. |
| Production preflight | `just production-preflight` | Primary | Run the expensive local proof gate before a production deploy. |
| Production deploy | `just deploy-production` | Primary | Run the strict preflight, deploy, then prove the live hosted canary and SLOs. |
| Postdeploy verification | `just postdeploy-check` | Primary | A deploy already happened, or production feels flaky and needs a fresh canary. |
| Reliability intake | `just reliability-intake`, `just reliability-intake-shake` | Primary | Starting from a physical-device, debug, TestFlight, production-like, or shake-to-report issue. Writes human/JSON diagnostics and a replay draft when possible. |
| Lower-level diagnostics merge | `just diagnostics-merge-pair` or `scripts/merged_diagnostics.py --json` | Building block | Reading merged diagnostics directly when you do not need the full intake artifact. |
| Production replay | `just production-replay` | Primary when diagnostics JSON exists | Turning field evidence into a local replay or scenario draft. |
| Protocol model check | `just protocol-model-checks` | Primary for protocol changes | Checking distributed interleavings and the matching Swift property tests. |
| Full hosted/local gates | `just reliability-gate-full`, `just reliability-gate-local` | Primary but expensive | Broad confidence after shared state-machine or backend contract changes. |
| Synthetic probe and SLO dashboard | `just synthetic-conversation-probe`, `just slo-dashboard` | Building blocks | Running only one half of `postdeploy-check` or combining extra SLO sources. |
| Route probe | `just route-probe`, `just route-probe-local` | Diagnostic/building block | Debugging route contract details or local websocket behavior. The synthetic conversation probe wraps this for the release canary. |
| Backend stability probe | `just backend-stability-probe` | Diagnostic | Separating hosted route availability from app/device behavior, especially for Unison Cloud escalation. |
| Retired production probes | older overlapping hosted probe recipes | Removed | Replaced by `postdeploy-check`; use `route-probe` for lower-level route-contract debugging. |
| Legacy APNs bridge helpers | `just ptt-apns-bridge`, `just ptt-apns-worker` | Diagnostic/legacy | Debugging old interim wake paths. Prefer the current deployed wake path and diagnostics surface when available. |

Use `just synthetic-conversation-probe` when you want a production-shaped
two-device control-plane canary without launching the app. It runs the semantic
route probe with synthetic caller/callee identities, requires the websocket,
receiver-ready, begin-transmit, push-target, and end-transmit checks to be
present, and writes per-iteration artifacts plus
`synthetic-conversation-probe.json` for comparison across runs.

Use `just slo-dashboard <synthetic-conversation-probe.json>` to turn probe
evidence into a static SLO report. The dashboard writes `slo-dashboard.json`,
`slo-dashboard.md`, and `reproduce.sh`, then fails when product-facing
conversation objectives breach their thresholds. The script can also read
backend stability probe JSON and merged diagnostics JSON directly when a report
needs to combine route health with invariant health.

Use `just protocol-model-checks` when a change touches core conversation
protocol rules. It validates the TLA+ communication model, runs TLC with the
configured safety invariants when `tla2tools.jar` is available, and runs the
Swift property tests for conversation projection and transport-fault planning.
Set `TLA2TOOLS_JAR` or pass the jar path as the first recipe argument when the
jar is not at `/tmp/tla2tools.jar`.

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

Debug builds publish structured diagnostics, and the backend supports exact-device diagnostics reads, including simulator identities. Agents should treat `scripts/merged_diagnostics.py` as the default entrypoint for debugging a two-device report. It is intentionally a merger over multiple sources, not "just telemetry" and not "just backend diagnostics."

Keep the two observability lanes separate:

- Cloudflare telemetry is the compact event stream for timing markers, invariant violations, route failures, production alerts, and shake-to-report pivots. Use it when you need the recent high-signal event timeline.
- Unison backend diagnostics are the latest full snapshot/transcript surface. Use it when you need routine state captures, the full local transcript, audio packet logs, playback scheduling details, or exact app state snapshot for a device. Debug builds keep routine state captures local and upload them through diagnostics snapshots; raw state-capture telemetry is only for an explicit short-session opt-in.

This makes the standard loop:

1. reproduce
2. run the scenario or probe, when the bug can be reproduced without physical devices
3. merge diagnostics with the single merged diagnostics command
4. inspect the merged timeline, backend latest transcript anchors, source warnings, and invariant violations

Prefer that over guessing from screenshots or manual tap-through notes.

For physical-device debugging, the expected agent loop is:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 1 @mau @bau
```

For normal intake from a human report, prefer the facade first:

```bash
just reliability-intake @mau @bau
just reliability-intake-shake @mau <incidentId> @bau
```

It writes a timestamped artifact under `/tmp/turbo-reliability-intake/` with a
summary, human merged diagnostics, JSON merged diagnostics, and a best-effort
production replay draft when there are enough participants. Use the lower-level
`merged_diagnostics.py` command directly when you need custom flags or a quick
terminal read.

For an agent investigation where the result will be saved and searched repeatedly, prefer this default:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata @mau @bau > /tmp/turbo-merged-diagnostics.txt
```

That command:

- fetches backend latest snapshots/transcripts by default
- merges Cloudflare telemetry when credentials are available
- keeps complete telemetry metadata in the human timeline
- bounds backend route waits so a slow latest-snapshot read does not block the whole investigation
- produces grep-friendly text for repeated searches during the debugging loop

Use `--insecure` only when local Python certificate roots block Cloudflare queries during development:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 1 --insecure @mau @bau
```

This is the right workaround for the recurring local failure where the diagnostics fetch reaches Cloudflare telemetry but Python cannot verify the local certificate chain. Treat it as scoped to that debugging read: rerun the diagnostics command with `--insecure`, note that TLS verification was relaxed for the local fetch, and keep the rest of the investigation unchanged. Prefer the `just` diagnostics wrappers when they fit because the common debug recipes already expose/default the `insecure` argument for this local-development case.

Use `--json` when you need to script over the result:

```bash
python3 scripts/merged_diagnostics.py --json --backend-timeout 8 --telemetry-hours 1 @mau @bau > /tmp/turbo-merged.json
```

Default flag guidance:

- Use `--backend-timeout 8` by default for physical-device debugging. Raise it to `15` if the backend is healthy but slow; lower it only when you explicitly want telemetry-first behavior.
- Use `--telemetry-hours 2` by default for manual device sessions. Narrow to `1` for a fresh repro; expand to `4` or more when the user has been testing for a long time.
- Use `--telemetry-limit 500` by default when saving an artifact for grep. Lower limits are fine for quick status checks; intense sessions can need more rows.
- Use `--full-metadata` by default when redirecting to a file. Skip it for quick terminal reads where compact output is easier.
- Do not use `--insecure` as a universal default. It is acceptable in local development when certificate roots are broken, but it disables TLS verification for HTTPS requests.
- Do not use `--no-telemetry` unless you are intentionally isolating backend latest snapshots/transcripts or Cloudflare credentials are broken.
- Do not use `--include-heartbeats` unless presence heartbeat cadence is the suspected bug.
- Use `--json` for automation, not as the default human debugging artifact.

Useful `merged_diagnostics.py` flags:

| Flag | Use when |
| --- | --- |
| `--base-url <url>` | Reading diagnostics from a non-default backend, such as a local or staging service. |
| `--backend-timeout <seconds>` | Bounding each backend latest/invariant/wake diagnostics request so telemetry can still return when the backend is slow. Use `8` or `15` for normal development. |
| `--device <handle=device-id>` | Fetching an exact device snapshot instead of the latest snapshot for a handle. This is common for simulator identities and scenario artifacts. Repeat once per handle when needed. |
| `--json` | Feeding merged diagnostics into a script, counting events, comparing transport digests, or attaching a machine-readable artifact. |
| `--fail-on-violations` | CI/scenario/debug gates where typed invariant violations should make the command fail. |
| `--full-metadata` | Inspecting complete Cloudflare telemetry metadata in the human timeline instead of the compact truncated view. |
| `--include-telemetry` | Explicitly enabling Cloudflare telemetry merge. This is already the default. |
| `--no-telemetry` | Reading only backend latest diagnostics snapshots/transcripts, useful when Cloudflare credentials are absent, slow, or irrelevant. |
| `--telemetry-hours <hours>` | Expanding or narrowing the Cloudflare lookback window. Use a small window for fresh physical-device reports; expand when debugging a long session. |
| `--telemetry-limit <n>` | Raising the maximum Cloudflare rows merged into the report. Increase this for intense sessions with many high-signal events or an explicitly opted-in raw state-capture telemetry run. |
| `--include-heartbeats` | Including backend presence heartbeat telemetry. Leave this off unless heartbeat cadence itself is the suspected bug. |
| `--telemetry-dataset <name>` | Querying a non-default Analytics Engine dataset. Rare outside telemetry migration/testing. |
| `--insecure` | Development-only workaround for local Python certificate-root problems when querying HTTPS/Cloudflare. |

Do not ask the tester to tap "Upload diagnostics" as the normal loop. In current debug builds, the app should automatically publish the latest full transcript after high-signal activity. Manual upload is a fallback for old builds, a suspected auto-publish regression, or one-off local investigation.

Interpret source warnings carefully:

- missing Cloudflare credentials means the command can still use backend latest snapshots, but the compact high-volume timeline is absent
- missing backend latest snapshot means the command can still show telemetry, but full transcript/audio-packet evidence is absent
- missing backend latest snapshot on a current debug build after fresh activity is itself a bug in auto-publish or backend diagnostics storage
- a backend timeout should not block the whole investigation; use the telemetry portion immediately, then probe backend health separately

When debugging audio quality or packet loss, backend latest snapshots matter. Telemetry can show that a transmit began or that an invariant fired, but the full transcript is where agents should look for `Captured local audio buffer`, `Enqueued outbound audio chunk`, transport digests, `Audio chunk received`, and `Playback buffer scheduled`.

Do not put every audio packet into Cloudflare telemetry by default. Packet-level audio evidence belongs in backend latest diagnostics, and it should usually be budgeted or summarized. If a bug needs deeper accounting, add a debug/test-gated diagnostic mode that emits compact sequence/digest/timing facts plus transmit-end totals, then keep using `merged_diagnostics.py` as the single read path.

Scenario runs are stricter than normal app debugging:

- normal debug builds auto-publish the latest full diagnostics transcript opportunistically after a short coalescing window
- routine debug state captures stay in local/backend diagnostics; only explicitly opted-in raw state-capture telemetry should create high-volume Cloudflare timelines
- simulator scenarios publish explicit scenario-tagged diagnostics artifacts and verify exact-device reads against those artifacts
- scenario view models disable automatic diagnostics publishing so scenario verification does not get overwritten by later background uploads from the same simulator identity
- merged diagnostics now also parse explicit `INVARIANT VIOLATIONS` sections, derive pair-level violations, support `--json`, include Cloudflare telemetry by default when credentials are available, tolerate missing latest backend snapshots, and can fail non-zero with `--fail-on-violations`

Use Cloudflare telemetry queries for high-volume debugging:

```bash
python3 scripts/query_telemetry.py --hours 2 --user-handle @mau --limit 100
python3 scripts/merged_diagnostics.py --telemetry-hours 2 @mau @bau
```

Telemetry merging requires `TURBO_CLOUDFLARE_ACCOUNT_ID` and `TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN`. Without those credentials, merged diagnostics still works from the backend latest snapshot. If a physical device is on an older build or the latest backend snapshot is missing, merged diagnostics prints a source warning and still emits the telemetry timeline.
If local Python certificate roots are stale, add `--insecure` to Cloudflare telemetry queries or merged diagnostics during development.
If a backend diagnostics route is slow or unhealthy, `merged_diagnostics.py` bounds each backend request with `--backend-timeout` so the command can still return telemetry and source warnings.

If diagnostics uploads appear to be stressing hosted Unison storage, clear the authenticated user's latest diagnostics anchor after deploying the current backend:

```bash
curl -X POST -H 'x-turbo-user-handle: @mau' -H 'Authorization: Bearer @mau' https://beepbeep.to/v1/dev/diagnostics/clear
```

If a known exact-device diagnostics row needs to be removed, clear it by key without materializing the stored payload:

```bash
curl -X POST -H 'x-turbo-user-handle: @mau' -H 'Authorization: Bearer @mau' https://beepbeep.to/v1/dev/diagnostics/clear/<device-id>
```

Do not use `reset-all` just to clear diagnostics; it also clears product/session state.

Use the backend stability probe when production bootstrap routes appear intermittently unavailable:

```bash
python3 scripts/backend_stability_probe.py --iterations 30 --timeout 8 --handle @mau
just backend-stability-probe https://beepbeep.to @mau 30 8
```

The probe repeatedly checks `/v1/health`, `/v1/config`, and `/v1/auth/session`, reports per-request latency/timeouts, and exits non-zero if any request fails. This is the preferred artifact for Unison Cloud escalation because it separates route availability from app/device behavior.

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
