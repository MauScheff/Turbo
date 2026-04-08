# Turbo Backend Architecture

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

Suggested module layout:

- `turbo.domain`
- `turbo.auth`
- `turbo.codec.json`
- `turbo.store.users`
- `turbo.store.devices`
- `turbo.store.channels`
- `turbo.store.memberships`
- `turbo.store.tokens`
- `turbo.store.presence`
- `turbo.store.runtime`
- `turbo.service.http`
- `turbo.service.ws`
- `turbo.push`
- `turbo`

This follows the same broad structure as `cuts`: domain types, store modules, service layer, and top-level entrypoints.

Current scratch/codebase layout already mirrors this plan:

- `turbo_domain.u`
- `turbo_store_auth.u`
- `turbo_runtime_store.u`
- `turbo_service_http.u`
- `turbo_service_ws.u`

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
4. backend selects that user's currently online device presence for the same channel
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

The backend treats `payload` as opaque text in v1. That keeps the signaling contract transport-agnostic and avoids baking SDP or ICE structure into backend logic.

### authorization and forwarding rules

- the authenticated websocket user must match `fromUserId`
- the bound websocket device must match `fromDeviceId`
- both `fromUserId` and `toUserId` must be channel members
- the backend ignores client-supplied `toDeviceId`
- the backend resolves the active receiving device for `toUserId` from channel presence
- the backend forwards only to that server-selected device
- if no active receiving device exists, the sender receives an error frame
4. client joins that backend-issued channel

### join

Join means:

- membership is confirmed
- selected device is marked present in the channel
- later, the client uploads its ephemeral PTT token for that channel

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

## Signaling model

The first backend milestone includes real websocket signaling.

### connection

Client opens an authenticated websocket and identifies:

- `userId`
- `deviceId`

### supported messages

- `offer`
- `answer`
- `ice-candidate`
- `hangup`
- `transmit-start`
- `transmit-stop`

### server checks

For every message:

- sender must own the sending device
- sender must be a member of the channel
- target must be the intended peer device in that channel
- malformed or unauthorized messages are rejected

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

## Transmit lifecycle

The backend enforces the Push-to-Talk invariant:

- at most one active transmitter per direct channel

### begin transmit

1. sender calls `begin-transmit`
2. backend verifies membership and device ownership
3. backend rejects if another transmitter is already active
4. backend selects the target receiving device
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

## Local development workflow

Target workflow:

1. run `turbo.serveLocal`
2. point the iOS app at local HTTP and websocket endpoints
3. use dev auth users
4. inspect console logs for stub push events and signaling traces

## Documentation and testing expectations

For core Unison code in this backend:

- add `.doc` definitions for exported or user-facing functions and important types
- add example tests for pure logic
- add property-based tests for core pure functions where useful
- explicitly call out functions that are not good candidates for property testing

## First implementation slice

Recommended first slice:

1. core domain types
2. users/dev auth
3. device registration
4. direct channel creation/lookup
5. join + ephemeral token ingest
6. websocket signaling
7. begin/end transmit runtime state
8. local entrypoint

This is enough to exercise the full control plane before real pushes are added.
