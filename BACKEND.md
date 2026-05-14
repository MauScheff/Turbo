# Backend / Control-Plane Guide

Status: active backend working guide.

Canonical home for backend ownership rules, storage/query design constraints, schema-change discipline, backend invariants, and app/backend bug triage.

Related docs:

- [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) owns exact deploy, probe, APNs helper, local server, and diagnostics commands.
- [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md) owns the quick Unison namespace map.
- [`Server/backend_architecture.md`](/Users/mau/Development/Turbo/Server/backend_architecture.md) owns the agreed v1 backend architecture reference.
- [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md) owns the current interim APNs delivery plan.

Use this file for backend, Unison Cloud, routes, storage/query design, deploy/probe work, and APNs wake-path debugging.

Use [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md) for the canonical ownership, invariant, modeling, and proof model.

## Scope

The backend should act as the control plane, not the media plane.

Unless the user explicitly changes scope, keep the backend focused on:

- dev auth and a simple user directory
- device registration
- stable backend-owned 1:1 direct channels
- channel membership checks
- ephemeral PTT token ingest and storage
- websocket signaling for control-plane notices and future transport setup
- single active transmitter enforcement per channel
- local stub push sender for development

Explicit non-goal for v1:

- media relay or SFU

## Authoritative architecture docs

Start here for backend design:

- [`Server/backend_architecture.md`](/Users/mau/Development/Turbo/Server/backend_architecture.md)
- [`BACKEND_STRUCTURE.md`](/Users/mau/Development/Turbo/BACKEND_STRUCTURE.md)

## Unison Cloud storage rules

When changing backend storage or query paths in this repo:

- Design `OrderedTable` schemas from the queries outward, not from the entity shape inward.
- Prefer compound keys plus `OrderedTable.rangeClosed.prefix` for per-user or per-channel reads.
- Do not stream whole tables and filter in memory on hot paths if a query-shaped key can exist instead.
- Add explicit secondary projections when the product needs multiple access patterns.
- Keep transactional writes small and focused. If a route or mutation touches many rows, stop and reconsider the schema or split the work.
- Keep secondary indexes and projections updated in the same transaction as the primary write.
- When adding a new projection, update reset/dev-cleanup paths in the same change.
- Treat route-level scans over all users, channels, or invites as a design smell unless the dataset is provably bounded and non-hot.
- For contact/session queries, optimize for the active user's relationship-backed subset, not the entire dev directory.

If a hosted failure looks like an intermittent server error, check transaction shape and table-scan behavior before blaming the platform.

## Current-truth projection rules

Stale rows may exist, but stale rows must never be sufficient to project current truth. Call-critical backend projections should derive from typed current-state predicates, not raw storage rows.

Classify every call-critical backend fact before using it to authorize, display, or route behavior:

- durable/monotonic: facts that can safely accumulate or remain true until explicitly superseded
- leased/epoched runtime state: presence, readiness, signaling authorization, wake target, active transmit, relay/session facts, and anything that can become false because time, connection, device, or ownership changed

Runtime truth should be leased, fenced, expiring, or invalidated. A route should not treat an old presence row, readiness row, token row, websocket row, or active-transmit row as current unless the typed predicate says it is current for the relevant user, device, channel, session, and epoch.

## Persisted schema changes

Unison Cloud table values are serialized using the Unison value/type shape. If a durable value type changes, existing rows may no longer deserialize. Treat that as a schema migration, not as a harmless refactor.

Use [`MIGRATIONS.md`](/Users/mau/Development/Turbo/MIGRATIONS.md) for the full Turbo workflow.

When changing any type stored in an `OrderedTable`:

1. Identify every table that stores the type, including secondary projections and dev/diagnostics tables.
2. Decide whether production data must be preserved, migrated, or can be intentionally reset.
3. If data must be preserved, keep enough old definitions available to read the old rows and write the new rows, or create a versioned table/type path such as a `_v2` table name.
4. Update reset/dev-cleanup paths in the same change.
5. Update `turbo.schemaDrift` fixtures for any new persisted value type.
6. Update `turbo.schemaDrift.expectedHashes` only when the migration/reset decision is deliberate and reviewed.
7. Run `turbo.schemaDrift.check` before deploy. `just deploy` does this automatically via `just backend-schema-drift-test`.

If production is already in the bad state, the usual recovery path is to redeploy code that can deserialize the existing rows, migrate or delete the affected rows intentionally, then deploy the new schema. Rotating the environment/database is a last-resort reset, not the normal fix.

## Backend invariants

Backend-owned truth uses the shared invariant system described in [`INVARIANTS.md`](/Users/mau/Development/Turbo/INVARIANTS.md):

- when the backend is authoritative for a fact, detect the invariant at the backend seam
- emit a stable invariant ID for the broken truth through `turbo.service.internal.appendInvariantEvent`
- keep backend dev invariant events visible through `/v1/dev/invariant-events/recent`
- prefer `backend.*` or `channel.*` IDs for backend-owned rules
- keep the same invariant ID aligned across backend diagnostics, merged diagnostics, and regressions

Typical backend-owned invariants here include:

- single active transmitter per channel
- canonical readiness consistency
- valid wake-target selection
- request or membership projections that must not contradict stored backend truth

Do not make the client prove a rule that only the backend can know.

## Mixed app/backend bug workflow

For distributed-state or app/backend contract bugs, follow [`WORKFLOW.md`](/Users/mau/Development/Turbo/WORKFLOW.md). Do not assume the first visible client symptom is the source.

For Turbo, the backend is usually authoritative for:

- channel membership and readiness
- wake-target availability
- direct-channel request/session truth
- pair/session convergence after reconnect, retry, or disconnect

If the backend can project stale, contradictory, or one-sided session truth, fix that in the backend even if the client also needs to fail closed more clearly.

## Verification loops

Use [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md) for exact deploy, postdeploy, route-probe, reset, local-server, and simulator-scenario commands.

Backend-specific verification rules:

- If backend behavior changed in the local Unison codebase, that change is not live on `https://beepbeep.to` until `turbo.deploy` has actually run.
- If an interactive `ucm` process is already holding the local codebase, a wrapper that starts another UCM process can block; use the existing MCP/UCM session to run `turbo.deploy`.
- Hosted verification should prove the live control-plane surface, not just that deployment returned successfully.
- Local backend verification should use the same backend implementation through `turbo.serveLocal`; do not introduce a fake local backend to make tests pass.

## APNs / wake debugging

Keep APNs credentials out of the repo. Exact environment variable names and helper commands live in [`TOOLING.md`](/Users/mau/Development/Turbo/TOOLING.md); the current interim delivery design lives in [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md).

Backend APNs rules:

- `turbo.deploy` must copy required APNs config into cloud config; deployed backend code should read config values, not local filesystem paths.
- Runtime config must be verified from the live deployed service, not inferred from local shell state.
- Wake-send attempts should be recorded in backend diagnostics so merged diagnostics can show the wake timeline inline.

## Deploying new backend env vars

When adding a new backend config key:

1. add it to the local deploy environment
2. make `turbo.deploy` copy it into the cloud environment
3. make the deployed service able to report whether it sees the value at runtime

This is part of the implementation, not optional operational cleanup. A new backend env var is not considered fully deployed until the running service can confirm it sees it.

For background / lock-screen PushToTalk work, treat the loop as:

1. prove the receiver token exists through the backend wake-target surface
2. use the current production APNs sender path documented in [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md)
3. only then use physical-device diagnostics to debug post-wake playback or Apple PTT behavior

The intended long-term wake architecture is:

- the backend owns wake-target selection
- `begin-transmit` builds the APNs JWT in Unison and sends the `pushtotalk` wake directly with `Http.request`
- wake-send results are written to dev wake events so merged diagnostics can show the send timeline inline

Current reality is different:

- hosted direct APNs-from-Unison is blocked on the current Unison Cloud runtime
- local runtime work proves the missing ALPN / HTTP/2 and P-256 builtin pieces
- until that runtime is merged and deployed upstream, use the external sender plan in [`APNS_DELIVERY_PLAN.md`](/Users/mau/Development/Turbo/APNS_DELIVERY_PLAN.md)

`ptt-apns-bridge` and `ptt-apns-worker` remain available only as legacy/debug tooling. The preferred interim production path is the backend-triggered Cloudflare sender, not the old pair-specific bridge.

`ptt-push-target` returning a real token means the token-upload/backend-send boundary is healthy. If wake still fails after that, the bug is in app wake handling or playback, not in Apple Developer credential setup.

Wake-ready transmit also requires the backend transmit-target selector to accept a token-backed receiver device when the peer is wake-capable but cannot receive foreground audio, including the case where websocket presence is still visible but the receiver has already published `receiver-not-ready`; otherwise the app will show `Hold to talk to wake ...` but `beginTransmit` will still fail server-side.

For current architecture work, treat `/v1/channels/{channelId}/readiness/{deviceId}` as the canonical wake-capability view too:

- `audioReadiness` answers "can the connected peer hear right now?"
- `wakeReadiness` answers "if the peer is disconnected, does the backend currently know a wake-capable device target for this channel?"

Do not make the app infer wake capability only from disconnected presence plus local token assumptions.

Token revocation is backend-owned. `POST /v1/channels/{channelId}/ephemeral-token/revoke` removes the current device's channel-scoped PTT token and APNs environment row. If that token was the active transmit target's only non-ready wake path, the backend clears active transmit so the channel cannot remain live without an addressable receiver.
