# Turbo Backend Architecture

Status: active reference.
Canonical home for: agreed v1 backend architecture, durable/runtime data model, websocket signaling, route surface, and backend control-plane responsibilities.
Related docs: [`BACKEND.md`](/Users/mau/Development/Turbo/BACKEND.md) owns agent-facing backend workflow rules; [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md) owns the quick namespace map.

## Purpose

This document defines the agreed v1 backend architecture for Turbo.

Turbo's backend is a **Unison Cloud control plane and signaling service** for an iOS Push-to-Talk app that uses Apple's PushToTalk framework and direct device-to-device media transport.

The backend is not a media relay.

## Product shape

### v1

Build the simplest viable backend for 1:1 Push-to-Talk:

- backend-managed dev auth
- simple backend-managed user directory
- backend-owned direct channels
- device registration
- channel membership authorization
- ephemeral PushToTalk token ingest and storage
- websocket signaling
- single active transmitter enforcement
- local development entrypoint with stub push logging

Explicit v1 non-goals:

- no media relay or SFU
- no group channels
- no Android
- no advanced moderation/admin features
- no message history beyond minimal audit/logging

### later

Keep a clean seam for:

- TURN-assisted fallback
- relay escalation when direct connectivity fails
- multi-device fanout
- group calls
- SFU-based media
- real APNs sender
- real auth provider integration

## Core design rule

The backend owns control-plane semantics and signaling semantics, while the client owns media transport.

That means:

- Unison decides who can talk to whom.
- Unison decides which direct channel exists for a pair of users.
- Unison authorizes signaling messages.
- Unison tracks active transmitter state.
- iOS devices create peer connections and carry audio.

## Why this is the right v1

This keeps the first implementation small and testable:

- PushToTalk integration can be exercised without solving relay infrastructure.
- Signaling can be developed and observed independently from media routing.
- Later transport upgrades do not require rewriting identity, channel, or signaling APIs.

## Runtime model

Use one shared backend implementation in all environments.

### local

- entrypoint: `turbo.serveLocal`
- runtime: `Cloud.main.local.serve`
- deployment surface: combined HTTP plus websocket route via `Route.deployWebSocket`
- push sender: stub logger
- auth: dev auth adapter
- storage: local cloud database/environment

### deployed

- entrypoint: `turbo.deploy`
- runtime: `Cloud.main`
- deployment surface: combined HTTP plus websocket route via `Route.deployWebSocket`
- push sender: real sender later, stub initially if needed
- auth: dev auth first, real auth later

No separate fake backend should exist for local development.

## Transport model

### v1 transport

- direct device-to-device only
- websocket signaling via Unison backend
- client-side STUN support expected

### future transport seam

The signaling contract must not assume direct P2P forever.

It should be possible later to:

- attach TURN config to session setup
- escalate failed direct attempts to relay-backed attempts
- replace direct peer signaling with SFU session setup

The public channel and membership model should remain unchanged.

## Backend modules

Current backend namespaces are indexed in [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md).

The architectural layering is:

- `turbo.domain`: durable records, runtime records, envelopes, readiness/wake types, and derived control-plane status helpers
- `turbo.store.*`: Unison Cloud table layouts, projections, transactional updates, and query-shaped accessors
- `turbo.service.*`: HTTP routes, websocket lifecycle, route composition, JSON boundaries, diagnostics, and internal worker surfaces
- `turbo.*`: deploy/local entrypoints, auth/config helpers, APNs support, schema drift checks, and cross-cutting infrastructure

## Data model

### Durable entities

#### users

- `userId`
- `handle`
- `displayName`
- `createdAt`
- `updatedAt`

#### devices

- `deviceId`
- `userId`
- `platform`
- `deviceLabel`
- `createdAt`
- `lastSeenAt`

#### direct channels

- `channelId`
- `lowUserId`
- `highUserId`
- `createdAt`

Store direct channels canonically by sorted user pair so one stable channel exists per pair.

#### memberships

- `channelId`
- `userId`
- `joinedAt`

For direct channels this can be derived at creation time, but it is still worth storing explicitly.

### Fast-changing state

#### device presence

- `deviceId`
- `userId`
- `status`
- `connectionId`
- `currentChannelId`
- `updatedAt`

#### active socket registry

Keyed by:

- `deviceId`

Fields:

- `userId`
- `webSocket`
- `connectedAt`

#### ephemeral PTT tokens

Keyed by:

- `channelId`
- `userId`
- `deviceId`

Fields:

- `token`
- `updatedAt`
- `invalidatedAt` or expiry metadata

#### runtime channel state

- `channelId`
- `activeTransmitterUserId`
- `activeTransmitterDeviceId`
- `targetUserId`
- `targetDeviceId`
- `transmitStartedAt`

## Device model

Users may register multiple devices.

For v1:

- only one active receiving device per user per channel is selected by the backend
- signaling routes to a specific target device
- pushes later target that same selected device

This keeps the runtime state simple while preserving the ability to expand to multi-device fanout later.

## Auth model

### v1

Use a backend-managed dev auth layer:

- sign in as a known test user
- resolve requests to a backend `userId`
- enforce ownership and membership checks on the server

### later

Replace the auth adapter with a real provider-backed flow without changing service logic.

The rest of the system should only depend on resolved backend identity, not on raw auth provider details.

## User directory

For v1, keep it simple:

- lookup by handle
- lookup by user ID
- no invite/contact graph
- no social workflow beyond choosing another known user

## Channel lifecycle

### direct channel creation

The app never invents channel IDs.

Flow:

1. client identifies the other user by handle or user ID
2. backend looks up or creates the stable direct channel
3. backend returns the channel UUID

### join and token flow

1. client registers a device
2. client asks for or creates the direct channel
3. client joins the channel with `deviceId`
4. backend records membership and marks that device present for the channel
5. client uploads the ephemeral PushToTalk token for `channel + user + device`

### begin transmit

1. client sends `begin-transmit` with only the sender `deviceId`
2. backend verifies the sender is a channel member
3. backend resolves the other direct-channel member
4. backend selects that user's foreground-ready device or token-backed wake target for the same channel
5. backend creates the transmit lock using the resolved target device

This keeps target-device choice authoritative on the server and avoids trusting the client to nominate a receiver.

## Websocket signaling

### handshake

- route: `GET /v1/ws`
- dev auth: `x-turbo-user-handle` header
- required query parameter: `deviceId`

On successful upgrade:

- backend binds the socket to that `deviceId`
- backend stores the active socket in the socket registry
- backend removes the socket record when the connection exits

### wire format

Signal frames are flat JSON objects with:

- `type`
- `channelId`
- `fromUserId`
- `fromDeviceId`
- `toUserId`
- `toDeviceId`
- `payload`

Supported `type` values in v1:

- `offer`
- `answer`
- `ice-candidate`
- `hangup`
- `transmit-start`
- `transmit-stop`
- `receiver-ready`
- `receiver-not-ready`

The backend treats `payload` as opaque text in v1. That keeps the signaling contract transport-agnostic and avoids baking SDP or ICE structure into backend logic.

### envelope shape

Use a transport-agnostic envelope:

```json
{
  "type": "offer",
  "channelId": "uuid",
  "fromUserId": "u_123",
  "fromDeviceId": "d_abc",
  "toUserId": "u_456",
  "toDeviceId": "d_xyz",
  "payload": {}
}
```

### authorization and forwarding rules

- the authenticated websocket user must match `fromUserId`
- the bound websocket device must match `fromDeviceId`
- both `fromUserId` and `toUserId` must be channel members
- the backend ignores client-supplied `toDeviceId`
- the backend resolves the active receiving device for `toUserId` from channel presence
- the backend forwards only to that server-selected device
- if no active receiving device exists, the sender receives an error frame

For `receiver-ready` and `receiver-not-ready`, the websocket signal is not the source of truth by itself. The backend persists the sender's current-session audio readiness and exposes the authoritative merged view on `/v1/channels/:channelId/readiness/:deviceId` under `audioReadiness`.

Wake capability is modeled separately from connected audio readiness. The same readiness route exposes token-backed wake capability under `wakeReadiness`, so the app can distinguish:

- connected peer, audio path not yet ready
- disconnected peer, wake-capable
- disconnected peer, not wake-capable

## PTT token lifecycle

After joining a channel, the iOS app receives an ephemeral PushToTalk token from Apple.

The backend stores it by:

- channel
- user
- device

Rules:

- replace previous token for the same tuple
- allow token invalidation later
- never expose stored tokens to other clients

## Transmit lifecycle

The backend enforces the Push-to-Talk invariant:

- at most one active transmitter per direct channel

### begin transmit

1. sender calls `begin-transmit`
2. backend verifies membership and device ownership
3. backend rejects if another transmitter is already active
4. backend selects the target receiving device and verifies that target's current-session receiver audio readiness
5. backend writes runtime state
6. backend later triggers push delivery
7. sender proceeds with signaling

### end transmit

1. sender calls `end-transmit`
2. backend clears runtime state
3. backend emits signaling lifecycle events as needed

## Push sending

### local

Do not call APNs.

Instead:

- log the intended target device
- log the channel ID
- log the intended payload shape

### later real sender

Keep push sending behind an interface so it can later:

- load credentials from environment config
- send real APNs PushToTalk requests
- invalidate tokens on APNs rejection

APNs PushToTalk sends must use:

- push type: `pushtotalk`
- topic: `<bundle-id>.voip-ptt`
- high priority delivery for wakeups
- immediate expiration semantics for stale audio wakeups

Payloads can include app-specific metadata such as:

- `channelId`
- sender identity
- event type such as `audio-available`

Example payload shape:

```json
{
  "aps": {},
  "channelId": "3f4f6e6f-0f9a-4ab2-a2d6-4e5f7d7e9b01",
  "speaker": {
    "userId": "u_123",
    "displayName": "Alice"
  },
  "event": "audio-available"
}
```

The iOS app still owns the Apple PushToTalk lifecycle. The backend owns target
selection, wake eligibility, APNs send attempt identity, and wake diagnostics.

## API surface

### HTTP

- `POST /v1/auth/session`
- `POST /v1/devices/register`
- `GET /v1/users/by-handle/:handle`
- `POST /v1/channels/direct`
- `POST /v1/channels/{channelId}/join`
- `POST /v1/channels/{channelId}/leave`
- `POST /v1/channels/{channelId}/ephemeral-token`
- `POST /v1/channels/{channelId}/begin-transmit`
- `POST /v1/channels/{channelId}/end-transmit`

### WebSocket

- authenticated websocket endpoint
- signaling message exchange using the shared envelope

## Failure handling

### Token issues

- If the recipient has no valid ephemeral token for the channel, `begin-transmit`
  returns a clear error unless foreground connected audio readiness is enough for
  the selected transmit path.
- If APNs rejects a token, remove or invalidate it.
- Token storage and invalidation are scoped to `channel + user + device`.

### Presence issues

- If the target device is offline, still try APNs wake when a token-backed wake
  target exists.
- If websocket is disconnected, do not assume the channel is invalid.
- Presence and session state must converge after reconnect, retry, duplicate
  delivery, and stale websocket signals.

### Signaling issues

- Reject malformed or unauthorized signaling.
- If offer/answer exchange times out, clear or repair runtime state through the
  owning subsystem.
- Include debug-friendly error codes and diagnostics evidence.

### Concurrency issues

- Only one active transmitter may exist per 1:1 channel.
- Overlapping transmit attempts must be rejected or serialized.
- Begin/end transmit behavior must be safe under retry and duplicate delivery.

## Security requirements

- All endpoints require auth.
- Device actions must be scoped to the owning user.
- Signaling messages must be authorized by channel membership.
- Arbitrary websocket routing across channels is forbidden.
- PTT tokens must never be exposed to clients other than the owning
  device/backend path that provided them.
- APNs credentials must be stored in managed environment/config secrets, not in
  checked-in files.

## Logging and observability

Backend diagnostics should preserve enough evidence to debug signaling, wake,
and transmit issues without reconstructing behavior from prose logs.

Important events:

- user authenticated
- device registered
- channel created or looked up
- channel joined or left
- ephemeral token stored, replaced, revoked, or invalidated
- begin-transmit called
- wake/APNs push attempted, succeeded, rejected, or failed
- offer relayed
- answer relayed
- ICE candidate relayed
- receiver-ready or receiver-not-ready persisted
- transmit ended
- websocket connected or disconnected

Include where possible:

- `userId`
- `deviceId`
- `channelId`
- timestamp
- result or failure reason
- transmit, wake, attempt, or session correlation IDs

## Local development workflow

Local development uses the same backend implementation through `turbo.serveLocal`, dev auth users, local HTTP/websocket endpoints, and stub push logging. Exact local server and scenario commands live in [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md).

## Documentation and testing expectations

For core Unison backend code, exported/user-facing functions and important types need `.doc` definitions, pure logic needs example tests, and core pure functions should get property tests when the property is meaningful. Full Unison workflow rules live in [`UNISON.md`](/Users/mau/Development/Turbo/UNISON.md).
