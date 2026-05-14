# Swift / iOS Debugging Guide

Status: active debugging guide.

Canonical home for app-side debugging interpretation, device escalation, PushToTalk/audio log reading, client-only debug toggles, and Apple boundary loops.

Related docs:

- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) owns exact commands, flags, wrappers, and operational entrypoints.
- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) owns the report-to-scenario proof workflow.
- [`scenarios/README.md`](/Users/mau/Development/Turbo/scenarios/README.md) owns the scenario catalog and scenario JSON reference.
- [`PRODUCTION_TELEMETRY.md`](/Users/mau/Development/Turbo/PRODUCTION_TELEMETRY.md) owns telemetry and shake-report setup details.

This file contains simulator, device, PushToTalk, audio-session, and operational debugging guidance for the app side.

Use it when the task is about:

- simulator scenarios
- distributed control-plane debugging from the app side
- device escalation rules
- PushToTalk wake behavior
- audio session activation or playback issues

For the repo's official state-machine-first proof model, also read:

- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md)
- [`SELF_HEALING.md`](/Users/mau/Development/Turbo/SELF_HEALING.md) when the bug should recover automatically instead of requiring force quit or manual reset

## Fast inner loop

Optimize for:

- simulator and Xcode agent checks before real-device checks
- app-owned self-checks before manual tap-through debugging
- persistent readable logs before screenshot-based diagnosis
- checked-in simulator scenario specs under [`scenarios/`](/Users/mau/Development/Turbo/scenarios) for distributed control-plane bugs
- `just simulator-scenario-merge` before guessing from screenshots or prose
- `just reliability-gate-smoke` before treating hosted control-plane changes as stable
- trusting simulator exact-device diagnostics only after confirming tests actually ran

## Turbo-specific iteration notes

- Debug builds keep state captures in the local diagnostics ring/log and coalesce automatic latest full diagnostics transcript uploads to the backend. Routine state captures are not emitted to Cloudflare telemetry by default; enable `TURBO_IOS_STATE_CAPTURE_TELEMETRY=1` only for a targeted short debugging run that needs a raw remote state timeline.
- For long or intense physical-device sessions, use merged diagnostics first. Cloudflare telemetry gives the compact event timeline, while backend latest diagnostics gives the full transcript anchor with audio and local state detail.
- The backend supports exact-device diagnostics reads for simulator identities too, so simulator scenarios and merged simulator diagnostics are part of the normal loop.
- For physical-device timelines, use the merged diagnostics entrypoints documented in [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md). They merge Cloudflare telemetry by default when credentials are available and treat missing latest backend snapshots as source warnings.
- Agents should not ask for manual in-app diagnostics upload during the normal debug loop. If a current debug build has recent activity and `merged_diagnostics.py` cannot find a backend latest snapshot, investigate auto-publish/backend diagnostics rather than changing the workflow to manual upload.
- Scenario runner locking, runtime config, retry behavior, and Swift Testing selector rules live in [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) and [`TESTING.md`](/Users/mau/Development/Turbo/TESTING.md). The debugging rule is simple: prefer the `just` wrappers, and do not trust an unusually fast run until the wrapper proves nonzero tests executed.

## Merged diagnostics workflow

Use [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for the exact `just reliability-intake`, `just reliability-intake-shake`, and direct `merged_diagnostics.py` command forms. This guide only documents how to read the result.

Backend latest snapshots are fetched by default. Full backend transcripts are separate from Cloudflare telemetry metadata; enabling fuller telemetry rendering does not enable or disable backend transcript collection.

Use the tester's actual handles. Use JSON output when you need to count events, compare transport digests, or script over the result. If local Python cannot verify the certificate chain while querying Cloudflare telemetry, the repo-supported development workaround is the insecure diagnostics fetch documented in [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md); that changes local fetch verification only, not the interpretation of backend or telemetry evidence.

Read the result in layers:

1. Source warnings: confirm whether telemetry and backend latest snapshots were both available.
2. Invariant violations: treat typed invariants as the fastest path to the owning subsystem.
3. Pair timeline: reconstruct who requested, joined, transmitted, backgrounded, disconnected, or retried.
4. Full transcript anchors: inspect audio/session details that compact telemetry intentionally does not carry.

If an invariant describes a clearly impossible local/backend state, use `SELF_HEALING.md` before patching. The expected pattern is invariant -> owner -> bounded repair -> repair diagnostic -> regression. Do not treat a self-heal as complete if it only changes UI copy or hides the red error.

For audio bugs, telemetry alone is not enough. The backend latest transcript should show the sender capture path (`Captured local audio buffer`, `Converted local audio buffer`, `Enqueued outbound audio chunk`, outbound transport digest) and the receiver path (`Audio chunk received`, `Playback buffer scheduled`, `Playback node started`). If those are missing from a current debug build, fix diagnostics/autopublish before drawing conclusions about the audio path.

For production-like reports, the same command still applies when Cloudflare query credentials are present. Telemetry makes production events queryable and alertable; merged diagnostics remains the agent-facing debug view that combines queryable events with the latest full transcript.

### Shake reports

When a development, TestFlight, or production-like user shakes the phone, the app asks for optional context, then uploads full backend diagnostics and emits an alert telemetry event named `ios.problem_report.shake` when telemetry is enabled. The user can send the report without typing anything.

Inspect it in this order:

1. Read the Discord alert or telemetry event for `incidentId`, `userHandle`, `deviceId`, `uploadedAt`, `diagnosticsLatestURL`, `channelId`, and `peerHandle`.
2. Fetch the full transcript from the `diagnosticsLatestURL`, or use `just diagnostics-latest <device_id> https://beepbeep.to <user_handle>` if the route needs auth headers.
3. Verify the transcript contains `Shake report requested` with the same `incidentId`; if the user filled out the prompt, inspect `userReport`.
4. Run merged diagnostics around the same time. Include `peerHandle` when the alert has one.

If there is no peer, run the same command with only the reporting handle. The current report link is a latest-snapshot pointer, so use `incidentId` and `uploadedAt` to avoid reading a later upload by mistake.

### Audio packet diagnostics policy

The app should not emit every audio packet to production telemetry. Packet-level audio logs are high-volume, hard to query globally, and can increase the overhead of the real-time path. Keep Cloudflare telemetry for compact lifecycle facts, timings, route failures, and invariant violations.

For normal debug builds, packet-level evidence belongs in the backend latest diagnostics transcript:

- sender capture path:
  - `Captured local audio buffer`
  - `Converted local audio buffer`
  - `Enqueued outbound audio chunk`
  - outbound dispatch/delivery events with transport digests
- receiver path:
  - `Audio chunk received`
  - `Playback buffer scheduled`
  - playback start/readiness events

Those logs are intentionally budgeted in the hot path. The current shape records the first few sender capture/convert/enqueue events and the first few relay receive chunks, then emits a suppression notice such as `Suppressing repetitive WebSocket audio chunk diagnostics`. That gives enough evidence to prove startup, silence/non-silence, payload size, and digest continuity without turning every transmit into a huge diagnostics payload.

When a bug specifically requires deeper packet accounting, prefer adding a temporary or gated diagnostic mode instead of making unlimited packet logging the default. A good deep-audio mode should:

- be scoped to debug/dev builds or explicit test configuration
- emit compact per-chunk sequence facts, not raw PCM or full payloads
- include transport digest, sequence/index, chunk count, payload length, frame count, and local monotonic timing
- summarize totals at transmit end: captured, enqueued, dispatched, received, scheduled, dropped, suppressed, and largest inter-arrival/playback gaps
- flow into backend latest diagnostics so `merged_diagnostics.py` remains the single agent entrypoint

The iteration loop for suspected packet loss is:

1. reproduce once on devices
2. save merged diagnostics with `--full-metadata`
3. compare sender enqueue/dispatch digests with receiver `Audio chunk received` digests
4. inspect playback scheduling for gaps, silence, or route/session changes
5. if the transcript is insufficient, add a focused deep-audio diagnostic counter or checked-in simulator/local transport scenario
6. keep the regression in simulator/local infrastructure when the defect is transport/state-machine owned; use physical devices only for Apple audio-session, PushToTalk, background, route, and actual capture/playback boundaries

## Client-only UX shortcuts

Some flows intentionally have a client-side shortcut layered on top of the underlying handshake state machine.

Current shortcut:

- requester auto-join on peer acceptance
  - if Avery sent the request
  - and Blake accepts it
  - Avery may auto-join instead of requiring a second manual `Connect` tap

This is intentionally:

- client-only
- optional
- reversible for debugging

It does **not** change the backend handshake truth. The underlying request / peer-ready / join states still exist and should still be reasoned about as the source of truth. The shortcut only compresses the requester-side UX.

### When debugging handshake bugs

If you suspect the shortcut is hiding a real sequencing bug, disable it first and reproduce the raw handshake:

```lldb
expr PTTViewModel.shared.setRequesterAutoJoinOnPeerAcceptanceEnabled(false)
```

Re-enable it with:

```lldb
expr PTTViewModel.shared.setRequesterAutoJoinOnPeerAcceptanceEnabled(true)
```

The flag is persisted in `UserDefaults` under:

- `turbo.shortcuts.requesterAutoJoinOnPeerAcceptance`

Diagnostics also expose:

- `selectedPeerAutoJoinEnabled`
- `selectedPeerAutoJoinArmed`

Those fields are useful when a merged timeline looks like the requester skipped a step. First check whether the shortcut was armed before assuming the backend or reducer illegally jumped phases.

## Scenario-driven simulator loop

Use [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md) for the scenario proof workflow and [`scenarios/README.md`](/Users/mau/Development/Turbo/scenarios/README.md) for the exact scenario commands and JSON shape.

For distributed control-plane bugs, the app-side debugging order is:

1. run the smallest useful scenario
2. merge diagnostics
3. inspect the merged timeline
4. only then move to physical devices for Apple/PTT/audio/background behavior

The scenario should assert machine projections directly where possible:

- selected-session phase / status
- contact-list projections
- backend-derived readiness

If a bug report comes from physical devices, the goal is usually not to mirror every tap literally. The goal is to extract the smallest multi-device event story that explains the invariant failure in the shared state machines, then encode that story as a simulator scenario.

In practice that means you can usually tell the agent:

- which user did what
- what the peer did
- whether either side backgrounded, reconnected, or restarted
- what state each side should have reached
- what state one side got stuck in instead

If the bug is in shared app/backend logic, that is usually enough to build a deterministic scenario, reproduce it, fix it, and keep it as a regression.

For mixed app/backend bugs, do not stop after reproducing the client symptom in Swift.

Before deciding the fix location:

1. inspect the app-side reducer or projection that surfaced the bad state
2. inspect the backend route or projection that supplied the shared truth
3. decide whether the client is rendering bad backend truth or deriving the backend truth incorrectly
4. add an invariant at the seam that can actually prove the contradiction

If the backend-owned fact is wrong, the frontend may add guardrails or better diagnostics, but that is not the primary fix.

## Device escalation rules

Only move to physical devices when the bug is clearly in one of these surfaces:

- microphone permission
- real Apple PushToTalk UI
- backgrounding / lock screen
- actual audio playback / capture

Do not start with more device experimentation if the simulator scenario or probe loop is red.

The device is still essential when the boundary itself is the suspect, but it should no longer be the first or only proof surface for control-plane bugs.

## Foreground audio smoke loop

When the app is already joined on both devices and both apps are foregrounded, the stable foreground transmit loop should look like this:

1. both sides converge to `ready`
2. the local hold-to-talk button stays disabled while that device is still `Preparing audio...`
3. once local prewarm finishes, hold-to-talk becomes enabled
4. on first press, the transmitter should:
   - play the Apple start beep
   - move through `startingTransmit`
   - quickly settle into `transmitting`
5. the receiver should:
   - move into `receiving`
   - hear audio on that first transmit, not only on later retries
6. on release, both sides should:
   - play the Apple end beep on the transmitter
   - converge back to `ready`

That is the current known-good foreground device contract. If this breaks, treat it as an audio-boundary regression, not as a generic control-plane bug.

### Current app-owned invariants behind that behavior

- local interactive media is prewarmed before hold-to-talk becomes enabled on that device
- first transmit rebinds the capture path against the real `PlayAndRecord` route instead of trusting the earlier prewarm route
- remote `transmit-stop` does not immediately recreate interactive audio while the PTT audio session is still deactivating
- unexpected system transmit end should clean up or retry cleanly instead of leaving stale transmit state behind

### What to read in logs when it regresses

For a healthy first foreground transmit, merged diagnostics should show this shape on the sender:

- `System transmit began`
- `PTT audio session activated`
- `Configured outgoing audio transport`
- `Refreshed capture path for current audio route`
- `Starting audio capture with transport state configured=true`
- `Captured local audio buffer`
- `Converted local audio buffer`
- `Enqueued outbound audio chunk`

And on the receiver:

- `Signal received ... type=transmit-start`
- `PTT audio session activated`
- `Preparing receive media session after PTT audio activation`
- `Audio chunk received`
- `Playback buffer scheduled`
- `Playback node started`

If the sender reaches `Starting audio capture...` but never logs `Captured local audio buffer`, suspect the sender capture engine / tap / route boundary first.

If the receiver reaches `Preparing receive media session...` but never logs `Audio chunk received`, suspect sender capture or send-path failure first, not receiver playback.

### Latest known-good foreground log shape

The current stable reference run is the `@avery -> @blake` foreground transmit uploaded around `2026-04-13T16:52Z`.

In that run, the important healthy sequence was:

- sender already back at `ready`
- `System transmit began`
- sender logs:
  - `Captured local audio buffer`
  - `Converted local audio buffer`
  - `Enqueued outbound audio chunk`
- receiver logs:
  - `Audio chunk received`
  - `Playback node started`
  - repeated `Playback buffer scheduled`
- receiver selected conversation becomes `receiving`
- on release:
  - sender logs `System transmit ended`
  - sender returns to `ready`
  - receiver briefly returns through `Preparing audio...`
  - receiver re-prewarms and returns to `Connected`

The important part is not a specific internal branch name. The important part is that real audio chunks arrive and playback starts promptly during the same transmit window, rather than being buffered until long after release.

### Receiver-ready gate

The prewarm gate is now globally receiver-ready for joined foreground sessions:

- each device publishes `receiver-ready` only after its own receive path is actually prewarmed
- each device publishes `receiver-not-ready` when that readiness is lost
- the backend stores that readiness per joined device/session and exposes it through `/readiness.audioReadiness`
- the sender only gets enabled hold-to-talk when backend readiness, local warmup, and the backend's authoritative peer audio-readiness view all agree

So for the normal joined foreground path, `Connected` plus enabled hold-to-talk now means "the backend currently believes the other joined device can hear you right now", not just "this device finished local prewarm first".

When a joined peer backgrounds or locks and deliberately tears down its idle foreground prewarm, that should no longer be modeled as ordinary `waiting` on the sender. The app now treats that `receiver-not-ready` transition as a wake-capable remote-audio state, so the sender can move into `wakeReady` instead of getting stuck in `Waiting for <peer>'s audio...`.

### Wake-ready gate

Wake is now modeled separately from foreground receiver readiness:

- the app still uploads the ephemeral PushToTalk token after join
- the backend exposes token-backed wake capability through `/readiness.wakeReadiness`
- the selected conversation only enters `wakeReady` when the peer is disconnected **and** the backend says `wakeReadiness.peer.kind == wake-capable`
- a disconnected peer without backend wake capability should stay in a waiting state, not show hold-to-talk optimistically

That distinction matters for background and lock-screen work. "Peer is offline" is no longer enough to infer "wake is possible".

## Background PTT wake loop

Foreground signaling can still use the app websocket, but background receive needs the real PushToTalk wake contract:

- direct APNs-from-Unison is the intended end state, but hosted Unison Cloud is still waiting on the upstream runtime rollout
- until that lands, use the interim backend-triggered Cloudflare sender plan in [APNS_DELIVERY_PLAN.md](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md)
- the backend chooses the authoritative wake target on `/ptt-push-target` and `/readiness.wakeReadiness`
- the long-term hosted path is still for `begin-transmit` to build the APNs JWT in Unison and perform the `pushtotalk` send directly with `Http.request`
- wake-send results are uploaded to the backend dev diagnostics surface, so merged diagnostics includes `[wake:apns] ...` entries in the timeline
- `ptt-apns-worker` and `ptt-apns-bridge` are still available only as legacy/debug helpers
- the app uploads the ephemeral PushToTalk token it receives while joined
- the backend uses that token to send a `pushtotalk` APNs push when a remote speaker starts
- the app's `incomingPushResult(...)` returns the active remote participant quickly
- PushToTalk then activates the audio session
- only after that activation should the app reconnect transport and start background playback

For locked receive, prefer a playback-only media startup path under the PTT-owned activated audio session. Do not eagerly boot capture/input just to play remote audio after wake.
If PTT activation does not arrive in time, keep buffering wake audio while the app is locked or backgrounded. Do not fall back to app-managed `AVAudioEngine` playback until the app is active again; otherwise CoreAudio can throw `player did not see an IO cycle`.
Also, do not carry an idle foreground app-managed interactive media session into the background. On `willResignActive` / `didEnterBackground`, the app should suspend that foreground prewarm unless it is actively transmitting or already in a pending wake flow. Otherwise the lock-screen receive path can get stuck buffering websocket audio without ever letting the real PushToTalk activation own playback.

The app now records the incoming wake handoff explicitly:

- `signalBuffered`
- `awaitingSystemActivation`
- `fallbackDeferredUntilForeground`
- `appManagedFallback`
- `systemActivated`

For the current background wake issue, the critical distinction is:

- `Incoming PTT push received` but **no** `PTT audio session activated`

That means APNs delivery worked, but the Apple PushToTalk activation boundary did not complete. Treat that as a device/PTT boundary failure, not a generic backend or websocket failure.

The current expected log order for a good locked-screen receive wake is:

1. bridge prints `sent wake push ... status=200`
2. receiver logs `Incoming PTT push received`
3. receiver logs `PTT audio session activated`
4. buffered wake audio drains and playback begins

If the receiver only reaches `awaitingSystemActivation`, the next debugging question is why Apple never promoted the incoming push into the activated PTT audio session.
