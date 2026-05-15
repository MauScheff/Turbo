# Reliability Sprint Plan

Status: active Track 6 sprint. Tracks 1-5 are complete; this file now owns the physical-device end-to-end reliability push.

Canonical goal: use physical devices to validate the Apple/PTT/audio/background boundary after the completed reliability work, find real failures, and convert every shared-logic failure into a local proof artifact before continuing.

This is the current sprint plan, not a permanent backlog. Replace it again when Track 6 closes.

## Baseline

Tracks 1-3 were closed in [`handoffs/2026-05-14-1520.md`](/Users/mau/Development/Turbo/handoffs/2026-05-14-1520.md).

Tracks 4-5 were closed in [`handoffs/2026-05-14-1732.md`](/Users/mau/Development/Turbo/handoffs/2026-05-14-1732.md).

Known completed proofs:

- `python3 scripts/check_invariant_registry.py`
- `python3 -m unittest scripts.test_merged_diagnostics`
- `just reliability-gate-regressions`
- `just swift-test-target absentBackendMembershipClearsStalePendingLocalJoinWithoutForceQuit`
- `just swift-test-target absentBackendMembershipRecoveryIsIdempotentAfterStalePendingJoinClears`
- `just swift-test-target absentBackendMembershipDoesNotClearPendingLocalJoinWhileBackendJoinIsSettling`
- `just swift-test-target selectedSyncPreservesPendingJoinWithUnresolvedLocalJoinAttemptAfterSettlingTTL`

Track 6 starts from that baseline. Do not reopen Tracks 1-5 unless physical-device evidence contradicts their invariants.

## Roles

Human device operator:

- Operates the physical phones exactly according to this plan.
- Reports the run ID, cell ID, transport mode, app states, visible path labels, whether audio was heard, and any shake incident IDs.
- Shakes both devices on failures and enters the requested short context string.
- Does not keep exploring after a serious failure unless the agent asks for a targeted retest.

Agent reliability owner:

- Runs reliability intake, merged diagnostics, probes, replay conversion, and gates.
- Classifies failures before editing: app/client projection, backend/control-plane truth, app/backend contract, simulator/tooling, or Apple/PTT/audio boundary.
- Converts shared-logic failures into the narrowest durable proof: reducer/property test, backend probe/test, simulator scenario, fuzz replay, merged-diagnostics fixture, production replay, or TLA+ model.
- Fixes the owning subsystem and asks for a minimal physical retest only after the automated proof is green.

## Non-Goals

- Do not use physical testing as a substitute for automated proof of shared app/backend behavior.
- Do not continue the whole matrix after a serious failure. Stop, capture evidence, classify, prove, fix, and retest the smallest failed cell.
- Do not ask for manual in-app diagnostics upload during the normal loop. Current debug builds should auto-publish latest full diagnostics after high-signal activity; missing latest snapshots are themselves a diagnostics/autopublish issue.
- Do not treat screenshots as authoritative when merged diagnostics can answer the behavioral question.
- Do not count a Direct QUIC cell as passing if it silently used relayed audio unless the test explicitly expected fallback.

## Prerequisites

Use two physical iPhones:

- Device A handle: `<A_HANDLE>`
- Device B handle: `<B_HANDLE>`
- Backend: `https://beepbeep.to` unless the agent explicitly changes it.
- Build: latest debug, TestFlight, or production-like build that includes Tracks 4-5.
- Permissions on both phones: microphone allowed, notifications allowed, Local Network allowed.
- Low Power Mode off and Focus/Do Not Disturb off for the first pass.
- Both devices on the same Wi-Fi for Direct QUIC cells unless the agent asks for cellular/NAT coverage later.

Before the matrix, open the app on both phones:

- Confirm both phones are signed in with the expected handles.
- Add/open each other as contacts.
- Open `Profile -> Diagnostics`.
- Note these fields from each phone if visible: app/build version, `Local device`, `WebSocket`, `Path state`, `Relay-only override`, `Auto-upgrade`, `Media relay enabled`, `Media relay forced`, `Backend advertised`, `Effective upgrade`.
- If `Local device` is unknown, run the first intake by handle only; the intake summary should list exact device IDs for later exact-device reads.

Recommended operator report template:

```text
T6 run:
- run ID:
- A handle / device:
- B handle / device:
- build:
- backend:
- network:
- cell:
- transport mode:
- starting app states:
- visible path labels:
- A->B heard first press?:
- B->A heard first press?:
- final states:
- shake incident IDs, if any:
- notes:
```

## Transport Modes

Set the transport mode on both phones from `Profile -> Diagnostics -> Direct QUIC` before running a cell.

### T1 WebSocket-Only Fallback Relay

Purpose: prove the plain hosted websocket relay path without Direct QUIC or media relay masking bugs.

Set on both phones:

- `Relay-only override`: on
- `Disable auto-upgrade`: on, shown as `Auto-upgrade: off`
- `Enable media relay`: off
- `Force media relay`: off

Expected:

- Top path badge or diagnostics path state shows `Relayed`.
- Direct QUIC fields show `Relay-only override: on`, `Effective upgrade: no`, and no active Direct QUIC attempt.
- Audio still works both directions in foreground. If foreground audio fails here, stop immediately; this is the baseline relay path.

### T2 Fast Relay

Purpose: prove low-latency media relay without Direct QUIC.

Set on both phones:

- `Relay-only override`: off
- `Disable auto-upgrade`: on, shown as `Auto-upgrade: off`
- `Enable media relay`: on
- `Force media relay`: on
- Relay host/ports: default `relay.beepbeep.to`, QUIC `9443`, TCP `9444`, unless the agent gives a different config.

Expected:

- Diagnostics show `Media relay enabled: yes`, `Media relay forced: yes`, `Media relay configured: yes`.
- Path state should become `Fast Relay` during prewarm/transmit.
- Direct QUIC should not activate.
- If media relay cannot connect, capture diagnostics and stop this transport mode; do not call it a websocket pass.

### T3 Direct QUIC

Purpose: prove device-to-device Direct QUIC promotion and first-talk behavior.

Set on both phones:

- `Relay-only override`: off
- `Auto-upgrade`: on
- `Enable media relay`: on
- `Force media relay`: off
- `Transmit startup`: default unless the agent asks to compare `Apple-gated` versus `Speculative foreground`.
- Local Network permission allowed on both devices.

Expected:

- Diagnostics show `Backend advertised: yes`, `Effective upgrade: yes`, production identity `ready`, peer device known, and eventually `Path state: Direct`.
- If path stays `Promoting`, `Recovering`, or `Relayed`, use `Force probe` once only if the agent asks. Otherwise capture diagnostics and stop the Direct QUIC cell.
- Audio must be heard on first press after the path is direct or direct-warming. A later retry-only success is a failure.

## App-State Matrix

Run the cells in this order. Stop on the first serious failure.

| Cell | App states | Sender action | Required coverage |
| --- | --- | --- | --- |
| S1 | A foreground, B foreground | A sends, then B sends | Baseline ready, first press audio, release convergence |
| S2 | A foreground, B backgrounded or locked | A sends to B | Wake-capable receiver, incoming PTT push, activation, playback |
| S3 | B foreground, A backgrounded or locked | B sends to A | Same as S2 with device roles swapped |
| S4 | A backgrounded or locked, B backgrounded or locked | Start from system PTT UI if available | Lock-screen/background sender plus locked receiver |

Run transport modes in this sequence:

1. T1 x S1
2. T2 x S1
3. T3 x S1
4. T1 x S2 and S3
5. T2 x S2 and S3
6. T3 x S2 and S3
7. S4 for each transport mode that passed S1-S3

S4 is allowed to be `blocked` instead of `failed` if the current build or iOS surface exposes no system sender affordance while the sender app is backgrounded or locked. Capture that as a product/platform limitation with diagnostics; do not invent taps to force it.

## Per-Cell Operator Script

Use a fresh run ID:

```text
T6-YYYYMMDD-HHMM-<transport>-<cell>
```

For each cell:

1. Set the transport toggles on both phones.
2. Fully foreground both apps.
3. Open/select the peer on both phones.
4. Wait until the intended state appears:
   - Foreground receiver: `Connected` / `ready`; hold-to-talk enabled only after `Preparing audio...` clears.
   - Background receiver: sender shows wake-capable or transmit-capable state; receiver is backgrounded or locked.
   - Direct QUIC: diagnostics path is `Direct`, or a Direct QUIC attempt is clearly active if the test is first-talk promotion.
5. Speak a unique phrase for each direction: `A to B <run ID>` and `B to A <run ID>`.
6. Press and hold for 3 seconds. Release. Wait 5 seconds.
7. Record whether the receiver heard the first press, whether the receiver UI showed `receiving`, whether the sender showed `transmitting`, and whether both sides returned to `ready`/`Connected` or the expected wake-ready state.
8. If anything violates expectations, stop and follow the failure capture script.

## Expected Healthy Behavior

Foreground sender and foreground receiver:

- Both devices converge to `ready`.
- Hold-to-talk stays disabled while the local device is still `Preparing audio...`.
- First press plays the Apple start beep on the sender.
- Sender reaches `transmitting` quickly.
- Receiver reaches `receiving` and hears audio on the first press.
- Release plays the Apple end beep and both devices converge back to `ready`.
- Merged diagnostics show no current invariant violations.

Background or locked receiver:

- Sender does not rely on foreground receiver prewarm; it uses backend wake readiness.
- Receiver gets an incoming PushToTalk push.
- Receiver logs `Incoming PTT push received`.
- Receiver logs `PTT audio session activated`.
- Buffered wake audio drains and playback starts during the same transmit window.
- If diagnostics show `Incoming PTT push received` but no `PTT audio session activated`, classify as Apple/PTT activation boundary until proven otherwise.

Transport evidence:

- T1 must show `Relayed`; no media relay forced, no Direct QUIC activation.
- T2 must show `Fast Relay`; media relay enabled/forced/configured, no Direct QUIC activation.
- T3 must show `Direct`; Direct QUIC attempt active/activated, peer device known, no forced relay.

Merged diagnostics should show, when relevant:

- Sender: `System transmit began`, `PTT audio session activated`, `Configured outgoing audio transport`, `Captured local audio buffer`, `Converted local audio buffer`, `Enqueued outbound audio chunk`.
- Receiver: `Signal received ... type=transmit-start`, `PTT audio session activated`, `Audio chunk received`, `Playback buffer scheduled`, `Playback node started`.
- Source warnings: ideally zero.
- Current invariant violations: zero for passing cells.

## Failure Capture Script

On the first serious failure:

1. Stop the matrix.
2. Shake both phones.
3. In the shake text field, enter:

```text
T6 <run ID> <cell> <transport> <short observed failure>
```

4. Wait 20-30 seconds for auto-publish.
5. Send the agent:
   - run ID
   - cell ID
   - transport mode
   - exact handles
   - visible path labels
   - whether audio was heard
   - final visible state on each phone
   - both shake incident IDs, if shown
   - whether either device was locked, home-screen backgrounded, or app-switcher backgrounded

The agent then runs intake. Use exact device IDs when known:

```bash
python3 scripts/reliability_intake.py \
  --base-url https://beepbeep.to \
  --surface debug \
  --backend-timeout 8 \
  --telemetry-hours 2 \
  --telemetry-limit 500 \
  --output-dir /tmp/turbo-track6/<run-id> \
  --device <A_HANDLE>=<A_DEVICE_ID> \
  --device <B_HANDLE>=<B_DEVICE_ID> \
  --insecure
```

If exact device IDs are not known yet:

```bash
just reliability-intake <A_HANDLE> <B_HANDLE>
```

For a shake-specific report:

```bash
just reliability-intake-shake <REPORTING_HANDLE> <INCIDENT_ID> <PEER_HANDLE>
```

The agent should inspect:

```bash
jq '.telemetryEventCount, .sourceWarnings, .currentViolations, .historicalViolations' /tmp/turbo-track6/<run-id>/merged-diagnostics.json
rg -n "VIOLATION|invariant|error|failed|timeout|transmit|receive|wake|audio|route|Direct QUIC|Media relay|PTT audio session|Incoming PTT push|Captured local audio buffer|Audio chunk received|Playback buffer scheduled" /tmp/turbo-track6/<run-id>/merged-diagnostics.txt
```

## Agent Debug Loop After Failure

For each failure:

1. Confirm source quality: backend latest snapshots, telemetry count, source warnings, shake marker, and exact devices.
2. Classify ownership:
   - app/client projection or reducer
   - backend/control-plane truth
   - app/backend contract
   - media relay or Direct QUIC transport
   - Apple/PTT/audio hardware boundary
   - diagnostics/autopublish
3. Name the violated invariant or create one if the contradiction is durable.
4. Choose the narrowest proof lane:
   - Swift reducer/property test for app state/projection/repair rules.
   - Backend probe/test for route, readiness, wake target, membership, or storage truth.
   - Simulator scenario for distributed app/backend ordering.
   - Merged-diagnostics fixture for pair/convergence detector regressions.
   - Production replay when intake produced a useful event story.
   - TLA+ when the issue is stale truth, ordering, retry, duplicate/drop/reconnect, or protocol convergence.
   - Physical retest only for PushToTalk UI, microphone permission, backgrounding, lock-screen wake, audio-session activation, or actual audio capture/playback.
5. Make the proof fail when feasible, then fix the owning subsystem.
6. Run the focused proof and the smallest broad gate matching blast radius.
7. Ask the operator to retest only the failed cell first.

## Optional Hosted Preflight

Use these when the hosted surface itself is suspect before blaming devices:

```bash
just backend-stability-probe https://beepbeep.to <A_HANDLE> 10 8
just websocket-stability-probe https://beepbeep.to <A_HANDLE> <B_HANDLE> 90 20 0
just hosted-backend-client-probe
just direct-quic-provisioning-probe
just turn-policy-probe
```

Run `just turn-policy-probe "--require-enabled"` only when the Direct QUIC test explicitly requires TURN to be enabled.

## Closeout

Track 6 closes when:

- All unblocked matrix cells either pass or have a tracked issue with artifact paths.
- Every shared-logic failure found by physical testing has a durable local proof artifact.
- Every Apple/PTT/audio-only failure has exact physical evidence and a clear unreplayable boundary explanation.
- Strict merged diagnostics for the final passing run has no current invariant violations.
- The final handoff lists run IDs, artifact paths, changed files, proof commands, remaining risks, and any skipped/blocked cells.

Final gate selection:

- App-only fix: focused Swift proof plus `just reliability-gate-regressions`.
- Distributed app/backend fix: focused proof, scenario when journey evidence matters, strict merged diagnostics, then `just reliability-gate-smoke`.
- Backend/control-plane fix: backend proof/probe, invariant registry check if touched, then `just reliability-gate-regressions` or stronger.
- Diagnostics/merged analyzer fix: `python3 scripts/test_merged_diagnostics.py`, replay fixture smoke, and `just reliability-gate-regressions`.
- Device-only Apple/PTT/audio fix: local shared-logic proof first, then targeted physical retest of the failed cell.
