# Ready-To-Send Diagram Prompts

Each prompt below is standalone and ready to paste directly into an image / diagram / poster model.

Global rendering rule for every prompt:

- Return exactly one polished diagram image.
- Do not return markdown, Mermaid, PlantUML, ASCII, code, bullets, captions, or prose outside the image.
- Put the title, legend, labels, and short annotations inside the image.
- Use a clean engineering-poster style with restrained colors:
  - blue for iOS app
  - amber for Unison backend
  - green for test / diagnostics / simulator tooling
  - gray for external systems

## Prompt 1: Big Picture Poster

```text
Create a large-format engineering poster titled "BeepBeep Big Picture".

Return exactly one polished diagram image and nothing else.

Turbo is an iOS Push-to-Talk app with:
- a Swift client in `Turbo/`
- a Unison control-plane backend whose source of truth lives in Unison project `turbo/main`
- simulator-scenario and diagnostics tooling in `scenarios/`, `scripts/`, and `justfile`

Core architectural truth:
- the backend is the control plane, not the media relay
- the backend owns shared truth: users, devices, direct channels, invite/request state, channel membership, readiness, active transmitter state, websocket signaling, wake targeting, diagnostics surfaces
- the app owns device-local behavior: SwiftUI UI, local reducers/coordinators, Apple PushToTalk integration, audio/media session behavior, local diagnostics capture
- simulator scenarios plus merged diagnostics are the primary repeatable proof loop for distributed app/backend behavior

The poster should have 6 panels:

Panel 1: Repo map
- `Turbo/` Swift app
- `TurboTests/` and `TurboUITests/`
- `scenarios/`
- `scripts/`
- `Server/`
- root docs like `README.md`, `TOOLING.md`, `SWIFT.md`, `APP_STATE.md`, `BACKEND.md`, `STATE_MACHINE_TESTING.md`
- show that checked-in scratch `.u` files are scratch artifacts, while backend source of truth is Unison project `turbo/main`

Panel 2: App architecture
- `TurboApp.swift` launches `ContentView(viewModel: .shared)`
- `PTTViewModel` is the central orchestration object, but not the owner of all truth
- important Swift files:
  - `Turbo/PTTViewModel.swift`
  - `Turbo/ConversationDomain.swift`
  - `Turbo/SelectedPeerSession.swift`
  - `Turbo/BackendClient.swift`
  - `Turbo/BackendSyncCoordinator.swift`
  - `Turbo/BackendCommandCoordinator.swift`
  - `Turbo/ControlPlaneCoordinator.swift`
  - `Turbo/PTTCoordinator.swift`
  - `Turbo/TransmitCoordinator.swift`
  - `Turbo/TransmitExecutionCoordinator.swift`
  - `Turbo/ReceiveExecutionCoordinator.swift`
  - `Turbo/WakeExecutionCoordinator.swift`
  - `Turbo/PTTSystemClient.swift`
  - `Turbo/MediaSession.swift`
  - `Turbo/AppDiagnostics.swift`

Panel 3: Backend architecture
- Unison modules:
  - `turbo.domain`
  - `turbo.store.users`
  - `turbo.store.devices`
  - `turbo.store.channels`
  - `turbo.store.invites`
  - `turbo.store.memberships`
  - `turbo.store.presence`
  - `turbo.store.sessions`
  - `turbo.store.sockets`
  - `turbo.store.tokens`
  - `turbo.store.runtime`
  - `turbo.store.receiverAudioReadiness`
  - `turbo.store.wakeJobs`
  - `turbo.store.devDiagnostics`
  - `turbo.store.devInvariantEvents`
  - `turbo.store.devWakeEvents`
  - `turbo.service.contacts`
  - `turbo.service.invites`
  - `turbo.service.channels`
  - `turbo.service.devices`
  - `turbo.service.presence`
  - `turbo.service.dev`
  - `turbo.service.ws`
  - `turbo.service.http`
  - `turbo.service.web`
  - entrypoints `turbo.serveLocal` and `turbo.deploy`

Panel 4: Main user flow
- open peer
- ensure direct channel
- create or reconcile invite/request
- join channel
- local PTT join
- backend readiness becomes ready
- hold to talk
- begin / renew / end transmit

Panel 5: Wake path
- receiver uploads ephemeral PTT token
- backend stores token
- backend resolves transmit target
- target can be a connected audio-ready device or a wake-capable token-backed device
- wake can go through current Cloudflare worker path
- long-term intended architecture is backend direct-to-APNs

Panel 6: Proof loop
- checked-in scenario JSON in `scenarios/`
- run via `scripts/run_simulator_scenarios.py`
- diagnostics upload via app + backend dev routes
- merge timeline via `scripts/merged_diagnostics.py`
- assert invariants and regressions

Add a footer band titled "Authority Boundaries" with 3 columns:
- backend owns shared truth
- Apple PushToTalk owns system channel lifecycle on device
- app derives selected conversation UI from backend truth + system PTT state + local execution state
```

## Prompt 2: Repository Map

```text
Create a repository map diagram titled "Turbo Repository Map".

Return exactly one polished diagram image and nothing else.

Represent these repo areas and label what each one is for:

- `Turbo/`
  - SwiftUI iOS client
  - app state, reducers, coordinators, backend client, PushToTalk integration, media, diagnostics
- `TurboTests/`
  - Swift tests including simulator scenario tests and domain logic tests
- `TurboUITests/`
  - UI-level tests
- `scenarios/`
  - checked-in distributed scenario JSON files such as:
    - `request_accept_ready.json`
    - `foreground-ptt.json`
    - `background_wake_refresh_stability.json`
    - `duplicate_transmit_stop_delivery_recovers.json`
    - `restart_ready_session_recovery.json`
- `scripts/`
  - scenario runner, merged diagnostics, probes, APNs helpers
  - important scripts:
    - `run_simulator_scenarios.py`
    - `merged_diagnostics.py`
    - `route_probe.py`
    - `postdeploy_check.py`
    - `send_ptt_apns.py`
    - `ptt_apns_worker.py`
    - `ptt_apns_bridge.py`
- `Server/`
  - backend architecture docs
- `cloudflare/apns-worker/`
  - interim APNs worker path
- root docs
  - `README.md`
  - `AGENTS.md`
  - `TOOLING.md`
  - `SWIFT.md`
  - `APP_STATE.md`
  - `BACKEND.md`
  - `STATE_MACHINE_TESTING.md`
  - `INVARIANTS.md`
- `justfile`
  - operational command entrypoint

Show a special callout that says:
- "Important: backend source of truth is Unison project `turbo/main`, not the checked-in scratch `.u` files."

Add a small side panel titled "Start Here":
- for app work: `SWIFT.md`, `APP_STATE.md`, `Turbo/`
- for backend work: `BACKEND.md`, `TOOLING.md`, Unison `turbo/main`
- for distributed bugs: `STATE_MACHINE_TESTING.md`, `scenarios/`, `scripts/merged_diagnostics.py`
```

## Prompt 3: Frontend Architecture

```text
Create a layered architecture diagram titled "Turbo iOS App Architecture".

Return exactly one polished diagram image and nothing else.

The app is a SwiftUI client in `Turbo/`.

Top-level boot:
- `TurboApp.swift` launches `ContentView(viewModel: .shared)`
- `PTTViewModel.shared` is the main app-level orchestrator

Draw these layers from top to bottom:

Layer 1: UI
- `ContentView.swift`
- `ContentViewSections.swift`
- `ContentViewTopChrome.swift`
- `TalkRequestSurface.swift`
- `CallPrototypeView.swift`
- `AudioRoutePickerButton.swift`

Layer 2: App orchestration
- `PTTViewModel.swift`
- note that many behaviors are split across extension files:
  - `PTTViewModel+BackendLifecycle.swift`
  - `PTTViewModel+BackendCommands.swift`
  - `PTTViewModel+BackendSync.swift`
  - `PTTViewModel+ControlPlane.swift`
  - `PTTViewModel+Selection.swift`
  - `PTTViewModel+TalkRequests.swift`
  - `PTTViewModel+Transmit.swift`
  - `PTTViewModel+PTTActions.swift`
  - `PTTViewModel+PTTCallbacks.swift`
  - `PTTViewModel+Notifications.swift`

Layer 3: reducers / coordinators / state machines
- `BackendSyncCoordinator`
- `BackendCommandCoordinator`
- `ControlPlaneCoordinator`
- `PTTCoordinator`
- `TransmitCoordinator`
- `TransmitExecutionCoordinator`
- `ReceiveExecutionCoordinator`
- `WakeExecutionCoordinator`
- `SelectedPeerSession` / `SelectedPeerReducer`
- `ConversationDomain`

Layer 4: integration clients and runtime boundaries
- `BackendClient.swift` for HTTP + websocket control-plane transport
- `PTTSystemClient.swift` for real-device Apple PushToTalk and simulator shim behavior
- `MediaSession.swift` and `PCMWebSocketMediaSession.swift` for local media behavior

Layer 5: diagnostics and developer tooling
- `AppDiagnostics.swift`
- `ContentViewDiagnostics.swift`
- `DevSelfCheck.swift`
- `DevSelfCheckCoordinator.swift`

Make these architectural truths visually explicit:
- UI is thin and should render derived state
- `PTTViewModel` coordinates, but business truth lives in typed state machines and backend-derived models
- backend integration, system PTT integration, and media integration are separate seams
- diagnostics are first-class, not an afterthought
```

## Prompt 4: Frontend State Machines

```text
Create a state-machine composition diagram titled "Turbo Frontend State Machines".

Return exactly one polished diagram image and nothing else.

Show that the app does not use one giant session enum. It composes several smaller state machines and derived projections.

Main state machines and exact states:

1. `ConversationState`
- `idle`
- `requested`
- `incoming-request`
- `waiting-for-peer`
- `ready`
- `self-transmitting`
- `peer-transmitting`

2. `PairRelationshipState`
- `none`
- `outgoingRequest(requestCount:)`
- `incomingRequest(requestCount:)`
- `mutualRequest(requestCount:)`

3. `SelectedPeerPhase`
- `idle`
- `requested`
- `incomingRequest`
- `peerReady`
- `wakeReady`
- `waitingForPeer`
- `localJoinFailed`
- `ready`
- `startingTransmit`
- `transmitting`
- `receiving`
- `blockedByOtherSession`
- `systemMismatch`

4. `SelectedPeerWaitingReason`
- `pendingJoin`
- `disconnecting`
- `localSessionTransition`
- `releaseRequiredAfterInterruptedTransmit`
- `localAudioPrewarm`
- `systemWakeActivation`
- `wakePlaybackDeferredUntilForeground`
- `remoteAudioPrewarm`
- `remoteWakeUnavailable`
- `backendSessionTransition`
- `peerReadyToConnect`

5. `LocalTransmitProjection`
- `idle`
- `stopping`
- `releaseRequired`
- `starting(requestingLease | awaitingSystemTransmit | awaitingAudioSession | awaitingAudioConnection)`
- `transmitting`

6. `SystemPTTSessionState`
- `none`
- `active(contactID, channelUUID)`
- `mismatched(channelUUID)`

7. `PTTSessionState` important fields
- `systemChannelUUID`
- `activeContactID`
- `isJoined`
- `isTransmitting`
- `lastError`
- `lastJoinFailure`

8. `TransmitPhase`
- `idle`
- `requesting(contactID)`
- `active(contactID)`
- `stopping(contactID)`

9. `MediaConnectionState`
- `idle`
- `preparing`
- `connected`
- `failed(String)`
- `closed`

10. `WakeReceiveState`
- `idle`
- `signalBuffered`
- `awaitingSystemActivation`
- `systemActivationTimedOutWaitingForForeground`
- `systemActivationInterruptedByTransmitEnd`
- `appManagedFallback`
- `systemActivated`

11. `IncomingWakeActivationState`
- `signalBuffered`
- `awaitingSystemActivation`
- `systemActivationTimedOutWaitingForForeground`
- `systemActivationInterruptedByTransmitEnd`
- `appManagedFallback`
- `systemActivated`

12. `ReceiveExecutionSessionState`
- tracks remote receive activity per contact
- activity sources: `incomingPush`, `transmitStartSignal`, `audioChunk`
- timeout phases: `awaitingFirstAudioChunk`, `drainingAudio`

13. `ControlPlaneSessionState`
- receiver audio readiness states per contact
- deferred publish on websocket reconnect
- post-wake repair contact set

Also show backend-derived wire-model ADTs that enter the frontend:
- `TurboRequestRelationship`
- `TurboChannelMembership`
- `TurboSummaryBadgeStatus`
- `TurboConversationStatus`
- `TurboChannelReadinessStatus`
- `TurboWakeCapabilityStatus`

The diagram should show dataflow:
- backend summaries and readiness feed derived selected-peer state
- Apple PushToTalk callbacks feed `PTTCoordinator`
- transmit lifecycle feeds `TransmitCoordinator` and `TransmitExecutionCoordinator`
- wake path feeds `WakeExecutionCoordinator`
- selected conversation UI is derived from all of the above, not stored as a single mutable source of truth
```

## Prompt 5: Backend Architecture

```text
Create a backend architecture diagram titled "Turbo Unison Control Plane".

Return exactly one polished diagram image and nothing else.

Turbo backend source of truth lives in Unison project `turbo/main`.

This backend is a control plane and signaling service, not a media relay.

Show these layers:

Layer 1: domain
- `turbo.domain`
- important domain concepts:
  - `User`
  - `Device`
  - `ChannelId`
  - `DirectChannel`
  - `ChannelMembership`
  - `RequestRelationship`
  - `ChannelMembershipView`
  - `ChannelStateStatus`
  - `ChannelReadinessStatus`
  - `ChannelAudioReadiness`
  - `WakeCapabilityStatus`
  - `ChannelWakeReadiness`
  - `Invite`
  - `EphemeralToken`
  - `TransmitState`
  - `SignalEnvelope`
  - `SignalKind`
  - `ReceiverAudioReadinessRecord`
  - `WakeJob`
  - dev diagnostics / invariant / wake event types

Layer 2: stores
- `turbo.store.users`
- `turbo.store.devices`
- `turbo.store.channels`
- `turbo.store.memberships`
- `turbo.store.invites`
- `turbo.store.presence`
- `turbo.store.sessions`
- `turbo.store.sockets`
- `turbo.store.tokens`
- `turbo.store.runtime`
- `turbo.store.receiverAudioReadiness`
- `turbo.store.wakeJobs`
- `turbo.store.devDiagnostics`
- `turbo.store.devInvariantEvents`
- `turbo.store.devWakeEvents`

Layer 3: services
- `turbo.service.auth`
- `turbo.service.users`
- `turbo.service.devices`
- `turbo.service.presence`
- `turbo.service.contacts`
- `turbo.service.invites`
- `turbo.service.channels`
- `turbo.service.dev`
- `turbo.service.ws`
- `turbo.service.http`
- `turbo.service.web`

Layer 4: entrypoints
- `turbo.serveLocal`
- `turbo.deploy`

Show important subsystem responsibilities:
- direct channel creation by sorted user pair
- membership checks
- invite/request lifecycle
- presence and connected-session freshness
- websocket inbox / socket routing
- ephemeral PTT token storage
- runtime active transmitter lease
- receiver audio readiness projection
- wake job queue and wake event reporting
- diagnostics and invariant event reporting

Add a bold architectural note inside the image:
- "Unison decides who can talk to whom, which direct channel exists, who is allowed to transmit, which device is targeted, and what control-plane truth is visible. iOS devices own media transport."
```

## Prompt 6: Backend Data Model And Route Map

```text
Create a combined data-model and route map titled "Turbo Backend Data + Routes".

Return exactly one polished diagram image and nothing else.

Show a left-to-right diagram.

Left side: important data and projections
- users
- devices
- direct channels
- memberships
- invites
- presence
- sessions
- sockets
- ephemeral tokens
- runtime transmit state
- receiver audio readiness
- wake jobs
- dev diagnostics
- dev invariant events
- dev wake events

Middle: service modules
- `turbo.service.auth`
- `turbo.service.users`
- `turbo.service.devices`
- `turbo.service.presence`
- `turbo.service.contacts`
- `turbo.service.invites`
- `turbo.service.channels`
- `turbo.service.ws`
- `turbo.service.dev`

Right side: actual route families used by the app and tooling
- `GET /v1/config`
- `POST /v1/auth/session`
- `GET /v1/users/by-handle/{handle}`
- `GET /v1/users/presence/{handle}`
- `POST /v1/devices/register`
- `POST /v1/presence/heartbeat`
- `POST /v1/presence/offline`
- `GET /v1/contacts/summaries/{deviceId}`
- `GET /v1/invites/incoming`
- `GET /v1/invites/outgoing`
- `POST /v1/invites`
- `POST /v1/invites/{inviteId}/accept`
- `POST /v1/invites/{inviteId}/decline`
- `POST /v1/invites/{inviteId}/cancel`
- `POST /v1/channels/direct`
- `POST /v1/channels/{channelId}/join`
- `POST /v1/channels/{channelId}/leave`
- `GET /v1/channels/{channelId}/state/{deviceId}`
- `GET /v1/channels/{channelId}/readiness/{deviceId}`
- `POST /v1/channels/{channelId}/ephemeral-token`
- `POST /v1/channels/{channelId}/begin-transmit`
- `POST /v1/channels/{channelId}/renew-transmit`
- `POST /v1/channels/{channelId}/end-transmit`
- `GET /v1/channels/{channelId}/ptt-push-target`
- `GET /v1/ws?deviceId=...`
- dev routes for seed, reset, diagnostics latest/upload, invariant events, wake events, deploy stamp, APNs config/probe

Add callouts for the key backend projections consumed by Swift:
- contact summaries carry:
  - `requestRelationship`
  - `membership`
  - `summaryStatus`
- channel state carries:
  - `membership`
  - `requestRelationship`
  - `conversationStatus`
- readiness carries:
  - `readiness`
  - `audioReadiness`
  - `wakeReadiness`
  - `activeTransmitterUserId`
  - `activeTransmitExpiresAt`

Make these authoritative seams visually obvious:
- `/v1/contacts/summaries/{deviceId}` is the canonical relationship / badge projection
- `/v1/channels/{channelId}/state/{deviceId}` is the canonical membership projection
- `/v1/channels/{channelId}/readiness/{deviceId}` is the canonical readiness / transmit / wake-capability projection
```

## Prompt 7: Request / Join / Ready Sequence

```text
Create a sequence diagram titled "Turbo Request -> Join -> Ready".

Return exactly one polished diagram image and nothing else.

Use these actors:
- user
- `ContentView`
- `PTTViewModel`
- `BackendCommandCoordinator`
- `BackendSyncCoordinator`
- `TurboBackendClient`
- backend services
- backend stores
- receiver app
- receiver backend sync
- Apple PushToTalk system on both devices

Sequence to show:
1. User selects a peer.
2. `BackendCommandCoordinator` opens or joins the peer.
3. App calls `POST /v1/channels/direct` to ensure a stable backend-owned direct channel.
4. App creates or reconciles invite state through `POST /v1/invites` or existing incoming/outgoing invite routes.
5. Backend stores direct channel and invite/request truth.
6. `BackendSyncCoordinator` refreshes:
   - `GET /v1/contacts/summaries/{deviceId}`
   - `GET /v1/invites/incoming`
   - `GET /v1/invites/outgoing`
   - `GET /v1/channels/{channelId}/state/{deviceId}`
   - `GET /v1/channels/{channelId}/readiness/{deviceId}`
7. Initiator and receiver converge on channel membership.
8. Local device joins Apple PushToTalk channel.
9. Backend readiness becomes ready when both sides have active channel/device state.
10. Selected peer UI becomes `ready`.

Include these domain/state labels in the sequence:
- relationship can be `none`, `outgoingRequest`, `incomingRequest`, or `mutualRequest`
- selected peer can be `requested`, `incomingRequest`, `peerReady`, `waitingForPeer`, or `ready`
- backend membership can be `absent`, `self-only`, `peer-only`, or `both`
- backend readiness can be `inactive`, `waiting-for-self`, `waiting-for-peer`, `ready`, `self-transmitting`, or `peer-transmitting`

Make it visually clear which transitions are:
- backend-authoritative
- Apple-system-authoritative
- frontend-derived UI projections
```

## Prompt 8: Transmit And Signaling Sequence

```text
Create a sequence diagram titled "Turbo Hold To Talk: Transmit + Signaling".

Return exactly one polished diagram image and nothing else.

Use these actors:
- user finger press
- `PTTViewModel`
- `TransmitCoordinator`
- `TransmitExecutionCoordinator`
- `TurboBackendClient`
- backend `turbo.service.channels.beginTransmit`
- backend `turbo.store.runtime.resolveTransmitTarget`
- backend runtime transmit store
- backend websocket service `turbo.service.ws`
- receiver device
- receiver `ReceiveExecutionCoordinator`
- `MediaSession`
- Apple PushToTalk system

Concrete facts to encode:
- `TransmitPhase` is `idle`, `requesting(contactID)`, `active(contactID)`, `stopping(contactID)`
- `begin-transmit` is `POST /v1/channels/{channelId}/begin-transmit`
- backend checks membership first
- backend resolves target device through `turbo.store.runtime.resolveTransmitTarget`
- target resolution rule:
  - if peer has a connected receiving device and that device is audio-ready, target that device
  - otherwise if the peer has a wake-capable ephemeral token, target that token-backed device
  - otherwise fail with no connected or wake-capable receiving device
- if `begin-transmit` succeeds, backend stores `TransmitState` with sender and target device info
- backend can send wake handling as part of begin-transmit
- websocket route is `GET /v1/ws?deviceId=...`
- `SignalKind` includes:
  - `offer`
  - `answer`
  - `ice-candidate`
  - `hangup`
  - `transmit-start`
  - `transmit-stop`
  - `audio-chunk`
  - `receiver-ready`
  - `receiver-not-ready`

Show this sequence:
1. user presses and holds
2. app enters requesting state
3. backend grants or rejects transmit lease
4. local system transmit begins
5. media session warms up
6. receiver gets `transmit-start` / buffered audio / other signaling
7. transmit is renewed while held
8. user releases
9. app calls `end-transmit`
10. backend clears runtime transmit state
11. receiver sees `transmit-stop`

Include resilience callouts:
- duplicate delivery and retries must converge safely
- stop dominates stale late-arriving events
- websocket disconnect can force transmit stop
```

## Prompt 9: Wake / APNs / Background Receive Sequence

```text
Create a sequence diagram titled "Turbo Wake Path And Background Receive".

Return exactly one polished diagram image and nothing else.

Use these actors:
- sender app
- sender backend client
- backend channel service
- backend token store
- backend runtime transmit target resolution
- backend wake job / wake event path
- Cloudflare APNs worker
- APNs
- receiver device
- Apple PushToTalk system
- `WakeExecutionCoordinator`
- `PTTCoordinator`
- `ReceiveExecutionCoordinator`
- `MediaSession`

Concrete facts to encode:
- receiver devices upload ephemeral PTT tokens through `POST /v1/channels/{channelId}/ephemeral-token`
- backend stores tokens in `turbo.store.tokens`
- readiness route returns both:
  - `audioReadiness`
  - `wakeReadiness`
- `wakeReadiness` exposes self and peer wake capability
- wake capability is either:
  - `unavailable`
  - `wake-capable(targetDeviceId)`
- current interim wake sending can use Cloudflare worker path in `cloudflare/apns-worker/`
- long-term intended design is backend direct APNs send from Unison
- `WakeReceiveState` can be:
  - `signalBuffered`
  - `awaitingSystemActivation`
  - `systemActivationTimedOutWaitingForForeground`
  - `systemActivationInterruptedByTransmitEnd`
  - `appManagedFallback`
  - `systemActivated`
- `TurboPTTPushPayload` carries:
  - event
  - channelId
  - activeSpeaker
  - senderUserId
  - senderDeviceId
- push event kinds include:
  - `transmit-start`
  - `leave-channel`

Sequence to show:
1. receiver publishes ephemeral token
2. sender begins transmit
3. backend chooses connected audio-ready target or wake-capable token target
4. backend triggers wake handling
5. APNs wakes the receiver device
6. receiver buffers signal/audio until system activation
7. device either reaches system-activated playback or app-managed fallback
8. receiver later publishes readiness repair / receiver-ready signal

Add a visual note:
- "Wake capability is backend-projected truth. The app should not infer wake readiness only from disconnected presence."
```

## Prompt 10: Diagnostics, Invariants, And Simulator Proof Loop

```text
Create a pipeline diagram titled "Turbo Proof Loop: Scenarios + Diagnostics + Invariants".

Return exactly one polished diagram image and nothing else.

Show the canonical engineering loop for distributed bugs.

Artifacts and tools:
- scenario JSON files in `scenarios/`
- simulator runner `scripts/run_simulator_scenarios.py`
- merged timeline tool `scripts/merged_diagnostics.py`
- `just simulator-scenario`
- `just simulator-scenario-local`
- `just simulator-scenario-merge`
- `just simulator-scenario-merge-strict`
- `just route-probe`
- `just postdeploy-check`

Important scenarios to name inside the image:
- `request_accept_ready.json`
- `foreground-ptt.json`
- `background_wake_refresh_stability.json`
- `duplicate_transmit_stop_delivery_recovers.json`
- `restart_ready_session_recovery.json`
- `delayed_accept_refresh_race.json`

Diagnostics architecture:
- debug app builds capture structured diagnostics
- app publishes diagnostics to backend dev routes
- backend stores exact-device diagnostics
- merged diagnostics reconstruct pair timelines from two devices
- invariant events are stored and surfaced as first-class debugging artifacts

Show this pipeline:
1. reproduce or codify a behavior as scenario JSON
2. run simulator scenario
3. app publishes diagnostics artifacts
4. backend stores diagnostics and invariant events
5. merged diagnostics creates one pair timeline
6. engineer finds contradiction at the authoritative seam
7. code fix
8. scenario becomes regression proof

Add a side panel "Preferred Proof Order":
1. scenario + automated tests
2. merged diagnostics
3. local reproducible tooling
4. physical devices only for Apple/PTT/audio-specific behavior
```

## Prompt 11: Runtime And Deploy Topology

```text
Create a topology diagram titled "Turbo Runtime Topology: Local, Hosted, Device, Deploy".

Return exactly one polished diagram image and nothing else.

Show these environments:
- iOS simulator
- physical iPhone
- local backend via `turbo.serveLocal`
- deployed backend via `turbo.deploy`
- Cloudflare APNs worker
- APNs
- Unison Cloud runtime

Show the important commands as arrows or operational labels:
- `just serve-local`
- `just deploy`
- `just route-probe`
- `just postdeploy-check`
- `just simulator-scenario`
- `just simulator-scenario-local`
- `just simulator-scenario-merge`
- `just ptt-push-target`

Important facts:
- `just serve-local` runs local backend entrypoint `turbo.serveLocal`
- `just deploy` runs deployed backend entrypoint `turbo.deploy`
- simulator scenario loop is the preferred proof path for distributed control-plane behavior
- physical device checks are still required for:
  - real Apple PushToTalk UI
  - microphone permission
  - backgrounding and lock-screen behavior
  - real audio capture/playback behavior
- local backend and hosted backend share the same conceptual backend implementation shape
- wake/APNs testing may involve Cloudflare worker path plus Apple systems

Add a bottom strip titled "What each environment is for":
- simulator: deterministic control-plane proof
- local backend: local route and websocket iteration
- hosted backend: deployed integration verification
- physical device: Apple-specific behavior only
```
