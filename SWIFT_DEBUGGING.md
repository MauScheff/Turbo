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

## Background PTT wake loop

Foreground signaling can still use the app websocket, but background receive needs the real PushToTalk wake contract:

- the app uploads the ephemeral PushToTalk token it receives while joined
- the backend uses that token to send a `pushtotalk` APNs push when a remote speaker starts
- the app's `incomingPushResult(...)` returns the active remote participant quickly
- PushToTalk then activates the audio session
- only after that activation should the app reconnect transport and start background playback

For locked receive, prefer a playback-only media startup path under the PTT-owned activated audio session. Do not eagerly boot capture/input just to play remote audio after wake.
