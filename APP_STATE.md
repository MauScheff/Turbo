# App State Guide

This document explains how the iOS app models a conversation, especially around Push-to-Talk (PTT) session setup, transmit, and teardown.

It is intentionally app-focused. For broader app architecture, read [SWIFT.md](/Users/mau/Development/Turbo/SWIFT.md). For simulator/device debugging loops, read [SWIFT_DEBUGGING.md](/Users/mau/Development/Turbo/SWIFT_DEBUGGING.md).

## Mental model

The app does not keep one giant "session state" enum. Instead it combines a few smaller state machines:

- backend sync state
  - authoritative control-plane truth from the backend: contact summaries, invites, and channel state
  - code: [Turbo/BackendSync.swift](/Users/mau/Development/Turbo/Turbo/BackendSync.swift), [Turbo/BackendSyncCoordinator.swift](/Users/mau/Development/Turbo/Turbo/BackendSyncCoordinator.swift)
- system PTT state
  - what Apple `PushToTalk` says is currently joined or restored on the device
  - code: [Turbo/PTTCoordinator.swift](/Users/mau/Development/Turbo/Turbo/PTTCoordinator.swift)
- transmit state
  - local press/hold/release lifecycle for "hold to talk"
  - code: [Turbo/TransmitCoordinator.swift](/Users/mau/Development/Turbo/Turbo/TransmitCoordinator.swift)
- selected-peer derived state
  - the user-visible state for the currently selected conversation
  - derived from backend truth, local session state, system session state, pending actions, and media state
  - code: [Turbo/ConversationDomain.swift](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift), [Turbo/SelectedPeerSession.swift](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)

That split is important:

- the backend owns shared truth like requests, channel readiness, and who may transmit
- Apple owns the device's live PTT channel lifecycle
- the app derives the selected conversation UI from those sources

## State layers

### 1. Base conversation state

`ConversationState` is the coarse backend-facing conversation status:

- `idle`
- `requested`
- `incoming-request`
- `waiting-for-peer`
- `ready`
- `self-transmitting`
- `peer-transmitting`

Code: [Turbo/ConversationDomain.swift](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift)

This is not the full UI state. It is a lower-level status that gets refined into a more specific selected-peer phase.

### 2. Relationship state

`PairRelationshipState` describes whether there is a request relationship between the two peers:

- `none`
- `outgoingRequest(requestCount:)`
- `incomingRequest(requestCount:)`
- `mutualRequest(requestCount:)`

`mutualRequest` matters for simultaneous-request conflicts. It means both sides have evidence of a request relationship at once, so the app must preserve both facts long enough to cancel the superseded outgoing request and accept the incoming one deterministically.

This is intentionally an ADT instead of separate `hasIncomingRequest` / `hasOutgoingRequest` booleans in the Swift domain layer. The backend may expose those booleans, but the app should convert them into a stronger internal representation immediately.

### 3. Selected-peer phase

`SelectedPeerPhase` is the main user-visible state machine for the selected conversation:

- `idle`
  - no active request or session
- `requested`
  - local user sent a request
- `incomingRequest`
  - peer wants to talk
- `peerReady`
  - peer already joined; local user can now finish the connection
- `wakeReady`
  - reserved "hold to talk is allowed now" state
- `waitingForPeer`
  - local/system/backend session alignment is still converging
- `localJoinFailed`
  - local PTT join failed in a way that blocks automatic restore
- `ready`
  - both sides are joined and hold-to-talk is available or nearly available
- `startingTransmit`
  - transmit was granted, but audio/media is still coming up
- `transmitting`
  - local user is talking
- `receiving`
  - peer is talking
- `blockedByOtherSession`
  - this device already has another active PTT session for a different contact
- `systemMismatch`
  - Apple restored or exposed a system PTT channel the app cannot map cleanly

Code: [Turbo/ConversationDomain.swift](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift), [Turbo/SelectedPeerSession.swift](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)

The app also keeps the richer `SelectedPeerDetail` alongside the coarse `SelectedPeerPhase`. That lets state-specific payloads live inside the corresponding case instead of being smeared across unrelated fields. Examples:

- `idle(isOnline:)`
- `requested(requestCount:)`
- `incomingRequest(requestCount:)`
- `waitingForPeer(reason:)`
- `localJoinFailed(recoveryMessage:)`
- `startingTransmit(mediaState:)`

### 4. System PTT state

`PTTCoordinator` tracks what the OS-level PTT system says:

- `none`
  - no known system session
- `active(contactID:, channelUUID:)`
  - the device is joined to a known contact's PTT channel
- `mismatched(channelUUID:)`
  - the device has a system channel, but the app cannot confidently map it to a contact

Important derived fields in `PTTSessionState`:

- `isJoined`
- `isTransmitting`
- `lastJoinFailure`

### 5. Transmit phase

`TransmitCoordinator` handles the local press-and-release lifecycle:

- `idle`
- `requesting(contactID:)`
  - user is pressing, app requested a transmit lease, waiting for grant
- `active(contactID:)`
  - transmit lease granted and local activation is in progress or active
- `stopping(contactID:)`
  - release or failure happened, app is ending transmit

This is intentionally separate from `SelectedPeerPhase`. A conversation can be `ready` while the transmit coordinator is still `idle`.

### 6. Media connection state

The app also tracks the media pipeline:

- `idle`
- `preparing`
- `connected`
- `failed(String)`
- `closed`

This is why the selected conversation can show `startingTransmit` before it shows `transmitting`: the control plane granted transmit, but audio is not fully connected yet.

Code: [Turbo/MediaSession.swift](/Users/mau/Development/Turbo/Turbo/MediaSession.swift)

### 7. Internal readiness ADTs

Inside the domain layer, the app now normalizes session readiness into stronger internal variants before deriving selected-peer state:

- `LocalSessionReadiness`
  - `none`
  - `partial`
  - `aligned`
- `BackendChannelReadiness`
  - `absent`
  - `peerOnly(peerDeviceConnected:, canTransmit:, status:)`
  - `selfOnly(canTransmit:, status:)`
  - `both(peerDeviceConnected:, canTransmit:, status:)`

These are internal domain ADTs, not UI-facing state. Their job is to stop repeated boolean recombination like:

- `systemSessionMatchesContact && isJoined && activeChannelID == contactID`
- `selfJoined && peerJoined && peerDeviceConnected`

That logic now gets normalized once and then pattern-matched in:

- effective-state derivation
- selected-peer projection
- session reconciliation

Before the domain layer sees backend summaries or channel state, the wire models are also normalized into stronger typed projections:

- `TurboRequestRelationship`
  - `none`
  - `outgoing(requestCount:)`
  - `incoming(requestCount:)`
  - `mutual(requestCount:)`
- `TurboSummaryBadgeStatus`
  - `offline`
  - `online`
  - `requested`
  - `incoming`
  - `idle`
  - `waitingForPeer`
  - `ready`
  - `transmitting`
  - `receiving`
  - `unknown(String)`
- `TurboConversationStatus`
  - `idle`
  - `requested`
  - `incomingRequest`
  - `connecting`
  - `waitingForPeer`
  - `ready`
  - `selfTransmitting(activeTransmitterUserId:)`
  - `peerTransmitting(activeTransmitterUserId:)`
  - `unknown(String)`
- `TurboChannelReadinessStatus`
  - `waitingForSelf`
  - `waitingForPeer`
  - `ready`
  - `selfTransmitting(activeTransmitterUserId:)`
  - `peerTransmitting(activeTransmitterUserId:)`
  - `unknown(String)`
- `TurboChannelMembership`
  - `absent`
  - `peerOnly(peerDeviceConnected:)`
  - `selfOnly`
  - `both(peerDeviceConnected:)`

That keeps the raw backend booleans and badge strings at the boundary instead of letting them leak into the rest of the Swift state machine logic.

The preferred backend contract is now the nested ADT-shaped wire projection:

- `requestRelationship`
  - `kind`
  - `requestCount`
- `membership`
  - `kind`
  - `peerDeviceConnected`
- `summaryStatus`
  - `kind`
  - backend summary routes currently emit `connecting` and `talking` on the wire; Swift normalizes those into the stronger internal `waitingForPeer` and `transmitting` views
  - `activeTransmitterUserId`
- `conversationStatus`
  - `kind`
  - `activeTransmitterUserId`
- `readiness`
  - `kind`
  - `activeTransmitterUserId`
- `audioReadiness`
  - `self.kind`
  - `peer.kind`
  - `peerTargetDeviceId`
- `wakeReadiness`
  - `self.kind`
  - `self.targetDeviceId`
  - `peer.kind`
  - `peer.targetDeviceId`

`TurboContactSummaryResponse`, `TurboChannelStateResponse`, and `TurboChannelReadinessResponse` now require the nested contract at decode time. The flat `badgeStatus`, `status`, `selfJoined`, `peerJoined`, `peerDeviceConnected`, and `activeTransmitterUserId` fields may still be present on the wire for observability or redundancy, but Swift no longer falls back to them when the nested ADTs are missing or malformed.

The important implementation rule is:

- `/contact-summaries` is the canonical backend input for relationship and badge projection
- `/channel-state` is the canonical backend input for membership projection
- `/readiness` is the canonical backend input for readiness and transmit authority
- `/readiness.wakeReadiness` is the canonical backend input for whether a disconnected peer is actually wake-capable for this channel

The selected-peer derivation now prefers `/readiness` directly instead of reconstructing readiness only from legacy join booleans.

## Background wake activation state

Background and lock-screen receive now track an explicit local wake-activation ADT, separate from backend `audioReadiness` and `wakeReadiness`:

- `signalBuffered`
  - websocket audio or transmit-start arrived before a confirmed incoming PTT push
- `awaitingSystemActivation`
  - the incoming PTT push was received and the app is now waiting for Apple PushToTalk to activate the audio session
- `fallbackDeferredUntilForeground`
  - wake audio exists, but the app is inactive/locked, so app-managed playback fallback must wait until foreground
- `appManagedFallback`
  - the app is active again and is draining buffered wake audio through the app-managed playback path
- `systemActivated`
  - PushToTalk activated the audio session and buffered wake audio can flush through the system-owned receive path

This is intentionally local device state. It explains the handoff between:

- backend/shared truth
- incoming push delivery
- Apple PushToTalk activation
- app-managed fallback

It should not be inferred from generic `waiting` alone.

## How the selected conversation is derived

`SelectedPeerSessionState` stores raw inputs for the selected contact:

- current selection
- relationship state
- base conversation state
- local joined channel info
- system PTT state
- pending session action
  - `connect(.requestingBackend(contactID:))`
  - `connect(.joiningLocal(contactID:))`
  - `leave(.explicit(contactID:))`
  - `leave(.reconciledTeardown(contactID:))`
- channel readiness snapshot from the backend
- media state

The reducer recomputes two important derived values after each event:

- `selectedPeerState`
- `reconciliationAction`

Code: [Turbo/SelectedPeerSession.swift](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)

The main reconciliation rules are:

- if the backend says the session is fully ready but the local/system session is not aligned, restore the local session
- if the backend says the session is gone but the local/system session is still hanging around, tear the local session down
- if Apple reports a mismatched system session, prefer teardown instead of pretending the conversation is usable

`PendingSessionAction` is intentionally an ADT instead of a loose status string. The important distinction is that "connect" and "leave" each carry state-specific payloads:

- backend request submission and local PTT join are different connection phases
- explicit user disconnect and reconciled teardown are different leave causes
- global explicit leave (`contactID: nil`) remains representable for "leave whatever session is active"

## Successful PTT session

This is the canonical happy path reflected in [scenarios/request_accept_ready.json](/Users/mau/Development/Turbo/scenarios/request_accept_ready.json) and [scenarios/foreground-ptt.json](/Users/mau/Development/Turbo/scenarios/foreground-ptt.json).

### Step 1. Both peers open each other

No session yet. Both sides typically start in:

- relationship: `none`
- selected peer phase: `idle`
- system PTT state: `none`
- transmit phase: `idle`

### Step 2. Initiator presses Connect

The initiator does not join a live audio session immediately. First the app creates or refreshes the backend-side request relationship.

Result:

- initiator: `requested`
- recipient: `incomingRequest`

### Step 3. Recipient presses Connect

On an incoming request, `Connect` means "accept and join". The recipient starts joining locally through Apple PTT and updating backend channel state.

Result during convergence:

- recipient: `waitingForPeer`, `isJoined = true`
- initiator: `peerReady`, `isJoined = false`

Why this split exists:

- the recipient already has a local/system session
- the initiator has proof from the backend that the peer is ready, but has not yet joined locally

### Step 4. Initiator presses Connect again

When the initiator sees `peerReady`, `Connect` means "finish the join on my side".

Once backend readiness, local join, and system-session alignment all match, both sides become:

- selected peer phase: `ready`
- `canTransmitNow = true`
- system PTT state: `active(...)`

The app only treats a conversation as truly ready when all of these line up:

- backend channel exists
- `selfJoined == true`
- `peerJoined == true`
- `peerDeviceConnected == true`
- local app says joined
- Apple PTT session matches the selected contact

If one of those lags, the UI stays in `waitingForPeer` instead of showing a false-ready state.

### Step 5. Initiator presses and holds talk

Now the transmit state machine starts:

1. `idle -> requesting(contactID:)`
2. backend grants transmit lease
3. `requesting -> active(contactID:)`
4. selected conversation becomes:
   - `startingTransmit` while media is still preparing
   - then `transmitting` once media is connected

At the same time, the peer's selected conversation becomes `receiving`.

### Foreground audio boundary note

For the current working foreground device path, `ready` does not mean "audio is already actively transmitting." It means:

- backend readiness is aligned
- local/system session alignment is correct
- the local device has finished its own interactive media prewarm
- the backend's authoritative `audioReadiness.peer` view says the peer device is `ready`, which means its receive path is prewarmed too

For background/lock-screen receive, `audioReadiness.peer` now has an important extra interpretation on the client side: a peer can be "not foreground-audio-ready" yet still be wake-capable. That should drive `wakeReady`, not the normal foreground `Waiting for <peer>'s audio...` gate.

When a locked receiver has already accepted the incoming push but Apple has not yet activated the PTT audio session, the selected conversation should not pretend it is already `receiving`. It should stay in an explicit waiting state such as:

- `Waiting for system audio activation...`
- `Wake received. Unlock to resume audio.`

Then, at the real first transmit boundary, the app still does one important sender-side step: it rebinds the capture engine and input tap against the actual live `PlayAndRecord` route before capturing microphone audio.

That detail matters. Earlier prototype behavior prewarmed the capture engine too early and then trusted that stale route during first transmit, which could produce a correct state-machine transition but no real audio on the wire.

So the current model is:

- prewarm enough locally that the device can honestly publish receiver-readiness to the backend
- only enable hold-to-talk once both devices are ready for immediate foreground audio
- still treat the actual transmit boundary as the moment when sender capture must bind to the live route
- treat `wakeReady` separately from foreground `ready`: it now requires backend `wakeReadiness.peer.kind == wake-capable`, not just a disconnected peer

This is why the selected conversation can be `ready`, yet the real "audio is now definitely capturable" moment still lives at transmit start rather than purely at join time.

On the receive side, the stable foreground behavior is:

- when the peer starts talking, the receiver should quickly move to `receiving`
- real audio chunks should arrive during that same transmit window
- playback should begin during that same transmit window
- after remote `transmit-stop`, the receiver may briefly return to `Preparing audio...` while the local interactive session is re-prewarmed
- then it should converge back to `ready`

So the foreground receive contract is not just "peer state says receiving." It is "receiving plus prompt playback plus clean return to ready."

For background and lock-screen receive, the app should not carry that idle foreground interactive prewarm across the lifecycle boundary. When the app resigns active or enters background, any idle app-managed interactive media session should be torn down so the subsequent wake path is driven by the PushToTalk-owned activation contract instead of a stale foreground `PlayAndRecord` shell.

### Step 6. Initiator releases talk

Transmit state moves:

1. `active -> stopping(contactID:)`
2. stop request completes
3. `stopping -> idle`

If the session remains healthy, both sides return to:

- selected peer phase: `ready`
- transmit phase: `idle`

### Step 7. Either side disconnects

Disconnect marks an explicit leave, tears down the local/system session, and converges backend state back to no active channel session.

End result:

- `isJoined = false`
- system PTT state: `none`
- transmit phase: `idle`
- selected peer phase usually falls back to `idle` or request-derived state

## A compact transition sketch

For the selected conversation, the main happy-path transitions are:

```text
idle
  -> requested
  -> incomingRequest

requested
  -> peerReady

incomingRequest
  -> waitingForPeer

peerReady
  -> waitingForPeer
  -> ready

waitingForPeer
  -> ready
  -> localJoinFailed

ready
  -> startingTransmit
  -> transmitting
  -> receiving
  -> waitingForPeer

startingTransmit
  -> transmitting
  -> ready

transmitting
  -> ready

receiving
  -> ready
```

This is a sketch, not an exhaustive formal graph. The source of truth for edge cases is the reducer code.

## Examples

### Example 1. Outgoing request that has not been accepted yet

Inputs:

- relationship: `outgoingRequest`
- no local join
- no system session

Derived UI:

- selected peer phase: `requested`
- status message: `Requested <name>`
- primary action: muted `Connect` or `Request Again`, depending on cooldown

### Example 2. Peer accepted before the local user joined

Inputs:

- backend channel says `peerJoined = true`
- local user not joined yet
- no active local system session

Derived UI:

- selected peer phase: `peerReady`
- status message: `<name> is ready to connect`
- primary action: enabled `Connect`

This is the "finish the join" state.

### Example 3. Session looks ready on the backend, but local system state is missing

Inputs:

- backend channel says both peers are joined
- local app or Apple PTT is not aligned

Derived UI:

- selected peer phase: `waitingForPeer`
- not `ready`

The app does this deliberately to avoid showing hold-to-talk before the local device is actually prepared.

### Example 3b. Session is ready, but transmit still needs the live route

Inputs:

- selected peer phase: `ready`
- backend readiness aligned
- local prewarm complete
- user presses hold-to-talk

Derived runtime behavior:

- selected peer phase: `startingTransmit`
- sender capture path is rebound to the live `PlayAndRecord` route
- only then does microphone capture produce outbound audio chunks

This preserves a useful distinction:

- `ready` means "the session is joined and locally prewarmed"
- `transmitting` means "the live transmit route is active and audio is actually flowing"

### Example 4. Local PTT join failed because the system channel limit was reached

Inputs:

- `lastJoinFailure.reason == .channelLimitReached`

Derived UI:

- selected peer phase: `localJoinFailed`
- status message: `Reconnect failed. End session and retry.`

Automatic restore is blocked in this case because retrying blindly would likely loop.

### Example 5. Another contact already owns the system PTT session

Inputs:

- `systemSessionState == .active(otherContact, ...)`

Derived UI:

- selected peer phase: `blockedByOtherSession`
- connect / hold-to-talk action disabled

The app refuses to pretend two conversations can own the same live Apple PTT session.

## Where to read next

- app-side architecture: [SWIFT.md](/Users/mau/Development/Turbo/SWIFT.md)
- reducer and derivation code: [Turbo/ConversationDomain.swift](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift)
- selected-session reducer: [Turbo/SelectedPeerSession.swift](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)
- system PTT reducer: [Turbo/PTTCoordinator.swift](/Users/mau/Development/Turbo/Turbo/PTTCoordinator.swift)
- transmit reducer: [Turbo/TransmitCoordinator.swift](/Users/mau/Development/Turbo/Turbo/TransmitCoordinator.swift)
- end-to-end simulator stories: [scenarios/README.md](/Users/mau/Development/Turbo/scenarios/README.md)
- reducer and regression tests: [TurboTests/TurboTests.swift](/Users/mau/Development/Turbo/TurboTests/TurboTests.swift)
