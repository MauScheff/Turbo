# Turbo Cloudflare APNs Worker

This is the interim APNs sender while hosted Unison Cloud waits on the runtime rollout for:

- TLS ALPN / HTTP/2 support needed for APNs transport
- built-in P-256 / ECDSA support needed for ES256 signing

Turbo remains authoritative for:

- wake target selection
- `begin-transmit` rules
- wake event identity and diagnostics

This Worker is only a transport adapter.

## Why this exists

The long-term goal is still direct APNs-from-Unison. Until that runtime is available on Unison Cloud, the backend should call this Worker instead of calling Apple directly.

## Routes

### `GET /health`

Returns a simple health payload and whether the required secrets are present.

### `POST /apns/send`

Authenticated generic APNs send endpoint.

Required header:

- `x-turbo-worker-secret: <shared secret>`

Request body:

```json
{
  "token": "<apns-device-token>",
  "payload": {
    "aps": {},
    "event": "transmit-start",
    "channelId": "abc",
    "activeSpeaker": "@blake",
    "senderUserId": "user-blake",
    "senderDeviceId": "device-blake"
  },
  "pushType": "pushtotalk",
  "bundleId": "com.rounded.Turbo",
  "topicSuffix": ".voip-ptt",
  "sandbox": true,
  "priority": 10,
  "expiration": 0,
  "metadata": {
    "wakeAttemptId": "optional-stable-id",
    "channelId": "abc",
    "targetDeviceId": "device-avery"
  }
}
```

Notes:

- `topic` may be sent directly instead of `bundleId` + `topicSuffix`.
- the generic shape is intentional so the same Worker can later send non-PTT APNs pushes too.

Response shape:

```json
{
  "ok": true,
  "result": "sent",
  "startedAt": "2026-04-15T12:34:56.000Z",
  "status": 200,
  "apnsId": "optional-apns-id",
  "reason": null,
  "body": "",
  "metadata": {
    "wakeAttemptId": "optional-stable-id"
  }
}
```

On Apple rejection:

```json
{
  "ok": false,
  "result": "rejected",
  "status": 400,
  "reason": "BadDeviceToken",
  "body": "{\"reason\":\"BadDeviceToken\"}"
}
```

On Worker exception:

```json
{
  "ok": false,
  "result": "worker-exception",
  "error": "..."
}
```

## Secrets

Set these with `wrangler secret put`:

- `TURBO_APNS_WORKER_SECRET`
- `TURBO_APNS_TEAM_ID`
- `TURBO_APNS_KEY_ID`
- `TURBO_APNS_PRIVATE_KEY`

Optional:

- `TURBO_APNS_DEFAULT_BUNDLE_ID`
- `TURBO_APNS_DEFAULT_USE_SANDBOX`

## Local commands

Run locally:

```bash
cd cloudflare/apns-worker
wrangler dev
```

Deploy:

```bash
cd cloudflare/apns-worker
wrangler deploy
```

Set secrets:

```bash
cd cloudflare/apns-worker
wrangler secret put TURBO_APNS_WORKER_SECRET
wrangler secret put TURBO_APNS_TEAM_ID
wrangler secret put TURBO_APNS_KEY_ID
wrangler secret put TURBO_APNS_PRIVATE_KEY
```

## First Turbo integration step

The first backend cutover should only change:

- `begin-transmit` still resolves the wake target in Turbo
- the backend calls this Worker instead of Apple
- the backend persists the returned send result into wake events

Do not move wake target selection or readiness logic into Cloudflare.
