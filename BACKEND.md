# Backend / Control-Plane Guide

Use this file for backend, Unison Cloud, routes, storage/query design, deploy/probe work, and APNs wake-path debugging.

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

- [`Server/unison_ptt_handoff.md`](/Users/mau/Development/Turbo/Server/unison_ptt_handoff.md)
- [`Server/backend_architecture.md`](/Users/mau/Development/Turbo/Server/backend_architecture.md)

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

## Verification loops

Deploy / probe:

- `just deploy`
- `just route-probe`
- `just reset-all https://beepbeep.to`

Local backend loop:

- `just serve-local`
- `just simulator-scenario-local foreground-ptt http://localhost:8090/s/turbo`
- `just simulator-scenario-merge-local http://localhost:8090/s/turbo`

## APNs / wake debugging

For background / lock-screen PushToTalk work, treat the loop as:

1. `direnv exec . just ptt-push-target <channel_id> <backend> <sender>` to prove the receiver token exists
2. `direnv exec . just ptt-apns-bridge` to prove real wake pushes are being sent
3. only then use physical-device diagnostics to debug post-wake playback or Apple PTT behavior

`ptt-push-target` returning a real token means the token-upload/backend-send boundary is healthy. If wake still fails after that, the bug is in app wake handling or playback, not in Apple Developer credential setup.

Wake-ready transmit also requires the backend transmit-target selector to accept a token-backed receiver device when websocket presence is absent; otherwise the app will show `Hold to talk to wake ...` but `beginTransmit` will still fail server-side.
