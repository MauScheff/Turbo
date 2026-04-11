# Turbo Handoff

This is the shortest accurate path back into the repo.

## Read first

1. [README.md](/Users/mau/Development/Turbo/README.md)
2. [AGENTS.md](/Users/mau/Development/Turbo/AGENTS.md)
3. [Server/backend_architecture.md](/Users/mau/Development/Turbo/Server/backend_architecture.md) if backend structure matters

## Current truth

- Foreground real-device PTT is working:
  - connect
  - hold-to-talk both directions
  - speaker routing on iPhone works with the current `.default` receive-mode experiment
- Hosted simulator/control-plane scenarios are in good shape.
- Production diagnostics upload/read are working again.
- APNs/PTT wake infrastructure is now real:
  - the app uploads ephemeral PTT tokens
  - the backend can return the canonical wake target for the active transmitter
  - the local APNs bridge can send real `pushtotalk` pushes and gets `status=200`

## Current blocker

The remaining real product bug is **deterministic background / lock-screen receive playback**.

What is already proven:

- the receiver gets a valid ephemeral PTT token uploaded to the backend
- `just ptt-push-target <channel> <base> <sender>` returns a real target token
- `just ptt-apns-bridge` sends real wake pushes
- on the locked receiver:
  - `incomingPushResult(...)` runs
  - `Set active remote participant` happens
  - `PTT audio session activated` happens
  - audio chunks arrive
- wake itself is now real:
  - the locked device can wake from the PTT push path
  - the sender can use the `wakeReady` path to start transmit even when websocket presence is soft

What is still failing:

- locked receiver playback is still nondeterministic after wake
- on some attempts, the receiver wakes but no audio plays
- on some later attempts on the same connection, audio may play
- the latest app-side experiment splits media startup:
  - `playbackOnly` startup for wake/receive
  - `interactive` startup for local transmit
- the intent is to let the locked receiver stand up speaker playback without trying to boot capture/input under the PTT-owned receive session
- the latest instrumentation now records:
  - media session startup mode
  - playback-engine start
  - playback-node start
  - playback buffer scheduling
  - audio-session interruption notifications
  - audio-session route-change notifications
  - media-services-reset notifications
- the sender-side wake-capable state is now implemented, so if wake-on-talk still fails the next bug is in the post-wake transmit/playback path rather than the selected-peer UI state machine

So the architecture gap is no longer push/token/send. It is the **post-wake playback/session path**, specifically making locked receive playback deterministic.

## Commands that matter

### Foreground / simulator loop

```bash
just simulator-scenario request_accept_ready
just simulator-scenario-merge
```

For deterministic local backend work:

```bash
just serve-local
just simulator-scenario-local request_accept_ready http://localhost:8080/s/turbo
just simulator-scenario-merge-local http://localhost:8080/s/turbo
```

### Production reset / probes

```bash
just reset https://beepbeep.to @avery
just reset https://beepbeep.to @blake
just prod-probe
```

`reset-all` now aliases to the live-safe reset path. Do not assume `/v1/dev/reset-all` exists on production.

### APNs / background wake loop

First, make sure `direnv` loads:

- `TURBO_APNS_TEAM_ID`
- `TURBO_APNS_KEY_ID`
- `TURBO_APNS_PRIVATE_KEY_PATH`
- `TURBO_APNS_USE_SANDBOX=1`

Then:

```bash
direnv exec . just ptt-push-target <channel_id> https://beepbeep.to @blake
direnv exec . just ptt-apns-bridge
```

`ptt-push-target` is the authoritative check that the receiver token exists on the backend.

`ptt-apns-bridge` should print lines like:

```text
[bridge] sent wake push sender=@blake target=... status=200
```

If wake fails and you do not see that line, do not guess from device UI first. Fix the token/send path first.

## What problem we are solving

There are two separate background concerns:

1. **Wake**
   - This is now largely solved.
   - APNs/PTT wake, token upload, bridge send, `incomingPushResult(...)`, and `didActivate` all work.

2. **Listening while locked**
   - This is the remaining blocker.
   - The receiver can wake correctly but playback is still flaky on the lock screen.
   - Current work should focus on locked receive playback, not on rediscovering the wake/token path.

## What changed recently

- App-side PTT token upload now retries when the ephemeral token arrives before the backend channel ID is known.
- The backend router was restructured into grouped route combinators so deploys stop silently dropping unrelated endpoints.
- Production contact-summary and diagnostics routes were restored after route-tree regressions.
- Invite subroutes (`accept`, `decline`, `cancel`) were reordered ahead of the generic invite route so cancel/decline no longer get shadowed.
- APNs sender tooling now uses `curl --http2` instead of Python’s default HTTP stack, which was incompatible with APNs.
- The APNs bridge now uses `curl` for backend calls as well, avoiding Cloudflare’s Python `urllib` blocking behavior.
- The selected-peer state machine now has a real `wakeReady` phase, and hold-to-talk remains enabled there.
- The media session startup path is now split between playback-only wake receive and interactive local talk startup.
- The backend transmit-target selector now falls back to the receiver's latest PTT token device when there is no connected receiving websocket presence, so wake-ready hold-to-talk is allowed to start transmit.
- The app now emits tighter locked-receive diagnostics:
  - media session startup mode
  - playback-engine start
  - playback buffer scheduling
  - audio-session interruption notifications
  - audio-session route-change notifications
  - media-services-reset notifications

## Next recommended test

Do not vary the ritual too much. Use one reproducible loop:

1. keep `direnv exec . just ptt-apns-bridge` running
2. establish one fresh foreground connection
3. test only:
   - `@blake` foreground
   - `@avery` locked
   - Blake talks once for 1-2 seconds
4. on the first failure:
   - upload both logs immediately
   - do not disconnect
5. retry once on the same live connection
6. if it succeeds:
   - upload both logs again immediately

The key goal is a fail/success pair from the same build and same session, so the new instrumentation can reveal what changes between unsuccessful and successful locked playback startup.

## Most important files

### App / domain

- [Turbo/ConversationDomain.swift](/Users/mau/Development/Turbo/Turbo/ConversationDomain.swift)
- [Turbo/SelectedPeerSession.swift](/Users/mau/Development/Turbo/Turbo/SelectedPeerSession.swift)
- [Turbo/PTTViewModel+Selection.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+Selection.swift)
- [Turbo/PTTViewModel+Transmit.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+Transmit.swift)
- [Turbo/PTTViewModel+PTTCallbacks.swift](/Users/mau/Development/Turbo/Turbo/PTTViewModel+PTTCallbacks.swift)
- [Turbo/PTTSystemClient.swift](/Users/mau/Development/Turbo/Turbo/PTTSystemClient.swift)
- [Turbo/PTTSystemPolicy.swift](/Users/mau/Development/Turbo/Turbo/PTTSystemPolicy.swift)
- [Turbo/PCMWebSocketMediaSession.swift](/Users/mau/Development/Turbo/Turbo/PCMWebSocketMediaSession.swift)
- [Turbo/AppDiagnostics.swift](/Users/mau/Development/Turbo/Turbo/AppDiagnostics.swift)

### Backend / scripts

- [turbo_service_http.u](/Users/mau/Development/Turbo/turbo_service_http.u)
- [turbo_runtime_store.u](/Users/mau/Development/Turbo/turbo_runtime_store.u)
- [scripts/ptt_apns_bridge.py](/Users/mau/Development/Turbo/scripts/ptt_apns_bridge.py)
- [scripts/send_ptt_apns.py](/Users/mau/Development/Turbo/scripts/send_ptt_apns.py)
- [scripts/sim_ptt_push.py](/Users/mau/Development/Turbo/scripts/sim_ptt_push.py)

### Tests / scenarios

- [TurboTests/TurboTests.swift](/Users/mau/Development/Turbo/TurboTests/TurboTests.swift)
- [scenarios/request_accept_ready.json](/Users/mau/Development/Turbo/scenarios/request_accept_ready.json)
- [justfile](/Users/mau/Development/Turbo/justfile)

## Known operational notes

- `TurboBackendBaseURL` in [Turbo/Info.plist](/Users/mau/Development/Turbo/Turbo/Info.plist) is still the environment switch.
- Physical devices are required for:
  - microphone permission
  - lock screen / background wake
  - Apple PTT system UI
  - actual audio routing and playback
- The route picker is available for debugging, but the current baseline is speaker-first receive audio.
- If a device UI shows stale `requested` / `incoming`, verify backend state first before assuming reinstall is required. Earlier failures were sometimes real backend invite-route regressions.
- The bridge may log expected non-owner noise less now, but only `sent wake push ... status=200` proves a real APNs wake attempt happened.

## Next agent task

1. Keep the sender talk affordance enabled when the peer is lock-screen reachable via PTT wake.
2. Fix locked-receiver playback so the already-activated PTT audio session can actually play arriving audio chunks.
3. Re-run the bridge-backed device test:
   - sender foreground
   - receiver locked
   - confirm wake push
   - confirm playback while locked
4. Only after that, clean up remaining UI/error noise and document the final device flow.
