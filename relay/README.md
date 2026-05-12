# Turbo Media Relay

Small canary relay for Turbo audio and peer hint frames.

The relay is intentionally dumb:

- Unison remains the control plane.
- The relay only validates a shared canary token, joins two device IDs into a session, and forwards encrypted audio payloads plus non-authoritative peer hint frames.
- QUIC is tried first by the iOS client, then TCP/TLS, then the app falls back to the existing Unison/WebSocket relay.

## Runtime Config

Required:

```bash
export TURBO_RELAY_CERT_PEM=/etc/letsencrypt/live/relay.beepbeep.to/fullchain.pem
export TURBO_RELAY_KEY_PEM=/etc/letsencrypt/live/relay.beepbeep.to/privkey.pem
export TURBO_RELAY_SHARED_TOKEN=''
```

Optional:

```bash
export TURBO_RELAY_QUIC_ADDR=0.0.0.0:9443
export TURBO_RELAY_TCP_ADDR=0.0.0.0:9444
export TURBO_RELAY_SESSION_TTL_SECONDS=180
```

## Build

```bash
cargo build --release
```

## Run

```bash
RUST_LOG=info ./target/release/relay
```

## DNS / GCP

For the first production canary:

1. Create one small GCP VM with a static external IP.
2. Open UDP `9443` and TCP `9444`.
3. Keep DNS in Cloudflare and add `relay.beepbeep.to` pointing to the GCP static IP.
4. Leave that DNS record DNS-only for now. Do not proxy it through normal Cloudflare HTTP proxying; QUIC/UDP needs direct reachability unless we later add Spectrum.
5. Put a public TLS certificate for `relay.beepbeep.to` on the VM.

Canonical GCP project:

```bash
export TURBO_RELAY_GCP_PROJECT=beep-beep-495919
```

Current canary deployment:

```text
project: beep-beep-495919
region: europe-west6
zone: europe-west6-a
vm: turbo-relay-1
static ip: 34.65.146.215
dns: relay.beepbeep.to -> 34.65.146.215, DNS-only in Cloudflare
quic: udp/9443
tcp/tls: tcp/9444
systemd service: turbo-relay
env file on VM: /etc/turbo-relay/env
```

Use the env var in setup commands instead of relying on the active `gcloud`
project:

```bash
gcloud config set project "$TURBO_RELAY_GCP_PROJECT"
gcloud compute instances list --project "$TURBO_RELAY_GCP_PROJECT"
```

## iOS Canary Config

The app reads:

```bash
TURBO_DEBUG_MEDIA_RELAY_ENABLED=true
TURBO_DEBUG_FORCE_MEDIA_RELAY=false
TURBO_MEDIA_RELAY_HOST=relay.beepbeep.to
TURBO_MEDIA_RELAY_QUIC_PORT=9443
TURBO_MEDIA_RELAY_TCP_PORT=9444
TURBO_MEDIA_RELAY_TOKEN=''
```

The diagnostics pane also exposes:

- `Enable media relay`
- `Force media relay`
- relay configured/active state
- relay host and ports

For the first canary, the relay token is intentionally empty so physical-device
testing only needs the diagnostics toggles. Use `Force media relay` only when
testing the relay path explicitly. Normal canary mode should leave Direct QUIC
P2P first and use the relay as fallback.
