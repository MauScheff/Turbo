# Turbo Peer Communication Diagrams

This document describes the two diagrams we want for explaining Turbo peer-to-peer communication:

- **Connection setup and fast-path warming**: how two peers become connected, how the backend remains the authority, and which hints/prewarm paths can make first talk faster.
- **Hold-to-talk audio flow**: what happens after the sender presses HOLD, including transmit lease, wake, Apple PushToTalk activation, media E2EE, and transport fallback.

The most important distinction:

- **The control plane is authoritative**. Requests, joins, readiness, wake targeting, websocket signaling authorization, and active transmit ownership are backend-owned.
- **Fast paths are optimizations**. Direct QUIC, the Rust media relay, receiver prewarm hints, and warm pings can reduce latency, but they do not replace backend session truth.
- **Audio transport is dynamic**. Audio prefers Direct QUIC when active, falls back to Fast Relay when enabled, and then falls back to the backend WebSocket relay.

## Legend

```text
[AUTH]  Backend-owned truth. This is the source of truth for session/transmit state.
[WS]    Backend WebSocket signaling. Authoritative routing, opaque signal payloads.
[HTTP]  Backend HTTP route.
[HINT]  Peer hint or prewarm signal. Useful for speed; not authoritative by itself.
[MEDIA] Audio/control path used by media startup or payload delivery.
[WAKE]  PushToTalk wake path through APNs.
[E2EE]  Media payload is sealed before transport and opened after receive.

Solid arrows   = required control flow
Dashed arrows  = fast-path hint/prewarm optimization
Dotted arrows  = fallback path
```

## Diagram 1: Connection Setup And Fast-Path Warming

This diagram should show that "establishing a connection" is not the same thing as choosing the audio transport. The session is established through the backend control plane. Direct QUIC and Fast Relay are prewarmed media/control paths layered on top of that session.

```text
Peer A iPhone                         Turbo Backend                         Peer B iPhone
-------------                         -------------                         -------------

Open/select peer
  |
  | [HTTP] /contact-summaries, /channel-state, /readiness
  |-----------------------------------> [AUTH] relationship, membership,
  |                                      audioReadiness, wakeReadiness,
  |                                      peer device identities
  |<-----------------------------------
  |
Press Connect
  |
  | [HTTP] create/refresh direct request
  |-----------------------------------> [AUTH] stable 1:1 direct channel
  |                                      request relationship
  |                                      contact summary projection
  |                         [WS/refresh]
  |                                      -------------------------------> Incoming request
  |
                                                                            Press Connect
                                                                            accept + join
                                                                            |
                                     [HTTP] accept invite / join channel     |
  Peer sees peerReady <---------------- [AUTH] membership + active device <--|
                                     [HTTP] upload PushToTalk token          |
                                     [HTTP] register Direct QUIC identity    |
                                     [HTTP] register media E2EE identity     |
                                     [WS] join-accepted control hint --------|
  |
Press Connect again
  |
  | [HTTP] join channel
  |-----------------------------------> [AUTH] both peers joined
  |                                      current device leases/presence
  |                                      /readiness projection
  |<-----------------------------------
  |
  |                         Both apps reconcile:
  |                         - backend channel exists
  |                         - local Apple PTT session matches selected peer
  |                         - backend membership/readiness agrees
  |                         - local media prewarm is complete enough to publish readiness
  |                         - peer audioReadiness is ready, or peer wakeReadiness is wake-capable
  v
selected peer phase: ready, waitingForPeer, or wakeReady
```

### Fast-path warming layered onto setup

These paths can run after peer selection, after join acceptance, during readiness convergence, or when first talk is approaching. They are intentionally drawn as side channels because they do not own session truth.

```text
                                        FAST-PATH WARMING LANE

Peer A iPhone                                                              Peer B iPhone
-------------                                                              -------------

Selected contact prewarm pipeline
  |
  +-- [HINT/WS] selected-peer-prewarm ------------------------------------>
  |       Payload: selected-peer-prewarm-v1
  |       Purpose: tell the selected peer to precreate media shell,
  |                run its prewarm pipeline, and remember recent peer device evidence.
  |
  +-- [HINT/WS] Direct QUIC setup signaling ------------------------------>
  |       direct-quic-upgrade-request
  |       offer / answer / ice-candidate / hangup
  |       Backend routes and authorizes these signals, but treats payload as opaque.
  |
  |                                      [MEDIA] Direct QUIC candidate probing
  |<------------------------------------- QUIC path negotiation ---------------------------->
  |                                      certificate fingerprint checked
  |                                      path state: promoting -> direct
  |                                      failure: timeout / hangup / path-lost -> relay
  |
  +-- [MEDIA] Direct QUIC receiver prewarm, if direct path is active ----->
  |       receiver-prewarm request / ack
  |       warm ping / pong
  |
  +-- [MEDIA] Fast Relay prejoin or receiver prewarm --------------------->
  |       Rust relay service, default relay.beepbeep.to
  |       relay QUIC port 9443, relay TCP port 9444
  |       control frames: receiver-prewarm request / ack
  |       path state: fastRelay
  |
  +.. [WS] fallback readiness signaling ..................................>
          receiver-ready / receiver-not-ready
          selected-peer-prewarm
          eventual audio relay fallback
```

### Setup outcomes to make visible

The final visual should show these possible connection/media readiness outcomes:

- **Ready foreground path**: both devices are joined, local Apple PTT sessions match, local media is prewarmed, peer `audioReadiness.peer.kind == ready`, and hold-to-talk can be enabled.
- **Wake-ready path**: the peer is not foreground-audio-ready, but backend `wakeReadiness.peer.kind == wake-capable`; the sender can hold to talk to wake the peer.
- **Direct path warmed**: Direct QUIC is active or warming; first talk can use direct media and Direct QUIC receiver prewarm.
- **Fast Relay warmed**: media relay is connected or prejoined; first talk can use relay media/control frames.
- **Relayed fallback**: backend WebSocket remains available for control signaling and fallback audio relay.

## Diagram 2: Hold-To-Talk Audio Flow

This diagram should show the complete path after the sender presses HOLD. The control plane grants or rejects transmit ownership; the wake path may activate the receiver; audio payloads are sealed end-to-end before they enter whichever transport is currently best.

```text
Peer A Sender                  Turbo Backend / Wake Plane             Media Transport            Peer B Receiver
-------------                  --------------------------             ---------------            ---------------

Press HOLD
  |
  | TransmitCoordinator: idle -> requesting
  |
  | [HINT] if warm Direct QUIC or relay exists:
  |-------- receiver transmit-prepare / receiver-prewarm --------------------------------------->|
  |        via Direct QUIC data channel, else Fast Relay control frame
  |        purpose: wake/prewarm receiver before real audio arrives
  |
  | [HTTP] begin-transmit
  |-----------------------------------> [AUTH] verify sender is current channel member
  |                                      [AUTH] resolve target device:
  |                                      - foreground-ready device, or
  |                                      - token-backed wake-capable device
  |                                      [AUTH] write active TransmitState lease
  |                                      [AUTH] return transmitId, expiresAt, targetDeviceId
  |<-----------------------------------
  |
  | start lease renewal loop
  | configure outgoing audio route
  | configure media E2EE session if peer identity is available
  |
  | [PushToTalk] request system transmit handoff
  | Apple start beep / system transmit began
  | PTT audio session activated
  | refresh capture path against live PlayAndRecord route
  |
  | capture microphone -> encode audio chunks -> [E2EE] seal payload
  |
  +============================ AUDIO PAYLOAD SELECTION ========================================+
  |                                                                                              |
  |  1. [MEDIA] Direct QUIC, if active and not forced to relay                                   |
  |        sendAudioPayload(sealedPayload) -----------------------------------------------------> |
  |        on send/path failure: fall back                                                       |
  |                                                                                              |
  |  2. [MEDIA] Fast Relay, if enabled/forced/configured                                        |
  |        Rust relay: QUIC 9443 or TCP 9444                                                     |
  |        sendAudioPayload(sealedPayload) -----------------------------------------------------> |
  |        on peer-unavailable/send failure: clear stale relay client, fall back                 |
  |                                                                                              |
  |  3. [WS] Backend WebSocket relay fallback                                                    |
  |        TurboSignalEnvelope(type: audio-chunk, payload: sealedPayload)                        |
  |-----------------------------------> backend routes authorized signal -----------------------> |
  |                                                                                              |
  +==============================================================================================+
                                                                                                  |
                                                                                                  v
                                                                                         receive sealed payload
                                                                                         configure/recover E2EE
                                                                                         [E2EE] open payload
                                                                                         ensure media session
                                                                                         schedule playback
                                                                                         selected phase: receiving
```

### Backend and wake side effects during transmit

The backend side effects run in parallel with the sender's local startup. They should be drawn close to `begin-transmit` because this is the authoritative point where the backend decides who may talk and who should receive.

```text
begin-transmit accepted
  |
  +-- [AUTH] active transmit lease exists
  |       - one active transmitter per channel
  |       - lease has transmitId and expiresAt
  |       - sender renews while still holding
  |
  +-- [WS] if target device has a current websocket/session lease:
  |       transmit-start payload "ptt-prepare" ---------------------------> receiver
  |       receiver marks remote activity and may prewarm/prepare playback
  |
  +-- [WAKE] unless target is already audio-ready with an open socket:
          backend selects target token
          current hosted path: backend -> Cloudflare Worker -> APNs
          desired long-term path: backend -> APNs directly
          Apple PushToTalk wakes receiver
          receiver waits for PTT audio session activation
```

### Receiver foreground path

```text
Receiver is active / foreground
  |
  | receives one or more of:
  | - transmit-start ptt-prepare over WebSocket
  | - Direct QUIC transmit-prepare
  | - Fast Relay receiver-prewarm request
  | - audio chunk over Direct QUIC / Fast Relay / WebSocket
  |
  v
prewarm or ensure playback media session
publish receiver-ready when local receive path and E2EE are ready
open E2EE payloads
schedule playback buffers
show receiving
```

### Receiver background or locked path

```text
Receiver is backgrounded / locked
  |
  | [WAKE] incoming PushToTalk push received
  |        pending wake candidate is associated with channel + sender device
  |
  | If audio/control arrives before Apple activates the PTT audio session:
  |        buffer encrypted wake audio
  |        stay in awaitingSystemActivation / signalBuffered
  |
  | Apple PushToTalk activates audio session
  v
systemActivated
  |
  | drain buffered encrypted audio
  | open E2EE payloads
  | schedule playback through system-owned receive path
  v
receiver hears audio during the same transmit window
```

### Release path

```text
Peer A releases HOLD
  |
  | stop local capture
  | [WS] transmit-stop payload "ptt-end" -------------------------------> Peer B
  | [HTTP] end-transmit(transmitId)
  |-----------------------------------> [AUTH] clear active transmit lease
  |
  v
Both sides converge back to ready, wakeReady, or waitingForPeer depending on
current membership, receiver readiness, wake capability, and media prewarm state.
```

### Warm Direct QUIC fast-start lane

There is also a foreground warm Direct QUIC optimization lane. When Direct QUIC is already active, the app may delegate a warm direct transmit path before the normal backend lease path completes. Draw this as a clearly labeled fast-start optimization, not as the ordinary control-plane path:

```text
Foreground + Direct QUIC active + startup policy allows it
  |
  | [HINT/MEDIA] receiver transmit-prepare over Direct QUIC
  | [PushToTalk] system handoff begins
  | [MEDIA] prewarmed Direct QUIC capture may start early
  | [WS] transmit-start payload "ptt-begin"
  | [MEDIA] sealed audio over Direct QUIC
  |
  +-- on release: [WS] transmit-stop payload "ptt-end"
  +-- on failure/path lost: fall back to relay path
```
ly1
## Image Model Prompt

Use this prompt to generate a polished visual diagram from the architecture above.

```text
Create a precise technical architecture diagram for Turbo, an iOS Push-to-Talk app.

The diagram must have two large horizontal panels:

Panel 1 title: "Connection Setup + Fast-Path Warming"
Panel 2 title: "Hold-To-Talk Audio + Wake + Fallback"

Use swimlanes from left to right:
1. "Peer A iPhone"
2. "Turbo Backend Control Plane"
3. "Wake Plane: Cloudflare Worker / APNs / Apple PushToTalk"
4. "Fast Media Paths"
5. "Peer B iPhone"

Visual encoding:
- Solid black arrows mean authoritative backend control-plane actions.
- Blue dashed arrows mean hints or prewarm paths.
- Green thick arrows mean encrypted audio payload delivery.
- Orange arrows mean APNs / Apple PushToTalk wake.
- Red dotted arrows mean fallback after transport failure.
- Add a small lock icon or "E2EE seal/open" label around media payloads before they enter Direct QUIC, Fast Relay, or WebSocket relay.
- Use labels directly on arrows. Keep text readable and technical, not marketing.

Panel 1 content:
- Show Peer A selecting/opening Peer B.
- Show Peer A calling backend HTTP routes: /contact-summaries, /channel-state, /readiness.
- Show Peer A pressing Connect, backend creating or refreshing the direct request/channel, and Peer B seeing incomingRequest.
- Show Peer B accepting and joining through Apple PushToTalk/local session plus backend join.
- Show backend storing membership/current device, PushToTalk token, Direct QUIC identity, and media encryption identity.
- Show a WebSocket join-accepted control hint from Peer B to Peer A, but label it "hint; backend remains authority".
- Show Peer A finishing join.
- Show readiness projection: audioReadiness, wakeReadiness, peerTargetDeviceId, peerDirectQuicIdentity, peerMediaEncryptionIdentity.
- Show final states: ready, waitingForPeer, wakeReady.
- In the Fast Media Paths lane, show these optional warming paths:
  1. selected-peer-prewarm over backend WebSocket
  2. Direct QUIC setup signaling over backend WebSocket: direct-quic-upgrade-request, offer, answer, ice-candidate, hangup
  3. Direct QUIC path probing and activation: promoting -> direct, with certificate fingerprint verification
  4. Direct QUIC receiver-prewarm request/ack and warm ping/pong
  5. Fast Relay prejoin through Rust relay, relay.beepbeep.to, QUIC 9443 or TCP 9444, receiver-prewarm request/ack
  6. WebSocket fallback receiver-ready / receiver-not-ready
- Make it visually explicit that Direct QUIC and Fast Relay do not establish the session; they only warm or carry media/control hints after backend session truth exists.

Panel 2 content:
- Show Peer A pressing HOLD.
- Show TransmitCoordinator moving idle -> requesting.
- Show optional fast prepare over Direct QUIC or Fast Relay: receiver transmit-prepare / receiver-prewarm.
- Show Peer A calling backend HTTP begin-transmit.
- In the backend lane, show:
  - verify sender is current channel member
  - resolve target as foreground-ready device OR token-backed wake-capable device
  - write active TransmitState lease
  - return transmitId, expiresAt, targetDeviceId
  - enforce one active transmitter per channel
  - sender renews lease while holding
- Show backend sending transmit-start "ptt-prepare" over WebSocket when the target has a current connected session.
- Show backend wake side effect unless target is already audio-ready with open socket:
  current hosted path: backend -> Cloudflare Worker -> APNs -> Apple PushToTalk -> Peer B
  desired future path: backend -> APNs directly
- Show Peer A PushToTalk handoff:
  request system transmit, Apple start beep, PTT audio session activated, rebind capture to live PlayAndRecord route, capture microphone, encode chunks.
- Show E2EE:
  media E2EE session from registered identities, seal payload before transport, open payload on Peer B.
  Label algorithm "media E2EE: X25519-derived key, ChaCha20-Poly1305 packet".
- Show dynamic audio transport priority:
  1. Direct QUIC sendAudioPayload if active
  2. Fast Relay sendAudioPayload if enabled/forced/configured; Rust relay over QUIC 9443 or TCP 9444
  3. backend WebSocket relay fallback with TurboSignalEnvelope type audio-chunk
- Show red dotted fallback arrows from Direct QUIC to Fast Relay, and from Fast Relay to WebSocket relay.
- Show Peer B foreground receive path:
  receive transmit-start or prewarm hint, set active remote participant, ensure playback media session, open E2EE payload, schedule playback buffer, show receiving.
- Show Peer B background/locked receive path:
  incoming PushToTalk push, pending wake candidate, awaitingSystemActivation/signalBuffered, buffer encrypted audio if it arrives early, Apple activates PTT audio session, drain buffered audio, open E2EE, play during same transmit window.
- Show release:
  Peer A releases HOLD, stop local capture, WebSocket transmit-stop "ptt-end", backend HTTP end-transmit(transmitId), backend clears active lease, both peers converge back to ready/wakeReady/waitingForPeer.
- Add a small callout for the foreground warm Direct QUIC fast-start optimization:
  "Warm Direct QUIC fast-start: if Direct QUIC is active and startup policy allows, app may send receiver transmit-prepare, start prewarmed direct capture, send transmit-start 'ptt-begin' over WebSocket, and carry sealed audio over Direct QUIC; draw as optimization lane, not normal backend authority."

Do not draw UDP/TCP as connection setup paths. UDP/QUIC and relay TCP only belong in the media transport layer. The backend WebSocket is the required control-plane signaling path; Direct QUIC and Fast Relay are media/hint fast paths.
```

## Source Pointers

Use these files when validating the diagram against implementation:

- `APP_STATE.md`
- `BACKEND.md`
- `APNS_DELIVERY_PLAN.md`
- `Server/backend_architecture.md`
- `Turbo/PTTViewModel+Selection.swift`
- `Turbo/PTTViewModel+Transmit.swift`
- `Turbo/PTTViewModel+TransmitAudioSend.swift`
- `Turbo/PTTViewModel+DirectQuic.swift`
- `Turbo/PTTViewModel+BackendSyncTransportFaultsAndSignals.swift`
- `Turbo/MediaEndToEndEncryption.swift`
- backend definitions: `turbo.service.channels.beginTransmit`, `turbo.store.runtime.beginTransmit`, `turbo.store.runtime.resolveTransmitTarget`, `turbo.service.channels.readiness`
