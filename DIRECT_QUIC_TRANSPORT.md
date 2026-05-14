# Direct QUIC Transport Plan

Status: active plan/reference.
Canonical home for: Direct QUIC transport decision, transport states, signaling model, promotion/demotion, rollout, and verification.
Related docs: [`CERTIFICATE-LIFECYCLE.md`](/Users/mau/Development/Turbo/CERTIFICATE-LIFECYCLE.md) owns Direct QUIC device identity and certificate lifecycle details.

## Decision

Turbo should keep the existing relay transport as the guaranteed path and add an opportunistic direct-path upgrade over `Network.framework` QUIC.

The rule is:

- start on `Relay`
- probe direct QUIC in parallel when the session is eligible
- switch to `Direct` only after the direct path is verified
- fall back immediately to `Relay` when direct establishment or continuity fails

## Are We Doing HTTP/3?

Short answer: no for media, yes for QUIC.

We are not planning to run Turbo media as HTTP request/response traffic or to model each device as an ad hoc HTTP/3 server. The planned direct path is a custom app protocol over QUIC using `Network.framework`.

That means:

- `HTTP/3`: no
- `QUIC`: yes
- `Network.framework`: yes
- UDP hole punching / ICE-like coordination: yes

Apple's PushToTalk guidance points us toward `Network.framework` plus QUIC to reduce secure connection setup time, but it does not remove the need for NAT traversal logic or fallback behavior.

## Why This Fits Turbo

This matches the current repo shape:

- the app already owns media transport behind [`Turbo/MediaSession.swift`](/Users/mau/Development/Turbo/Turbo/MediaSession.swift)
- unsupported signaling kinds already exist for `offer`, `answer`, `ice-candidate`, and `hangup`
- the backend architecture already treats media transport as client-owned and keeps room for direct-path attempts plus relay escalation
- runtime capabilities already flow through `/v1/config` into `TurboBackendRuntimeConfig`

## Goals

- improve first-audio latency when direct UDP connectivity is available
- preserve current product behavior on hostile or degraded networks
- keep the backend as control plane and signaling authority, not as media plane
- make direct-path behavior observable and easy to disable during debugging

## Non-Goals

- no same-LAN-only transport mode
- no device-discovery UI
- no backend media relay inside Unison
- no requirement that transmit wait for direct connectivity
- no assumption that direct QUIC works on all networks

## Transport States

Add a transport-path state that is separate from session truth:

```swift
enum MediaTransportPathState: Equatable {
    case relay
    case promoting(DirectPromotionContext)
    case direct(DirectConnectionInfo)
    case recovering(RecoveryContext)
}
```

Semantics:

- `relay`
  - relay transport is the active media path
  - direct probing is not active
- `promoting`
  - relay remains the active path
  - direct candidate exchange / checks / handshake are in flight
- `direct`
  - media is actively flowing over the direct QUIC path
  - relay remains available as standby fallback
- `recovering`
  - a direct path existed or was being established, but failed or degraded
  - the app is reasserting relay as the active path and optionally scheduling a later retry

This state must not be inferred from transport booleans. It should be first-class state with timestamps and reason fields.

## UI Chip

The user-facing chip should mirror the transport state:

- `Relay`
- `Promoting`
- `Direct`
- `Recovering`

Rules:

- only show `Direct` after nomination succeeded and media has actually moved onto the direct path
- while probing, continue showing the active path as `Promoting`, not `Direct`
- if direct drops mid-session, flip to `Recovering` immediately and then back to `Relay` once relay is confirmed

This chip describes network path only. It must not be used as an encryption claim.

## Capability And Debug Flags

Use two layers of control.

### Backend capability

Extend `TurboBackendRuntimeConfig` with direct-path capability fields:

```swift
struct TurboBackendRuntimeConfig: Decodable {
    let mode: String
    let supportsWebSocket: Bool
    let telemetryEnabled: Bool?
    let supportsDirectQuicUpgrade: Bool
    let directQuicPolicy: TurboDirectQuicPolicy?
}
```

`supportsDirectQuicUpgrade` is the top-level kill switch from the backend.

`directQuicPolicy` should eventually include:

- `stunServers`
- `turnServers` later
- `promotionTimeoutMs`
- `retryBackoffMs`
- `idleDirectUpgradeDisabled`

Default production posture:

- `supportsDirectQuicUpgrade = false` until the feature is ready

### Local debug override

Add a local app override that can force relay-only behavior even when the backend advertises support:

- `TurboDebugForceRelayOnly`

Recommended sources:

- `UserDefaults`
- launch argument / debug menu toggle
- scenario-runtime override for tests

Effective decision:

```swift
effectiveDirectUpgradeEnabled =
    runtimeConfig.supportsDirectQuicUpgrade
    && !localDebugForceRelayOnly
```

If the local override is active:

- never enter `Promoting`
- never emit direct-path signaling
- keep the chip on `Relay`
- log a clear diagnostics event that direct upgrade was locally disabled

## Candidate Model

Because this is internet direct QUIC, assume UDP NAT traversal is required.

Start with an ICE-like candidate model:

- host candidate
- server-reflexive candidate from STUN
- relay candidate later via TURN

Proposed type:

```swift
struct TurboTransportCandidate: Codable, Equatable {
    let foundation: String
    let component: String
    let transport: String
    let priority: Int
    let kind: CandidateKind
    let address: String
    let port: Int
    let relatedAddress: String?
    let relatedPort: Int?
}

enum CandidateKind: String, Codable {
    case host
    case serverReflexive = "srflx"
    case relay
}
```

For v1 direct QUIC, `transport` should always be `udp`.

## Signaling Model

Keep the backend transport-agnostic and reuse the existing signaling lane.

Retain these signal kinds:

- `offer`
- `answer`
- `ice-candidate`
- `hangup`

Change the payload semantics to a transport-agnostic direct-path protocol instead of WebRTC SDP.

### `offer`

Contains:

- `protocol = "quic-direct-v1"`
- `attemptId`
- `channelId`
- `fromDeviceId`
- `toDeviceId`
- `quicAlpn`
- `certificateFingerprint`
- initial candidate set
- role intent if needed

### `answer`

Contains:

- `protocol = "quic-direct-v1"`
- `attemptId`
- accepted / rejected
- receiver certificate fingerprint
- receiver initial candidate set

### `ice-candidate`

Contains:

- `attemptId`
- incremental candidate
- optional end-of-candidates marker

### `hangup`

Contains:

- `attemptId`
- reason

The backend should continue to authorize and route these signals, but it should treat their payloads as opaque transport data.

## Connection Roles

Pick deterministic roles per attempt:

- the current transmitter-initiating side becomes the initial direct dialer
- the receiver listens and dials simultaneously if the attempt policy requires symmetric punching

Do not let role confusion leak into call sites. The promotion coordinator should own role assignment.

## Promotion Flow

### Session ready path

1. Session becomes eligible for media.
2. Active transport is `Relay`.
3. If `effectiveDirectUpgradeEnabled == true`, enter `Promoting`.
4. Gather host and STUN-derived candidates.
5. Exchange `offer`, `answer`, and `ice-candidate` over websocket signaling.
6. Start QUIC listener / outbound connection attempts.
7. Run short direct-path checks.
8. If direct QUIC becomes ready and authenticated, mark the attempt nominated.
9. Switch active media path from relay to direct.
10. Move state to `Direct`.

### Wake / background receive path

Do not make wake-critical receive depend on direct promotion.

For wake-driven or reconnect-sensitive flows:

- restore audio on the currently working path first
- probe direct only after the receive path is stable

## Promotion Gate

Promotion from `Promoting` to `Direct` requires all of:

- QUIC handshake succeeded
- peer identity matches the expected device / fingerprint
- at least one nominated candidate pair passed checks
- direct media path has sent and received proof traffic
- cutover does not interrupt active PTT audio session ownership

Until all of these are true, the active path remains `Relay`.

## Recovery And Demotion

Direct transport must demote aggressively.

Triggers:

- QUIC handshake failure
- connectivity-check timeout
- sustained packet loss / application-level no-progress timeout
- audio path stalls
- peer disconnect / hangup
- app background transitions that invalidate the direct socket

Recovery rules:

1. mark `Recovering`
2. reassert relay as the send and receive path
3. keep user-visible media continuity if possible
4. record the demotion reason
5. apply retry backoff before attempting a later promotion

Never leave the session in a state where both direct and relay are unavailable because the app waited too long to demote.

## Security

The direct QUIC path still needs explicit peer authentication.

Minimum requirement:

- per-attempt certificate fingerprint exchange via signaling
- verify the remote fingerprint against the signaled expectation before promotion

This transport chip does not claim end-to-end encryption. If Turbo later wants an encryption claim, document that separately.

## Implementation Shape

### App

Add:

- `DirectQuicPromotionCoordinator`
- `DirectQuicSession`
- `MediaTransportPathState`
- transport diagnostics events

Keep:

- `MediaSession` as the media boundary
- relay transport implementation as the baseline path

Likely factory evolution:

```swift
func makeDefaultMediaSession(
    supportsWebSocket: Bool,
    directUpgradeEnabled: Bool,
    sendAudioChunk: ...,
    reportEvent: ...
) -> any MediaSession
```

### Backend

Keep backend ownership limited to:

- capability advertisement in `/v1/config`
- STUN / TURN policy distribution later
- routing `offer`, `answer`, `ice-candidate`, `hangup`
- diagnostics about signaling attempts

Do not terminate QUIC in the backend.

## Diagnostics

Add structured events for:

- `transport.path.relay_active`
- `transport.path.promoting`
- `transport.path.direct_active`
- `transport.path.recovering`
- `transport.direct.disabled_local_override`
- `transport.direct.offer_sent`
- `transport.direct.answer_received`
- `transport.direct.candidate_sent`
- `transport.direct.candidate_received`
- `transport.direct.nomination_succeeded`
- `transport.direct.nomination_failed`
- `transport.direct.demoted`

Each event should carry:

- `channelId`
- `contactId`
- `attemptId`
- `localDeviceId`
- `peerDeviceId`
- `activePath`
- `reason`

## Phased Rollout

### Phase 0

- document the decision
- add runtime config fields
- add local `force relay only` override
- add transport-path state and UI chip

### Phase 1

- implement QUIC listener / connector spike on physical devices
- add direct-path media cutover once the QUIC path is proven
- verify signaling, authentication, and handshake timing

### Phase 2

- add STUN-based candidate gathering and server-reflexive candidate advertisement
- reuse the same local UDP port for listener/STUN/outbound QUIC where applicable
- trickle answer-side `ice-candidate` updates and `end-of-candidates` markers over websocket signaling
- let the listener side consume remote answer candidates and attempt outbound proof when inbound proof does not arrive
- keep answerer attempts alive after an initial outbound probe failure so the offerer can still rescue the path
- re-trickle offerer candidates after an accepted answer so the answerer gets another punch window
- keep wake/background flows relay-first

### Phase 3

- record the nominated direct path explicitly before `Promoting -> Direct`
- run lightweight direct-path consent pings after activation so stalled paths demote quickly
- add demotion, retry backoff, and richer diagnostics
- retain classified retry-backoff metadata so future probes can distinguish connectivity failure from security mismatch, peer rejection, or local/signaling faults
- add scenario and device proof loops

### Phase 4

- add TURN relay candidates if direct UDP success rate is not acceptable

## Verification

Automated first:

- reducer tests for transport-path state transitions
- coordinator tests for promotion and demotion rules
- signaling codec tests for `offer`, `answer`, and `ice-candidate`
- debug-override tests that prove `TurboDebugForceRelayOnly` blocks promotion

Physical-device proof:

- same Wi-Fi
- different Wi-Fi networks
- Wi-Fi to cellular
- background receiver wake then relay recovery
- direct-path failure mid-session with immediate demotion to relay

Simulator remains useful for state-machine and signaling logic, but not for proving QUIC transport behavior.

## Immediate Next Change

The next implementation step should be the first real ICE-like behavior layer:

1. prove the offerer-listener / answerer-dialer hole-punch path on physical devices across NATs
2. capture the most common real-network failure modes from those runs and tune the new classified retry / diagnostics policy around them

That keeps the current relay-first behavior intact while moving from a QUIC spike to a narrow, testable ICE-like direct-path layer.
