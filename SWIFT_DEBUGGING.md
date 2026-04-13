# Swift / iOS Debugging Guide

This file contains simulator, device, PushToTalk, audio-session, and operational debugging guidance for the app side.

Use it when the task is about:

- simulator scenarios
- distributed control-plane debugging from the app side
- device escalation rules
- PushToTalk wake behavior
- audio session activation or playback issues

For the repo's official state-machine-first proof model, also read:

- [`STATE_MACHINE_TESTING.md`](/Users/mau/Development/Turbo/STATE_MACHINE_TESTING.md)

## Fast inner loop

Optimize for:

- simulator and Xcode agent checks before real-device checks
- app-owned self-checks before manual tap-through debugging
- persistent readable logs before screenshot-based diagnosis
- checked-in simulator scenario specs under [`scenarios/`](/Users/mau/Development/Turbo/scenarios) for distributed control-plane bugs
- `just simulator-scenario-merge` before guessing from screenshots or prose
- trusting simulator exact-device diagnostics only after confirming tests actually ran

## Turbo-specific iteration notes

- Debug builds auto-publish structured diagnostics after high-signal state transitions. Manual `Upload` in the diagnostics sheet is now fallback behavior, not the primary path.
- The backend now supports exact-device diagnostics reads for simulator identities too, so `just simulator-scenario-merge` is part of the normal loop.
- The simulator scenario runner is controlled by a temporary repo-local file `.scenario-runtime-config.json` that `just simulator-scenario` creates and removes through `scripts/run_simulator_scenarios.py`. Do not check this file in or depend on it manually.
- The scenario runner now serializes scenario invocations with `.scenario-test.lock` and retries transient XCTest bootstrap crashes automatically. Use the `just` entrypoints instead of invoking `xcodebuild` manually when you want the stable loop.
- For targeted Swift Testing runs, use `just swift-test-target <name>` instead of raw `-only-testing`. The wrapper fails if the requested test name never actually executes, which prevents false-green zero-test runs.
- If `xcodebuild` says the simulator scenario command succeeded unusually quickly, confirm that tests actually ran. Swift Testing does not use the same selector behavior as classic XCTest, so a bad `-only-testing` filter can silently run zero tests.

## Scenario-driven simulator loop

Prefer this order for distributed control-plane bugs:

1. `just simulator-scenario <scenario>`
2. `just simulator-scenario-merge`
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

Useful commands:

- `just simulator-scenario`
- `just simulator-scenario foreground-ptt`
- `just simulator-scenario request_accept_ready`
- `just simulator-scenario-merge`

Current source of truth:

- the `simulatorDistributedJoinScenario()` result
- the merged simulator diagnostics timeline
- the regular `TurboTests` unit suite

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

## Background PTT wake loop

Foreground signaling can still use the app websocket, but background receive needs the real PushToTalk wake contract:

- the app uploads the ephemeral PushToTalk token it receives while joined
- the backend uses that token to send a `pushtotalk` APNs push when a remote speaker starts
- the app's `incomingPushResult(...)` returns the active remote participant quickly
- PushToTalk then activates the audio session
- only after that activation should the app reconnect transport and start background playback

For locked receive, prefer a playback-only media startup path under the PTT-owned activated audio session. Do not eagerly boot capture/input just to play remote audio after wake.
