# Turbo

Turbo is an iOS Push-to-Talk App that uses a Unison Cloud backend.

The app side currently proves out Apple's PushToTalk framework integration. The backend side is now a first control-plane slice for direct 1:1 channels, device registration, ephemeral PTT token handling, HTTP control endpoints, websocket signaling, and APNs wakeups.

## Repository layout

- `Turbo/`: SwiftUI iOS prototype app.
- `Server/`: backend notes and architecture documentation.
- `AGENTS.md`: repo-specific instructions for AI/code agents working on the Unison codebase.
- `UNISON.md`: Unison workflow, mode rules, and documentation/testing rules.
- `UNISON_LANGUAGE.md`: Unison language guide and syntax reference.
- `SWIFT.md`: app-side Swift/iOS architecture and working guidance.
- `APP_STATE.md`: app-side state machines, session phases, and successful PTT flow examples.
- `SWIFT_DEBUGGING.md`: simulator/device/PTT/audio debugging guidance.
- `BACKEND.md`: backend/control-plane/storage/query guidance.
- `TOOLING.md`: tooling, operational entrypoints, and infrastructure overview.
- `STATE_MACHINE_TESTING.md`: canonical scenario-driven state-machine testing workflow.
- `INVARIANTS.md`: invariant rule catalog and diagnostics-backed regression guidance.
- `PRODUCTION_TELEMETRY.md`: production telemetry architecture, deployment, alerting, and query workflow.
- `journal/`: timestamped engineering notes for design lessons, debugging conclusions, and changelog-style session records.
- `.agents/`: supporting Unison language and workflow notes.

## Docs ownership

Use these docs as the primary authority for their respective concerns:

- `AGENTS.md`
  - repo-level working rules, mode overview, startup guidance, and doc-loading rules
- `TOOLING.md`
  - tooling, operational entrypoints, simulator/probe infrastructure, and how to choose the right tool
- `UNISON.md`
  - Unison workflow, scratch-file/typechecking process, and Unison-specific mode rules
- `UNISON_LANGUAGE.md`
  - Unison syntax, semantics, and language-reference guidance
- `SWIFT.md`
  - app/client architecture, state management boundaries, and implementation guidance
  - includes the default thin-UI / canonical-state-machine / ADT-first architecture pattern we want to apply broadly
- `APP_STATE.md`
  - app-visible session phases, state derivation, and PTT journey examples
- `SWIFT_DEBUGGING.md`
  - simulator/device/PTT/audio debugging loops and escalation rules
  - client-only handshake UX shortcuts and how to disable them during debugging
- `BACKEND.md`
  - backend/control-plane scope, storage/query rules, and backend operational guidance
- `STATE_MACHINE_TESTING.md`
  - the default distributed bug reproduction, proof, and regression-testing model
- `INVARIANTS.md`
  - how invariant IDs, typed violation logging, merged diagnostics checks, and regression expectations are encoded
- `PRODUCTION_TELEMETRY.md`
  - production telemetry architecture, worker/backend setup, and operator query workflow
- `handoffs/README.md`
  - handoff conventions and how to use the timestamped handoff log
- `handoffs/*.md`
  - timestamped project state and session memory
- `journal/README.md`
  - journal conventions and how to write concise design/debugging records
- `journal/*.md`
  - timestamped engineering journal entries; use these for lessons learned, ownership boundaries, and changelog-style notes

## Current app status

The iOS app has a backend integration path:

- It uses Apple's PushToTalk framework.
- It has the PTT entitlement and background mode configured.
- It receives real ephemeral PTT push tokens from `PTChannelManager`.
- It uses the backend for dev seeding, auth, device registration, direct-channel lookup, join, ephemeral token upload, and begin/end transmit.
- Contact presence, request queues, and conversation state are now backend-driven.
- The contact list now has a dedicated backend summary route, and the selected conversation uses a stronger backend-owned session snapshot.
- The app also surfaces Apple-held PushToTalk sessions separately, so a stale system session can be ended from the UI.
- Local websocket signaling is not currently used in the fast local-dev loop.
- The app no longer depends on WebRTC or CocoaPods; media transport is being kept behind an app-owned abstraction so a relay-oriented implementation can replace the prototype spike cleanly.

## Backend goal

The backend should act as the control plane, not the media plane.

Planned v1 responsibilities:

- dev auth and a simple user directory
- device registration
- stable backend-owned 1:1 direct channels
- channel membership checks
- ephemeral PTT token ingest and storage
- websocket signaling for control-plane notices and future transport setup
- single active transmitter enforcement per channel
- local stub push sender for development

Explicit non-goal for v1:

- media relay or SFU

Planned media direction after the prototype spike cleanup:

- iOS client: `PushToTalk` + `AVAudioSession` + `AVAudioEngine`
- transport: app-owned `MediaSession` boundary with a future relay-oriented implementation
- backend: Unison remains the control plane; media relay will run separately

## Architecture docs

Start here for backend design:

- `Server/unison_ptt_handoff.md`
- `Server/backend_architecture.md`

## Local Unison setup

Current local facts confirmed in this repo:

- Unison project name: `turbo`
- Reference project (read-only): `cuts`
- `ucm` is installed locally
- the local Unison MCP can access `turbo/main` and `cuts/main`

Current backend libraries installed in `turbo/main`:

- `base`
- `@unison/cloud`
- `@unison/routes`
- `@unison/json`

The `cuts` project is still the best local reference for service structure, store modules, and local/cloud entrypoint patterns.

## AI agents / handoff notes

If you are starting fresh in this repo:

Read this core set first:

1. Read `AGENTS.md`.
2. Read `handoffs/README.md`.
3. Read the latest file in `handoffs/` if you need the current project state.
4. Search `journal/` when a bug looks recurring or when you need the design reasoning behind a recent change.

Then load only the docs needed for the task:

- Read `TOOLING.md` for tooling and infrastructure context.
- Read `UNISON.md` for Unison/backend workflow rules.
- Read `UNISON_LANGUAGE.md` only for Unison syntax or semantics.
- Read `SWIFT.md` for app/client architecture and implementation work.
- Read `APP_STATE.md` for app-visible conversation/session states and transition examples.
- Read `SWIFT_DEBUGGING.md` for simulator/device/PTT/audio debugging.
- Read `BACKEND.md` for backend/cloud/storage/route work.
- Read `STATE_MACHINE_TESTING.md` when the task is about distributed bugs, scenario design, or proof loops.
- Read `INVARIANTS.md` when the task is about invariant design, diagnostics-backed regression rules, or merged diagnostics checks.
- Read `Server/backend_architecture.md` if you need backend structure or Unison deployment context.

Treat the backend as control-plane-only unless the user explicitly changes scope.

### Current app shape

The iOS client important boundaries are authority for session logic. New behavior should usually go into the domain, coordinators, or typed integration seams first.

### Instrumentation and iteration model

Turbo now has a real development observability loop:

- debug builds auto-capture structured state transitions
- debug builds auto-publish diagnostics after high-signal transitions
- the backend stores exact-device diagnostics per authenticated user
- merged timeline tooling can read `device A + device B` without manual upload steps
- simulator scenarios are checked into `scenarios/` and run against the simulator PTT shim plus the real backend

This means distributed control-plane bugs should now be debugged in this order:

1. reproduce in the simulator scenario runner when possible
2. inspect the merged timeline
3. only move to physical devices for Apple-specific behavior

Treat [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) as the canonical statement of that loop.

Use [`journal/`](/Users/mau/Development/Turbo/journal) to preserve concise but dense notes when a session produces an architectural lesson, a rejected approach, or a debugging result worth carrying forward. Use [`handoffs/`](/Users/mau/Development/Turbo/handoffs) when the main purpose is resuming active work.

### Current known blocker

The simulator diagnostics transport is fixed, but the scenario itself is not yet green.

What is true right now:

- `just simulator-scenario-merge` reliably reads exact-device simulator reports after a scenario run
- the scenario runner now executes real Swift Testing cases instead of silently running zero tests
- the current failing test is `TurboTests/simulatorDistributedJoinScenario()`

So the next engineering task is no longer “make simulator diagnostics visible”; it is “fix the actual scenario crash now that the simulator runner is truthful.”

### Fast iteration loop

Prefer this order:

1. Backend verification
   - `just prod-probe`
   - probe defaults are the reserved handles `@quinn` and `@sasha`, not the manual device-test pair
2. App verification in simulator
   - run `just simulator-scenario` for the distributed control-plane smoke
   - run the in-app self-check when you need one-app diagnostics
   - inspect the persistent diagnostics log when a state transition looks wrong
3. Real device verification
   - only for PushToTalk / background / lock-screen / audio behavior

### Scenario-driven simulator loop

The simulator is now valid for distributed control-plane verification because the app uses a simulator PTT shim instead of `PTChannelManager` there.

Use these commands:

- `just simulator-scenario`
  - runs the checked-in simulator scenarios in [`scenarios/`](/Users/mau/Development/Turbo/scenarios)
  - covers request creation, incoming accept, peer-ready, both-ready, transmit begin/end, and disconnect
  - activates the scenario runner through a temporary repo-local runtime config file so the simulator test process executes the selected spec deterministically
- `just simulator-scenario request_accept_ready`
  - runs only the named checked-in scenario
  - use this when iterating on one distributed bug without paying for the whole scenario set
- `just simulator-scenario-merge`
  - fetches the simulator pair's latest published diagnostics by exact device id
  - use it after a run to inspect the merged timeline without manual uploads

Current source of truth:

- the `simulatorDistributedJoinScenario()` spec runner result
- the merged simulator diagnostics timeline fetched by `just simulator-scenario-merge`
- the regular `TurboTests` unit suite

Current status:

- the merged simulator diagnostics path is now reliable
- the scenario itself currently fails, so treat that failure as a real product/integration bug rather than a tooling issue

Recommended testing strategy:

- express new distributed regressions as checked-in scenario JSON in [`scenarios/`](/Users/mau/Development/Turbo/scenarios)
- simulator scenarios for request/join/ready/transmit/disconnect and distributed state-machine bugs
- physical devices only for microphone permission, real Apple PushToTalk UI, backgrounding, lock screen, and actual audio

### Background PTT wake loop

Foreground signaling can still use the app websocket, but background receive needs the real PushToTalk wake contract:

- the app uploads the ephemeral PushToTalk token it receives while joined
- the backend uses that token to send a `pushtotalk` APNs push when a remote speaker starts
- the app's `incomingPushResult(...)` returns the active remote participant quickly
- PushToTalk then activates the audio session
- only after that activation should the app reconnect transport and start background playback

For fast iteration:

- simulator/unit loop:
  - keep reducer/domain tests for payload parsing and wake state
  - use `just simulator-ptt-push <channel_id>` to inject a simulator push payload into the running app
- backend payload loop:
  - use `just ptt-push-target <channel_id> <backend> <sender>` to inspect the canonical receiver token + wake payload for the sender's active transmit
  - the intended end state is direct APNs send from Unison, but hosted Unison Cloud is currently waiting on the upstream runtime rollout
  - until that runtime is deployed, the interim production sender should be the backend-triggered Cloudflare worker path described in [APNS_DELIVERY_PLAN.md](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md)
  - use `just ptt-apns-start <channel_id> <backend> <sender>` only for manual one-off APNs debugging once auth env vars are configured
  - use `just ptt-apns-worker <backend>` and `just ptt-apns-bridge <backend> @avery @blake` only as legacy/debug helpers
  - wake-send attempts are uploaded to the backend dev diagnostics surface, so `scripts/merged_diagnostics.py` includes them in the merged timeline as `[wake:apns] ...`
- device loop:
  - use physical devices for lock-screen and blue-pill validation
  - treat those runs as the source of truth for background wake behavior

The simulator path is useful for payload handling and app state transitions, but physical devices are still required for the real PushToTalk wake + audio-session behavior.

APNs sender env vars for deploys and local APNs debugging:

- `TURBO_APNS_TEAM_ID`
- `TURBO_APNS_KEY_ID`
- `TURBO_APNS_PRIVATE_KEY_PATH` or `TURBO_APNS_PRIVATE_KEY`
- optional `TURBO_APNS_USE_SANDBOX=1` for development entitlements
- optional `TURBO_APNS_BUNDLE_ID="com.rounded.Turbo"`

Recommended local setup uses `direnv` with an untracked `.envrc`:

```bash
export TURBO_APNS_TEAM_ID="YOUR_TEAM_ID"
export TURBO_APNS_KEY_ID="YOUR_KEY_ID"
export TURBO_APNS_PRIVATE_KEY_PATH="$HOME/.config/turbo/AuthKey_YOUR_KEY_ID.p8"
export TURBO_APNS_USE_SANDBOX=1
```

Notes:

- keep the `.p8` key outside the repo, for example under `~/.config/turbo/`
- `.envrc` is ignored by git in this repo, so local APNs secrets stay untracked
- after creating or editing `.envrc`, run `direnv allow`
- verify the variables are visible inside the repo with `direnv exec . env | rg '^TURBO_APNS'`
- `turbo.deploy` resolves `TURBO_APNS_PRIVATE_KEY_PATH` locally at deploy time and stores the PEM contents in cloud config as `TURBO_APNS_PRIVATE_KEY`
- deployed backend code should read `TURBO_APNS_PRIVATE_KEY`, not a filesystem path

### Diagnostics

The app now writes a persistent diagnostics log file automatically.

In-app:

- open the diagnostics sheet
- note the displayed log-file path
- use `Copy transcript` for a shareable plain-text snapshot

The diagnostics snapshot currently includes:

- current identity
- selected contact
- active channel id
- joined/transmitting/backend/websocket/media state
- status text
- backend status text

The app also auto-publishes diagnostics in debug builds after high-signal state transitions.

That means the normal loop is now:

1. reproduce once
2. tell the agent which side looked wrong
3. fetch the latest report or merged timeline from the backend

Manual upload remains available, but it is now a fallback rather than the primary workflow.

For simulator-driven distributed debugging, the normal loop is now:

1. `just simulator-scenario <name>`
2. `just simulator-scenario-merge`
3. fix the failing invariant or state transition

### Verification baseline

Most recent validated commands:

- `xcodebuild -project Turbo.xcodeproj -scheme BeepBeep -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- `xcodebuild -project Turbo.xcodeproj -scheme BeepBeep -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' -skip-testing:TurboUITests test CODE_SIGNING_ALLOWED=NO`

The unit suite currently covers:

- session coordinator invariants
- authoritative contact retention
- selected-session reconciliation rules
- primary action derivation
- self-check summary behavior
- simulator PTT join/transmit behavior
- a simulator-backed distributed smoke scenario

Important design decisions already agreed for v1:

- Use one shared backend implementation for local and cloud.
- Provide both `turbo.deploy` and `turbo.serveLocal`.
- Stub APNs locally by logging intended pushes.
- Use backend-owned direct channel IDs.
- Store ephemeral PTT tokens per `channel + user + device`.
- Route to one active receiving device per user per channel.
- Include real websocket signaling from the first backend milestone.
- Enforce at most one active transmitter per direct channel.
- Keep the media contract transport-agnostic so a relay-oriented transport can replace the prototype spike cleanly.

## Unison Cloud storage guidance

Backend storage changes in this repo should follow these rules:

- model `OrderedTable` keys from the queries we need to serve
- use compound keys and `rangeClosed.prefix` for scoped reads
- avoid whole-table scans with in-memory filtering on route hot paths
- add explicit secondary indexes or projections for additional access patterns
- keep primary rows and secondary projections in sync in the same transaction
- keep transactions small and focused
- update dev reset/cleanup flows whenever a new projection is added

Recent production debugging confirmed why this matters: a broad contact-summary path that scanned too much durable state was fine locally but unstable when deployed. The fix was not a hosting workaround; it was a better query-shaped schema and narrower reads.

## Local development workflow

Use this for fast iteration right now:

1. For backend-focused local checks, run `turbo.serveHttpLocal`
2. For full simulator ready/transmit scenario runs, run `turbo.serveLocal`
3. Use the printed named URL or the LAN equivalent, for example:
   - `http://localhost:8081/s/turbo`
   - `http://localhost:8090/s/turbo`
   - `http://192.168.1.161:8081/s/turbo`
4. Set `TurboBackendBaseURL` in [Turbo/Info.plist](/Users/mau/Development/Turbo/Turbo/Info.plist) to that base URL
5. Rebuild and reinstall the app

Important current split:

- `turbo.serveHttpLocal` is the reliable local path for backend-only and route-level checks, and is HTTP-only
- `turbo.serveLocal` is the websocket-capable path to use for simulator `request_accept_ready` / transmit scenario verification
- `turbo.deploy` remains the intended production/cloud path

Operational reminders:

- `Turbo/Info.plist` `TurboBackendBaseURL` should be `http://localhost:8081/s/turbo` for local HTTP route checks, `http://localhost:8090/s/turbo` for local websocket-backed simulator scenario work, `http://<your-mac-lan-ip>:8081/s/turbo` for a physical device against local HTTP, and `https://beepbeep.to` for the deployed backend.
- If no interactive `ucm` process is already using the local codebase, use `just deploy`.
- If you are already working inside a live `ucm` session, `just deploy` can block on the codebase lock; in that case run `turbo.deploy` from that existing MCP/UCM session instead.
- If you changed backend behavior in the local Unison codebase, that change will not be live on `https://beepbeep.to` until `turbo.deploy` has actually run.
- Dev user seeding is no longer automatic on app launch. If you want the canonical dev handles on a fresh backend, call `POST /v1/dev/seed` explicitly.
- Use `just reset` for the authenticated runtime reset and `just reset-all` for a full backend cleanup. `just seed` restores the canonical dev handles after a full reset. All default to `https://beepbeep.to` and can be overridden, e.g. `just reset http://localhost:8081/s/turbo @avery`.
- Use `just clean-scratch` to delete repo-root `scratch_*.u` files when temporary route experiments or one-off migration drafts have drifted away from the actual codebase state.
- Use `just route-probe` after changing backend route composition. It exercises the deployed HTTP surface end to end, including the routes most likely to regress when Unison route order changes:
  - dev reset/seed
  - diagnostics upload and latest-read routes
  - auth and device bootstrap
  - contact summaries
  - invite subroutes (`accept`, `decline`, `cancel`)
  - websocket registration held open during route assertions that depend on live connectivity
  - channel state/readiness/transmit routes
  - `ptt-push-target` during an actual active transmit
- Treat [`scripts/route_probe.py`](/Users/mau/Development/Turbo/scripts/route_probe.py) as part of the route contract. When you add, remove, rename, or reorder backend routes, update the probe in the same change and run it before trusting the deploy. Some routes only become valid inside a live websocket session or active transmit window, so the probe intentionally keeps those preconditions alive while it asserts them.
- The simulator is valid for distributed control-plane verification because the app uses the simulator PTT shim there. Real Apple PushToTalk UI, backgrounding, lock-screen behavior, and audio still require physical devices.
- If local UI behavior looks impossible, restart `turbo.serveHttpLocal` and clear backend runtime state via `POST /v1/dev/reset-state` before debugging further.

The backend now exposes `GET /v1/config`, and the app uses that to decide whether websocket signaling is supported by the current runtime.

Backend slice currently implemented in the Unison codebase:

- `GET /v1/config`
- `POST /v1/auth/session`
- `POST /v1/devices/register`
- `POST /v1/presence/heartbeat`
- `GET /v1/users/by-handle/:handle`
- `GET /v1/users/by-handle/:handle/presence`
- `GET /v1/contacts/summaries/:deviceId`
- `POST /v1/invites`
- `GET /v1/invites/incoming`
- `GET /v1/invites/outgoing`
- `POST /v1/invites/:inviteId/accept`
- `POST /v1/invites/:inviteId/decline`
- `POST /v1/invites/:inviteId/cancel`
- `POST /v1/channels/direct`
- `POST /v1/channels/:channelId/join`
- `POST /v1/channels/:channelId/leave`
- `GET /v1/channels/:channelId/state/:deviceId`
- `POST /v1/channels/:channelId/ephemeral-token`
- `POST /v1/channels/:channelId/begin-transmit`
- `POST /v1/channels/:channelId/end-transmit`
- `GET /v1/ws?deviceId=...` authenticated websocket signaling endpoint

Current websocket contract:

- dev auth still uses the `x-turbo-user-handle` header
- websocket handshake requires `deviceId` as a query parameter
- websocket text frames are flat JSON `SignalEnvelope` objects
- signaling payloads are forwarded opaquely as text
- clients still send `toUserId`
- the backend ignores client `toDeviceId` and rewrites it from active channel presence

Current transmit contract:

- `POST /v1/channels/:channelId/begin-transmit` now only requires the sender `deviceId`
- the backend resolves the peer user and their active receiving device server-side
- requests fail if the target user has no active device joined to that channel
- the active-session snapshot also exposes backend-derived `canTransmit`, so the client can treat `ready` as “press-to-talk is actually possible now”
