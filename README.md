# Turbo

Turbo is an iOS Push-to-Talk prototype plus an in-progress Unison Cloud backend.

The app side currently proves out Apple's PushToTalk framework integration. The backend side is now a first control-plane slice for direct 1:1 channels, device registration, ephemeral PTT token handling, HTTP control endpoints, websocket signaling, and later APNs wakeups.

## Repository layout

- `Turbo/`: SwiftUI iOS prototype app.
- `Server/`: backend notes and architecture documentation.
- `AGENTS.md`: repo-specific instructions for AI/code agents working on the Unison codebase.
- `.agents/`: supporting Unison language and workflow notes.

## Current app status

The iOS app is still partly a local prototype, but it now has a real backend integration path:

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
- Reference project: `cuts`
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

1. Read `AGENTS.md`.
2. Read `Server/backend_architecture.md`.
3. Check the current Unison project context and installed libraries.
4. Treat the backend as control-plane-only unless the user explicitly changes scope.

### Current app refactor status

The iOS app is mid-refactor from a prototype-oriented screen into a production-style architecture.

What has already been extracted:

- `Turbo/ConversationDomain.swift`
  - conversation state types
  - contact identity helpers
  - primary action derivation
  - session reconciliation rules
- `Turbo/BackendClient.swift`
  - backend HTTP + websocket transport client
- `Turbo/BackendSync.swift`
  - backend-owned sync state for summaries, invites, channel state, and request cooldowns
- `Turbo/AppDiagnostics.swift`
  - structured diagnostics store
  - automatic persistent log file writing
- `Turbo/DevSelfCheck.swift`
  - app-owned self-check model for fast simulator/device verification

What is still intentionally not finished:

- `Turbo/ContentView.swift` still owns too much orchestration
- selected-peer relationship state and selected-session state are still partially mixed together
- contact summary badge state is still leaking into selected-screen behavior
- PushToTalk lifecycle and backend session lifecycle still need a clearer coordinator boundary

### Current known product issue

The main remaining app bug is a relationship/session state conflation:

- self-check can pass
- backend can be healthy
- but both peers can still render `Waiting`

The current diagnosis is:

- the app still uses backend relationship/list summary state (`badgeStatus`, invite history, connecting/requested) too directly for the selected peer screen
- that allows stale or historical relationship state to look like live session state
- the selected peer screen needs one explicit authoritative state model that separates:
  - contact/address-book state
  - relationship state (invite/request/accepted)
  - live selected-session state (connecting/connected/transmitting/receiving)

### Next structural increment

The next agent should implement a selected-peer authoritative state model.

Target direction:

1. Introduce a dedicated `SelectedPeerState` / `PairRelationshipState` domain type.
2. Compute selected-screen UI from that type only.
3. Stop using list badge state as selected-session truth.
4. Make `Waiting` only represent an active in-progress selected session transition.
5. Keep contact summaries as list decoration, not session authority.

### Fast iteration loop

Prefer this order:

1. Backend verification
   - `just prod-probe`
2. App verification in simulator
   - run the in-app self-check
   - inspect the persistent diagnostics log
3. Real device verification
   - only for PushToTalk / background / lock-screen / audio behavior

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

## Local development workflow

Use this for fast iteration right now:

1. In UCM, run `turbo.serveHttpLocal`
2. Use the printed named URL or the LAN equivalent, for example:
   - `http://localhost:8081/s/turbo`
   - `http://192.168.1.161:8081/s/turbo`
3. Set `TurboBackendBaseURL` in [Turbo/Info.plist](/Users/mau/Development/Turbo/Turbo/Info.plist) to that base URL
4. Rebuild and reinstall the app

Important current split:

- `turbo.serveHttpLocal` is the reliable local path and is HTTP-only
- `turbo.serveLocal` is intended to mirror the websocket-capable cloud path, but its local websocket exposure is still broken
- `turbo.deploy` remains the intended production/cloud path

Operational reminders:

- `Turbo/Info.plist` `TurboBackendBaseURL` should be `http://localhost:8081/s/turbo` for simulator/local HTTP work, `http://<your-mac-lan-ip>:8081/s/turbo` for a physical device against local HTTP, and `https://beepbeep.to` for the deployed backend.
- Dev user seeding is no longer automatic on app launch. If you want the canonical dev handles on a fresh backend, call `POST /v1/dev/seed` explicitly.
- Use `just reset` for the authenticated runtime reset, or `just reset-all` for a blank-world reset that also deletes users, devices, and channels. Both default to `https://beepbeep.to` and can be overridden, e.g. `just reset-all http://localhost:8081/s/turbo @avery`.
- The simulator is valid for control-plane/UI verification, but PushToTalk instantiation is expected to fail there. Do not treat simulator PTT failures as product regressions.
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

## Documentation and testing expectations

For core Unison code in this repo:

- add `.doc` definitions for exported or user-facing functions and important types
- include example tests and property-based tests for core pure logic where appropriate
- use the built-in Unison testing style, not ad hoc checks
