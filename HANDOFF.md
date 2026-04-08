# Turbo Handoff

This is the shortest path back into the project on the next session.

## Current state

- The iOS app and Unison backend are working well enough for prototype iteration.
- The backend is the control plane only.
- The WebRTC/CocoaPods spike has been removed from the app again.
- `Turbo/MediaSession.swift` now holds a transport-agnostic stub seam for the future relay implementation.
- The backend now exposes backend-derived contact summaries plus a stronger active-session snapshot.
- The client is now substantially decoupled from the original single-view-model design:
  - list pills come from backend contact summaries
  - selected conversation state comes from a dedicated selected-peer reducer/coordinator
  - transmit lifecycle comes from a dedicated reducer/coordinator
  - Apple PushToTalk lifecycle comes from a dedicated reducer/coordinator
  - backend sync has its own coordinator
  - backend command/orchestration has its own coordinator
  - backend self-check has its own coordinator/runner
  - token upload and restored descriptor naming now go through a small PTT system policy boundary
  - a client-side system PTT row still surfaces when iOS holds a live/restorable session
- Local fast iteration should use `turbo.serveHttpLocal`.
- Real PushToTalk validation still needs real APNs plus a real deploy.

## Most important files

- [README.md](/Users/mau/Development/Turbo/README.md)
- [AGENTS.md](/Users/mau/Development/Turbo/AGENTS.md)
- [Server/backend_architecture.md](/Users/mau/Development/Turbo/Server/backend_architecture.md)
- [Turbo/ContentView.swift](/Users/mau/Development/Turbo/Turbo/ContentView.swift)
- [Turbo/SelectedPeerSession.swift](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)
- [Turbo/TransmitCoordinator.swift](/Users/mau/Development/Turbo/Turbo/TransmitCoordinator.swift)
- [Turbo/PTTCoordinator.swift](/Users/mau/Development/Turbo/Turbo/PTTCoordinator.swift)
- [Turbo/PTTSystemClient.swift](/Users/mau/Development/Turbo/Turbo/PTTSystemClient.swift)
- [Turbo/PTTSystemPolicy.swift](/Users/mau/Development/Turbo/Turbo/PTTSystemPolicy.swift)
- [Turbo/BackendSyncCoordinator.swift](/Users/mau/Development/Turbo/Turbo/BackendSyncCoordinator.swift)
- [Turbo/BackendCommandCoordinator.swift](/Users/mau/Development/Turbo/Turbo/BackendCommandCoordinator.swift)
- [Turbo/DevSelfCheckCoordinator.swift](/Users/mau/Development/Turbo/Turbo/DevSelfCheckCoordinator.swift)
- [turbo_service_http.u](/Users/mau/Development/Turbo/turbo_service_http.u)
- [turbo_service_state.u](/Users/mau/Development/Turbo/turbo_service_state.u)
- [turbo_invites.u](/Users/mau/Development/Turbo/turbo_invites.u)
- [turbo_runtime_store.u](/Users/mau/Development/Turbo/turbo_runtime_store.u)
- [turbo_deploy_domain.u](/Users/mau/Development/Turbo/turbo_deploy_domain.u)

## Local workflow

Use this for day-to-day iteration:

1. In UCM, run `turbo.serveHttpLocal`
2. App base URL should point at:
   - `http://localhost:8081/s/turbo` in simulator-style contexts
   - `http://<your-mac-lan-ip>:8081/s/turbo` on physical devices
3. If local behavior looks stale after backend changes, restart the local backend process
4. If runtime state gets wedged, clear it with:

```bash
curl -X POST http://localhost:8081/s/turbo/v1/dev/reset-state
```

## Key operator notes

- `TurboBackendBaseURL` in `Turbo/Info.plist` is the switch that determines which backend the app uses:
  - `http://localhost:8081/s/turbo` for simulator/local HTTP work
  - `http://<your-mac-lan-ip>:8081/s/turbo` for a physical device against your local HTTP backend
  - `https://beepbeep.to` for the deployed backend
- `turbo.serveHttpLocal` is the stable local path and is intentionally HTTP-only. The app reads `/v1/config` and should keep websocket/media behavior off in that mode.
- `turbo.serveLocal` is still not the preferred local test path because local websocket exposure remains unreliable.
- Dev seeding is manual now. The app no longer calls `POST /v1/dev/seed` on startup; use it explicitly only when you want the canonical dev handles created on a fresh backend.
- The iOS simulator is only for control-plane and UI verification. `PTChannelManager` / PushToTalk instantiation failures in the simulator are expected and are not the bug to chase.
- For actual peer-to-peer talking tests, use two physical devices against `https://beepbeep.to`, start with both apps foregrounded, and only then test backgrounded or locked behavior.
- The dev reset endpoint requires the same dev auth headers as the app. For deployed reset checks, use `curl -i -X POST -H 'x-turbo-user-handle: @avery' -H 'Authorization: Bearer @avery' https://beepbeep.to/v1/dev/reset-state` and confirm a `200` JSON response before assuming stale state was cleared.
- Prefer `just reset` over ad hoc curl for runtime cleanup, and `just reset-all` when you need a truly blank backend. Override base and handle as needed, e.g. `just reset-all http://localhost:8081/s/turbo @avery`.
- Selected conversation truth should remain separate from list-summary decoration. Request/history state should stay `Requested` or `Incoming`, and `Waiting` should only appear while a real session transition is in progress.
- The selected-screen `System PTT Session` row should only appear when `systemSessionState != .none`. If it appears with no real session, that is a UI regression.
- `ContentView.swift` is still large, but it is no longer the system’s primary orchestration boundary. New work should prefer extending the dedicated coordinator/reducer files rather than re-centralizing logic in the view model.
- When interpreting diagnostics, prefer the newest log lines only. Old simulator runs may still contain cloud/websocket entries from previous launches and can be misleading.

## Important gotcha

Deleting the app does not clear the local Unison database.

If UI behavior feels impossible or outdated:

- restart `turbo.serveHttpLocal`
- call `POST /v1/dev/reset-state`
- rerun the app

This has bitten us repeatedly during invite and transmit iteration.

## Current product behavior

- Contact presence is backend-driven from `GET /v1/contacts/summaries/:deviceId`.
- Requests and requested rows are backend-driven.
- Re-requesting increments backend invite `requestCount`.
- The selected conversation now uses the stronger `GET /v1/channels/:channelId/state/:deviceId` snapshot, including backend-derived `status`, `canTransmit`, and `peerDeviceConnected`.
- `ready` is intended to mean “you can actually press talk now”, not merely “someone joined”.
- Backend join/leave, invite create/accept, and direct-channel resolution now flow through a dedicated backend command coordinator instead of ad hoc calls in `ContentView.swift`.
- Self-check runs through a dedicated coordinator/runner and applies structured contact/channel updates back into the app after the run completes.
- Ephemeral token upload and restored descriptor naming now flow through a small PTT system policy layer instead of being handled inline in `ContentView.swift`.
- Dev auth now accepts either:
  - `x-turbo-user-handle`
  - `Authorization: Bearer <handle>`
- Missing dev auth should return `401` JSON instead of surfacing as a server error.
- The app now shows:
  - `Active`
  - `Requests`
  - `Requested`
  - `Contacts`
- The `Active` section can also show a `System PTT Session` row with `End Session` when Apple still has a session the backend/UI would otherwise miss.
- The bottom control only appears when a contact is selected.
- Transmit is lease-based on the backend, so stuck talking should self-heal after expiry if renewals stop.

## Custom domain

`turbo.deploy` now:

- deploys the websocket-capable backend
- assigns stable service name `turbo`
- creates a custom domain mapping for `beepbeep.to`

The Unison side is wired in `turbo.deploy`.

Operationally, this still requires DNS to be set correctly for `beepbeep.to`.

## Real-device PushToTalk testing

Local HTTP mode is only for fast control-plane iteration.

For real framework testing on two physical devices, the next missing piece is:

- a real APNs PushToTalk sender
- a real deployed backend environment

The current backend already stores ephemeral channel tokens and has the control-plane pieces needed to support that next step.

## Highest-value next steps

1. Move into UI-focused cleanup:
   - split `ContentView.swift` presentation into smaller UI components
   - keep view code rendering derived state only
   - avoid moving orchestration back into the view layer
2. Design and implement the real relay-oriented media transport behind `MediaSession`.
3. Add the real APNs PushToTalk sender boundary.
4. Deploy with `turbo.deploy`.
5. Test two real devices with:
   - both foreground
   - receiver backgrounded
   - receiver locked
6. Tighten the single-screen UX further now that the structural seams are in place.

## Notes on codebase shape

- Some Unison scratch files contain newer definitions than older embedded copies elsewhere.
- Always typecheck and update from the scratch file you are actively editing.
- Prefer fresh scratch patches over editing large older scratch files unless you are intentionally refreshing a whole slice.
- For the iOS app, prefer these boundaries when continuing the refactor:
  - `SelectedPeerSession.swift`
  - `TransmitCoordinator.swift`
  - `PTTCoordinator.swift`
  - `PTTSystemClient.swift`
  - `PTTSystemPolicy.swift`
  - `BackendSyncCoordinator.swift`
  - `BackendCommandCoordinator.swift`
  - `DevSelfCheckCoordinator.swift`
- Verification path after app-side refactors:
  - `xcodebuild -project Turbo.xcodeproj -scheme BeepBeep -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' -skip-testing:TurboUITests test CODE_SIGNING_ALLOWED=NO`
- Current known non-code warning:
  - `Metadata extraction skipped. No AppIntents.framework dependency found.`
