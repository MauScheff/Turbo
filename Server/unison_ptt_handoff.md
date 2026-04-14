# Handoff: Unison Cloud Backend for iOS Push-To-Talk App

## Goal
Build the **control plane and signaling backend** for an iOS Push-To-Talk app that uses Apple's **PushToTalk framework** and **peer-to-peer WebRTC audio**.

This backend will run on **Unison Cloud**.

It is **not** responsible for relaying audio media. Audio should flow **directly between iOS devices via WebRTC**. The backend is responsible for identity, channel membership, APNs wakeups, ephemeral PTT token storage, and WebRTC signaling.

## Core product assumptions
- iOS app uses Apple's PushToTalk framework.
- Initial version is **1:1 only**.
- Audio transport is **WebRTC peer-to-peer**, not SFU.
- Backend is built in **Unison Cloud**.
- Backend uses **WebSockets** for signaling.
- Backend sends **APNs PushToTalk** notifications to wake the receiving device.
- We should design the backend so that we can later swap P2P media for an SFU without rewriting the whole control plane.

## Non-goals for v1
- No media relay/SFU.
- No group channels.
- No Android.
- No advanced moderation/admin features.
- No message history beyond minimal audit/logging.

## System responsibilities
The backend must support:
1. **Authentication and user identity**
2. **Device registration**
3. **1:1 channel creation and lookup**
4. **Presence and active device tracking**
5. **Ephemeral PushToTalk token ingest and storage**
6. **APNs PushToTalk wakeup delivery**
7. **WebRTC signaling relay**
8. **Transmit lifecycle state**
9. **Future compatibility with TURN/SFU**

---

# Architecture overview

## Backend responsibilities on Unison
Build these services in Unison Cloud:

### 1. Auth service
Responsible for:
- login/session validation
- mapping app users to internal user IDs
- authorizing access to channels and devices

### 2. Device service
Responsible for:
- registering iOS devices to users
- storing device metadata
- tracking current websocket connection
- tracking last seen / online status

### 3. Channel service
Responsible for:
- creating or looking up stable 1:1 channels
- storing channel membership
- ensuring only members can interact with the channel

### 4. PTT token service
Responsible for:
- receiving ephemeral PTT push tokens from iOS after channel join
- storing token scoped to **channel + user + device**
- replacing stale tokens
- expiring invalid state

### 5. APNs push service
Responsible for:
- sending PushToTalk APNs notifications to target devices
- using `pushtotalk` push type
- using `<bundle-id>.voip-ptt` topic
- high priority / immediate expiration behavior suitable for PTT

### 6. Signaling service
Responsible for:
- persistent WebSocket connections from devices
- relaying WebRTC signaling messages:
  - `offer`
  - `answer`
  - `ice-candidate`
  - `hangup`
  - `transmit-start`
  - `transmit-stop`
  - `receiver-ready`
  - `receiver-not-ready`
- routing messages only to authorized channel members
- persisting current-session receiver audio readiness so `/readiness.audioReadiness` is authoritative after reconnects, retries, or stale signals
- exposing token-backed wake capability on `/readiness.wakeReadiness` so wake is backend-authoritative too instead of inferred only from disconnected presence

### 7. Presence / session state service
Responsible for:
- active channel joins
- active websocket session per device
- active speaker / current transmitter state
- reconnection cleanup

---

# High-level call flow

## A. Join channel flow
1. iOS app authenticates.
2. Client opens WebSocket to signaling service.
3. Client joins a stable 1:1 channel.
4. Apple PushToTalk framework provides an **ephemeral PTT push token** after join.
5. Client POSTs token to backend.
6. Backend stores token under `channel + user + device`.

## B. Begin transmit flow
1. User presses talk.
2. Client calls `begin-transmit` endpoint.
3. Backend verifies user is a channel member.
4. Backend marks sender as active speaker for that channel.
5. Backend sends PushToTalk APNs push to the target device(s).
6. Backend notifies receiving device over WebSocket if already online.
7. Sender creates WebRTC offer and sends it through signaling.
8. Receiver answers after wake and readiness.
9. ICE candidates are exchanged through signaling.
10. Media flows directly device-to-device.

## C. End transmit flow
1. User releases talk button.
2. Client calls `end-transmit` or sends signaling event.
3. Backend clears active speaker state.
4. Backend forwards `transmit-stop` / `hangup` as needed.
5. Clients either keep peer connection warm briefly or tear it down.

---

# Important product constraints

## 1. Channel identity must be stable
For a direct conversation between two users, use a stable channel ID rather than creating a new channel per transmission.

Reason:
- better fits PushToTalk channel semantics
- easier token replacement
- easier reconnection and restoration

## 2. Tokens are stored per device, not just per user
A single user may have multiple iOS devices. Token storage must be scoped to:
- channel ID
- user ID
- device ID

## 3. Signaling must be stateless where possible
Do not make the signaling service depend on long-lived in-memory state only. Use durable or shared state for channel membership and device presence so reconnects are safe.

## 4. Design for future media upgrade
The signaling and channel control APIs should not assume P2P forever. They should be usable later with a TURN-heavy setup or an SFU.

---

# Data model

## Durable entities

### users
- `id`
- `external_auth_id`
- `display_name`
- `created_at`

### devices
- `id`
- `user_id`
- `platform` = `ios`
- `device_label` (optional)
- `last_seen_at`
- `created_at`

### channels
- `id` (UUID)
- `type` = `direct`
- `created_at`

### channel_memberships
- `channel_id`
- `user_id`
- `joined_at`
- unique `(channel_id, user_id)`

## Fast-changing state

### ptt_ephemeral_tokens
Store by:
- `channel_id`
- `user_id`
- `device_id`

Fields:
- `token`
- `updated_at`
- `expires_at` or TTL-equivalent strategy

### device_presence
- `device_id`
- `connection_id`
- `status` = online/offline
- `current_channel_id` (optional)
- `updated_at`

### channel_runtime_state
- `channel_id`
- `active_speaker_user_id` (nullable)
- `active_speaker_device_id` (nullable)
- `transmit_started_at` (nullable)

---

# Required APIs

## Auth
### `POST /v1/auth/session`
Validate session/token and return user identity.

Response:
```json
{
  "userId": "u_123",
  "displayName": "Alice"
}
```

## Device registration
### `POST /v1/devices/register`
Register or upsert device.

Request:
```json
{
  "deviceId": "d_abc",
  "platform": "ios",
  "deviceLabel": "Alice iPhone"
}
```

## Channel lookup/create
### `POST /v1/channels/direct`
Get or create stable 1:1 channel for two users.

Request:
```json
{
  "otherUserId": "u_456"
}
```

Response:
```json
{
  "channelId": "3f4f6e6f-0f9a-4ab2-a2d6-4e5f7d7e9b01"
}
```

## Join channel
### `POST /v1/channels/{channelId}/join`
Marks device as joined/ready for this channel.

Request:
```json
{
  "deviceId": "d_abc"
}
```

## Leave channel
### `POST /v1/channels/{channelId}/leave`
Marks device as left.

## Ephemeral PTT token ingest
### `POST /v1/channels/{channelId}/ephemeral-token`
Store the channel-scoped ephemeral push token from Apple PushToTalk.

Request:
```json
{
  "deviceId": "d_abc",
  "token": "<ephemeral-ptt-token>"
}
```

Behavior:
- verify channel membership
- upsert token by `channel + user + device`
- replace previous token for same tuple
- clean up stale token state

## Begin transmit
### `POST /v1/channels/{channelId}/begin-transmit`
Called when sender presses talk.

Request:
```json
{
  "deviceId": "d_abc"
}
```

Behavior:
- verify sender is channel member
- set active speaker state
- identify recipient device(s)
- send APNs PushToTalk push to recipient tokens
- optionally notify recipient over WebSocket if online
- return success so sender can proceed with WebRTC offer

## End transmit
### `POST /v1/channels/{channelId}/end-transmit`
Called when sender releases talk.

Behavior:
- clear active speaker state
- notify peers via signaling

---

# WebSocket signaling protocol

## Connection
Client opens authenticated WebSocket connection.

Server associates websocket session with:
- `userId`
- `deviceId`

## Message envelope
All signaling messages should use a common envelope.

```json
{
  "type": "offer",
  "channelId": "3f4f6e6f-0f9a-4ab2-a2d6-4e5f7d7e9b01",
  "fromUserId": "u_123",
  "fromDeviceId": "d_abc",
  "toUserId": "u_456",
  "toDeviceId": "d_xyz",
  "payload": {}
}
```

## Supported message types

### `offer`
Payload:
```json
{
  "sdp": "..."
}
```

### `answer`
Payload:
```json
{
  "sdp": "..."
}
```

### `ice-candidate`
Payload:
```json
{
  "candidate": "...",
  "sdpMid": "0",
  "sdpMLineIndex": 0
}
```

### `transmit-start`
Payload:
```json
{
  "startedAt": "2026-03-21T10:00:00Z"
}
```

### `transmit-stop`
Payload:
```json
{
  "stoppedAt": "2026-03-21T10:00:05Z"
}
```

### `hangup`
Payload:
```json
{}
```

## Server behavior
- authorize all messages against channel membership
- only route messages to intended target device/user
- reject malformed or unauthorized signaling
- optionally store short-lived signaling trace for debugging

---

# APNs PushToTalk requirements
The push worker must send Apple PushToTalk notifications with the correct headers.

Required behavior:
- push type: `pushtotalk`
- topic: `<bundle-id>.voip-ptt`
- high priority delivery for wakeups
- immediate expiration semantics for stale audio wakeups

Payload can include app-specific metadata such as:
- `channelId`
- sender identity
- event type like `audio-available`

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

Note: the iOS app team must still implement the Apple PushToTalk lifecycle correctly.

---

# WebRTC assumptions for v1
The backend does not terminate WebRTC. It only coordinates it.

Assume the iOS app will:
- create peer connections
- create offers and answers
- gather ICE candidates
- send signaling messages through the Unison WebSocket service
- stream audio directly device-to-device

## Expected first version network strategy
- start with STUN support on client side
- leave TURN integration as a planned follow-up if P2P connectivity is not good enough

---

# Failure handling requirements

## Token issues
- if recipient has no valid ephemeral token for the channel, return a clear error from `begin-transmit`
- if APNs rejects a token, remove or invalidate it

## Presence issues
- if target device is offline, still try APNs wakeup if token exists
- if websocket is disconnected, do not assume the channel is invalid

## Signaling issues
- if offer/answer exchange times out, clear runtime state
- include debug-friendly error codes

## Concurrency issues
- only one active transmitter per 1:1 channel
- reject or serialize overlapping transmit attempts

---

# Security requirements
- all endpoints require auth
- device actions must be scoped to the owning user
- signaling messages must be authorized per channel membership
- never allow arbitrary websocket routing across channels
- do not leak tokens to clients other than the owning device/backend
- APNs credentials must be stored in Unison-managed secrets

---

# Logging and observability
We need enough visibility to debug signaling and wakeup issues.

Log these events:
- user authenticated
- device registered
- channel created / looked up
- channel joined / left
- ephemeral token stored / replaced / invalidated
- begin-transmit called
- APNs push attempted / succeeded / failed
- offer relayed
- answer relayed
- ICE candidate relayed
- transmit ended
- websocket connected / disconnected

For each log event, include where possible:
- `userId`
- `deviceId`
- `channelId`
- timestamp
- result / failure reason

---

# Suggested implementation order

## Phase 1: Control plane skeleton
- auth stub
- user/device model
- channel model
- direct channel create/lookup

## Phase 2: WebSocket signaling
- authenticated websocket
- connection registry
- route `offer`, `answer`, `ice-candidate`

## Phase 3: PushToTalk token flow
- join channel endpoint
- ephemeral token ingest endpoint
- token replacement and cleanup

## Phase 4: Begin/end transmit
- active speaker state
- APNs push worker
- begin/end transmit APIs

## Phase 5: Reliability and cleanup
- presence expiry
- websocket reconnect handling
- timeout cleanup
- better logging and metrics

---

# Deliverables expected from the agent

## 1. Technical design
A concrete design for how this should be structured in Unison Cloud, including:
- services/modules
- storage layout
- websocket/session model
- background task model for APNs sending

## 2. API spec
A concrete API contract for the HTTP endpoints and WebSocket message types.

## 3. Data model
Concrete schema/types for:
- users
- devices
- channels
- memberships
- ephemeral tokens
- presence/runtime state

## 4. APNs integration plan
Explain:
- how credentials are stored
- how JWT/token auth is handled
- how push requests are formed
- retry / invalidation behavior

## 5. Minimal implementation plan
A realistic v1 build plan with file/module breakdown and execution order.

---

# Explicit guardrails
- Do **not** build a media relay or SFU.
- Do **not** assume WebRTC is backend-only.
- Do **not** terminate or proxy audio in Unison.
- Do **not** overcomplicate for group calls.
- Optimize for a working 1:1 iOS PTT prototype first.

---

# Final summary for the agent
We want a **Unison Cloud backend** that acts as the **control plane and signaling layer** for an **iOS PushToTalk app** using **peer-to-peer WebRTC audio**.

The backend should manage:
- auth
- devices
- stable 1:1 channels
- ephemeral Apple PTT push tokens
- APNs wakeups
- websocket signaling
- active speaker state

The backend should **not** relay media.

The design should be simple, clean, and intentionally structured so that a future version can replace P2P audio with TURN-heavy routing or an SFU without rewriting identity, channels, push, or signaling semantics.
