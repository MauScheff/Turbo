# Production Telemetry

Turbo now has a production telemetry pipeline built around a Cloudflare Worker plus Workers Analytics Engine. The goal is not to mirror every debug diagnostic. The goal is to capture high-signal production facts that help explain what happened, who it happened to, and where to query next.

## Architecture

There are two producers and one sink:

- the iOS app emits high-signal client telemetry through the backend
- the Unison backend emits server-side telemetry directly
- the Cloudflare telemetry worker writes compact events to Analytics Engine and can mirror alert-worthy events to Discord

Both producers may include `invariantId` when they can prove a contradiction locally. For true distributed invariants, they emit correlated facts that reliability intake or merged diagnostics can evaluate later.

The backend remains the authority for production ingestion:

- the worker secret stays server-side
- the app never talks to the worker directly
- the app only uses `POST /v1/telemetry/events`
- the backend forwards authenticated app telemetry to the worker as source `ios`

## Event Model

The shared event envelope includes these fields when available:

- `eventName`
- `source`
- `severity`
- `userId`
- `userHandle`
- `deviceId`
- `sessionId`
- `channelId`
- `peerUserId`
- `peerDeviceId`
- `peerHandle`
- `appVersion`
- `backendVersion`
- `invariantId`
- `phase`
- `reason`
- `message`
- `metadataText`
- `devTraffic`
- `alert`

The worker stores these in the `turbo_telemetry_events_v1` Analytics Engine dataset.

## Current Coverage

The current implementation sends these classes of events:

- iOS connection lifecycle:
  - `ios.backend.connected`
- iOS transmit lifecycle:
  - `ios.transmit.begin_requested`
  - `ios.transmit.backend_granted`
  - `ios.transmit.end_requested`
  - `ios.transmit.system_began`
  - `ios.transmit.system_ended`
- iOS wake / PTT signal path:
  - `ios.ptt.incoming_push_received`
- iOS high-signal diagnostics:
  - `ios.error.<subsystem>`
  - `ios.invariant.violation`
- iOS user-triggered reports:
  - `ios.problem_report.shake`
  - `ios.problem_report.shake_upload_failed`
- backend channel lifecycle:
  - `backend.channel.joined`
  - `backend.channel.left`
- backend transmit lifecycle:
  - `backend.transmit.begin_granted`
  - `backend.transmit.ended`
- backend presence lifecycle:
  - `backend.presence.heartbeat`
  - `backend.presence.background`
  - `backend.presence.offline`
- backend wake path:
  - `backend.wake.skipped_config`
  - `backend.wake.skipped_no_token`
  - `backend.wake.send_crashed`
  - `backend.wake.sent`
  - `backend.wake.failed`
- backend invariants:
  - `backend.invariant.violation`

The current rule of thumb is: send facts that explain production behavior or point directly to a contradiction. Keep low-level debug spam in the existing diagnostics system.

## Runtime Gating

Production telemetry is enabled when the backend has both of these environment values:

- `TURBO_TELEMETRY_WORKER_BASE_URL`
- `TURBO_TELEMETRY_WORKER_SECRET`

Optional classification env:

- `TURBO_TELEMETRY_DEV_HANDLES`
  - comma-separated handles treated as dev traffic for backend-owned events
  - example: `@avery,@blake,@turbo-ios`

`devTraffic` classification rules:

- iOS uploads set `devTraffic=true` for `DEBUG` builds
- iOS uploads also set `devTraffic=true` when running against a non-cloud backend mode
- backend-owned events set `devTraffic=true` when the emitting handle is in `TURBO_TELEMETRY_DEV_HANDLES`

When those are present:

- the backend advertises `"telemetryEnabled": true` from `GET /v1/config`
- the iOS app starts forwarding high-signal telemetry through the backend
- the backend sends its own server-side telemetry directly to the worker

When those are absent:

- the backend returns `"telemetryEnabled": false`
- the app-side telemetry hook stays inert
- the backend drops production telemetry instead of partially configuring it

## Worker Setup

Worker source lives in [`cloudflare/telemetry-worker/README.md`](/Users/mau/Development/Turbo/cloudflare/telemetry-worker/README.md).

Deploy the worker:

```bash
just cf-telemetry-worker-deploy
```

Required worker secret:

```bash
cd cloudflare/telemetry-worker
wrangler secret put TURBO_TELEMETRY_WORKER_SECRET
```

Optional Discord webhooks:

```bash
cd cloudflare/telemetry-worker
wrangler secret put TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK
wrangler secret put TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK
wrangler secret put TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK
```

Then bind the worker to the intended public hostname in Cloudflare:

```text
https://telemetry.beepbeep.to
```

The worker exposes:

- `GET /health`
- `POST /telemetry/events`

## Backend Setup

Before running `just deploy`, set these local environment values so `turbo.deploy` can sync them into the Unison cloud environment:

```bash
export TURBO_TELEMETRY_WORKER_BASE_URL="https://telemetry.beepbeep.to"
export TURBO_TELEMETRY_WORKER_SECRET="..."
```

Then deploy the backend:

```bash
just deploy
```

If the deployed service still reports telemetry config as absent even though the
local env vars are present, run the explicit sync helper from a `direnv`-loaded
shell and deploy again:

```bash
direnv exec . ucm run turbo/main:.turbo.syncDeployConfig
just deploy
```

After deploy, the backend will:

- expose `telemetryEnabled` in `GET /v1/config`
- accept authenticated app telemetry at `POST /v1/telemetry/events`
- emit backend-owned telemetry directly to the worker

## Query Setup

Telemetry queries use the Cloudflare Analytics Engine SQL API.

Set these locally:

```bash
export TURBO_CLOUDFLARE_ACCOUNT_ID="..."
export TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN="..."
export TURBO_TELEMETRY_DATASET="turbo_telemetry_events_v1"
```

Available `just` commands:

- `just telemetry-query query='SHOW TABLES'`
- `just telemetry-recent hours=24 limit=50`
- `just telemetry-recent-signal hours=24 limit=50`
- `just telemetry-recent-dev hours=24 limit=50`
- `just telemetry-follow hours=1 limit=50 poll=5`
- `just telemetry-follow-signal hours=1 limit=50 poll=5`
- `just telemetry-follow-dev hours=1 limit=50 poll=5`
- `just telemetry-user handle=@avery hours=24 limit=50`

Equivalent direct usage:

```bash
python3 scripts/query_telemetry.py --hours 24 --limit 50
python3 scripts/query_telemetry.py --hours 24 --limit 50 --exclude-event-name backend.presence.heartbeat
python3 scripts/query_telemetry.py --hours 1 --limit 50 --follow --poll-seconds 5
python3 scripts/query_telemetry.py --user-handle @avery --hours 24 --limit 50
python3 scripts/query_telemetry.py --hours 24 --limit 50 --dev-traffic true
python3 scripts/query_telemetry.py --query "SHOW TABLES"
```

The query helper prints a compact operator view by default and supports `--json` for raw API output.

## Relationship To Merged Diagnostics

Production telemetry is one input to the agent debugging loop, not a replacement for full diagnostics.

Use direct telemetry queries when the question is operational:

- did an event happen in production?
- which users/devices/channels emitted alerts?
- are backend routes timing out?
- did an invariant fire recently?
- is a production event stream or Discord alert configured correctly?

Use merged diagnostics when the question is behavioral:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 1 @mau @bau
```

`merged_diagnostics.py` pulls Cloudflare telemetry by default when query credentials are present, then combines it with the latest backend diagnostics snapshots. It treats both iOS and backend telemetry as invariant evidence: events with `invariantId` become violations, and complete telemetry state facts can become snapshot facts for the same pair/convergence checks used by local diagnostics.

The practical split is:

- telemetry answers: "what high-signal facts happened recently?"
- backend latest diagnostics answers: "what did this exact app instance know and log in detail?"
- merged diagnostics answers: "how do both devices' and backend facts line up?"

Do not move full debug transcripts, audio packet logs, routine state captures, or complete local state dumps into Cloudflare telemetry. Those belong in local diagnostics and backend latest diagnostics, especially when shake-to-report uploads the transcript. Telemetry events should stay compact, queryable, and alert-friendly.

## Shake Reports

Development, TestFlight, and production-like builds support shake-to-report. When a user shakes the phone, the app creates a local `incidentId`, asks for optional context, records a `Shake report requested` marker in diagnostics, captures the current state projection, uploads the full latest diagnostics transcript to the backend, then emits `ios.problem_report.shake` with `alert=true` when telemetry is enabled.

The user-facing UI stays generic. Operators should use these fields to inspect the report:

- `incidentId`: correlates the telemetry alert with the diagnostic transcript marker.
- `userHandle` and `deviceId`: identify the reporting device.
- `uploadedAt`: identifies the report time.
- `diagnosticsLatestURL`: points at the backend latest-diagnostics route for the reporting device.
- `channelId` and `peerHandle`: present when the user had selected or active conversation context.
- `userReport`: optional user-written context, present only when filled out.

From a Discord alert, first open or copy the `diagnosticsLatestURL` from the message. If auth headers are needed, fetch the same report with:

```bash
just diagnostics-latest <device_id> https://beepbeep.to <user_handle>
```

For behavioral debugging, prefer merged diagnostics around the alert time:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata <user_handle>
```

If the alert includes `peerHandle`, include both handles:

```bash
python3 scripts/merged_diagnostics.py --backend-timeout 8 --telemetry-hours 2 --telemetry-limit 500 --full-metadata <user_handle> <peer_handle>
```

V1 limitation: `diagnosticsLatestURL` is a latest-snapshot pointer, not an immutable report URL. Use `incidentId` and `uploadedAt` to confirm that the transcript you are reading is the shake report. A later incident-backed backend route should make `incidentId` the stable fetch key and allow peer-device reports to attach to the same incident automatically.

## Alerts

The worker can mirror alert-worthy events to Discord.

Recommended webhook split:

- `TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK` for `#prod-alerts`
- `TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK` for `#prod-telemetry`
- `TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK` for `#prod-dev`

Current alert policy:

- any event with `alert: true`
- any event with severity `critical`

That means:

- app-side invariant violations alert
- backend invariant violations alert
- explicit alert-marked failures can alert without waiting for a new severity tier

Delivery behavior:

- every accepted event is still written to Analytics Engine
- `devTraffic=true` events go only to the dev webhook when `TURBO_TELEMETRY_DISCORD_DEV_WEBHOOK` is configured
- the dev webhook receives both dev telemetry and dev alerts in one channel, labeled separately as `DEV STREAM` or `DEV ALERT`
- the stream webhook receives a curated operator feed for non-dev traffic
- `backend.presence.heartbeat` and explicitly opted-in `ios.diagnostics.state_capture` are intentionally excluded from Discord stream delivery to avoid flooding operator channels
- the alerts webhook receives only non-dev alert-worthy events
- the legacy `TURBO_TELEMETRY_DISCORD_WEBHOOK` name is still accepted as an alerts fallback during migration

Discord alerts intentionally include the fields needed to pivot back into Analytics Engine:

- source
- event name
- severity
- user identity
- device identity
- channel identity
- peer identity

## Smoke Test

Use this order.

1. Deploy the worker and bind `telemetry.beepbeep.to`.
2. Set `TURBO_TELEMETRY_WORKER_BASE_URL` and `TURBO_TELEMETRY_WORKER_SECRET`.
3. Run `just deploy`.
4. Verify the worker:

```bash
curl https://telemetry.beepbeep.to/health
```

5. Verify the backend advertises the feature:

```bash
curl --fail-with-body -sS https://beepbeep.to/v1/config
```

Expected: `"telemetryEnabled": true`

6. Open the app, connect a dev user, and join or transmit once.
7. Query recent events:

```bash
just telemetry-recent hours=1 limit=20
```

You should see a mix of:

- `ios.backend.connected`
- iOS transmit events if you pressed to talk
- backend join / presence / wake events from the same interaction

8. If Discord is configured, force an alert-worthy path and confirm the webhook fires.

## Design Notes

- Production telemetry is intentionally separate from the existing debug transcript pipeline.
- The debug diagnostics system remains the deep local timeline.
- Production telemetry is the searchable, durable, operator-facing summary stream.
- The worker is deliberately thin. Selection policy and identity enrichment belong in Turbo, not in Cloudflare glue code.
