# APNs Delivery Plan

## Status

Turbo's ideal long-term wake path is still:

1. Unison backend selects the authoritative wake target
2. Unison backend signs the APNs JWT
3. Unison backend sends the `pushtotalk` request directly
4. Unison backend records the wake result in merged diagnostics

That path is blocked today by the current hosted Unison Cloud runtime. Local runtime work now proves the missing pieces:

- TLS ALPN negotiation needed for HTTP/2-over-TLS
- P-256 / ECDSA builtins needed for ES256 signing

We should treat direct APNs-from-Unison as waiting on two things:

1. upstream merge of the Unison runtime changes
2. deployment of that updated runtime to Unison Cloud

Until both happen, the production-compatible plan is an external APNs sender.

## Interim Direction

Use Cloudflare as the temporary APNs sender.

Important refinement:

- do not recreate the old pair-specific local bridge
- do not move target selection or wake authority out of Turbo
- only move the outbound Apple APNs call out of Unison Cloud for now

The backend remains authoritative for:

- wake target selection
- begin/end transmit rules
- wake event identity and diagnostics
- readiness / wakeReadiness

Cloudflare only performs:

- authenticated receipt of a wake-send request from the backend
- the outbound APNs request
- response/error translation

## Recommended Interim Architecture

### MVP

1. `begin-transmit` in Unison resolves the wake target exactly as it does now
2. instead of calling APNs directly, it POSTs a signed internal request to a Cloudflare Worker
3. the Worker sends the APNs `pushtotalk` request immediately
4. the Worker returns the APNs result synchronously
5. the backend records the wake event and includes it in merged diagnostics

That keeps the architecture close to the desired end state:

- Turbo backend still decides *who* to wake
- the Worker only decides *how* to perform the outbound send

### Request Shape

The backend request to Cloudflare should include:

- a backend-authenticated signature or shared-secret header
- `channelId`
- `senderUserId`
- `targetDeviceId`
- `targetToken`
- `bundleId`
- `sandbox` flag
- `startedAt`
- `wakeAttemptId` or another idempotency key

The Worker response should include:

- result kind: `sent`, `rejected`, `transport-failed`
- APNs status code if any
- APNs reason/body if any
- sender-side request id / idempotency key

## Why Worker First

Prefer a Worker first, not Containers and not Queues.

### Worker

Use a Worker when:

- the job is one outbound HTTPS request
- low operational overhead matters
- latency matters
- secrets and a small HTTP surface are enough

This is the best fit for APNs wake sending.

### Queues

Do not use Queues for the primary wake path.

Wake delivery is latency-sensitive. If we later want a queue, it should be for:

- audit export
- retries after explicit transport failure
- dead-letter analysis

not the first wake attempt.

### Durable Objects

A Durable Object is optional if we later need:

- stricter idempotency
- per-channel ordering
- retry coordination

It is not required for the first cut.

### Containers

Do not start with Containers.

Containers are heavier than this use case needs. They only become interesting if we later need:

- a custom binary runtime
- long-lived stateful connections
- a non-Worker networking stack

That is not the current problem.

## Cloudflare Plan

### Phase 1: prove the sender

Build a tiny Worker that:

- authenticates a backend request
- sends one APNs request to sandbox
- returns the raw APNs status and body

The first scaffold now lives in:

- [`cloudflare/apns-worker/`](/Users/mau/Development/Turbo/cloudflare/apns-worker)

Success criteria:

- invalid requests produce a real Apple HTTP response
- valid test requests produce an APNs `200`
- no local bridge is required

### Phase 2: wire Turbo backend to the Worker

Change `begin-transmit` so the hosted backend:

- still resolves the token-backed wake target
- calls the Worker instead of APNs directly
- persists the returned wake result into dev wake events

Success criteria:

- merged diagnostics shows authoritative backend-owned wake attempts again
- device testing no longer depends on `ptt-apns-bridge`

### Phase 3: harden

Add:

- shared-secret rotation plan
- idempotency key enforcement
- short timeout + retry policy
- explicit metrics / log fields for APNs outcome classes

## Once Unison Cloud Runtime Catches Up

When the runtime changes are merged and deployed on Unison Cloud:

1. prove hosted Unison can:
   - negotiate `h2`
   - sign ES256 with the builtin crypto surface
   - get a real HTTP response from APNs
2. switch `begin-transmit` back to direct APNs from Unison
3. keep the same wake-event schema and merged diagnostics surface
4. leave the Cloudflare sender in place briefly as rollback insurance
5. then remove the Worker path, shared secret, and related docs

The goal is for the Cloudflare sender to be a temporary transport adapter, not a permanent split-brain control plane.
