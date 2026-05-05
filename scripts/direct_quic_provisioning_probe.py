#!/usr/bin/env python3

from __future__ import annotations

import argparse
import asyncio
import urllib.parse
import uuid

from route_probe import (
    connected_websocket_pair,
    direct_quic_identity_for_device,
    request,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def participant(handle: str, prefix: str) -> dict[str, str]:
    return {
        "handle": handle,
        "device_id": f"{prefix}-{uuid.uuid4()}",
    }


def peer_identity_fingerprint(payload: dict) -> str | None:
    identity = payload.get("peerDirectQuicIdentity")
    if not isinstance(identity, dict):
        return None
    if identity.get("status") != "active":
        return None
    fingerprint = identity.get("fingerprint")
    return fingerprint if isinstance(fingerprint, str) else None


async def main() -> int:
    parser = argparse.ArgumentParser(description="Verify deployed Direct QUIC provisioning metadata.")
    parser.add_argument("--base-url", default="https://beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    caller = participant(args.caller, "direct-quic-probe-caller")
    callee = participant(args.callee, "direct-quic-probe-callee")

    config = request(args.base_url, "/v1/config", caller["handle"], insecure=args.insecure)
    require(
        config.get("supportsDirectQuicProvisioning") is True,
        f"backend did not advertise Direct QUIC provisioning support: {config}",
    )
    require(
        config.get("supportsDirectQuicUpgrade") is False,
        f"Direct QUIC upgrade should remain globally gated during provisioning smoke: {config}",
    )

    request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure)
    request(args.base_url, "/v1/dev/reset-state", caller["handle"], method="POST", insecure=args.insecure)
    request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure)

    for current in (caller, callee):
        session = request(args.base_url, "/v1/auth/session", current["handle"], method="POST", insecure=args.insecure)
        current["user_id"] = session["userId"]
        current["identity"] = direct_quic_identity_for_device(current["device_id"])
        registered = request(
            args.base_url,
            "/v1/devices/register",
            current["handle"],
            method="POST",
            body={
                "deviceId": current["device_id"],
                "deviceLabel": current["device_id"],
                "directQuicIdentity": current["identity"],
            },
            insecure=args.insecure,
        )
        require(
            registered.get("directQuicIdentity", {}).get("fingerprint") == current["identity"]["fingerprint"],
            f"registration did not round-trip Direct QUIC identity for {current['handle']}: {registered}",
        )

    preserved = request(
        args.base_url,
        "/v1/devices/register",
        caller["handle"],
        method="POST",
        body={
            "deviceId": caller["device_id"],
            "deviceLabel": caller["device_id"],
        },
        insecure=args.insecure,
    )
    require(
        preserved.get("directQuicIdentity", {}).get("fingerprint") == caller["identity"]["fingerprint"],
        f"registration without identity did not preserve Direct QUIC metadata: {preserved}",
    )

    invite = request(
        args.base_url,
        "/v1/invites",
        caller["handle"],
        method="POST",
        body={"otherHandle": callee["handle"]},
        insecure=args.insecure,
    )
    accepted = request(
        args.base_url,
        f"/v1/invites/{invite['inviteId']}/accept",
        callee["handle"],
        method="POST",
        insecure=args.insecure,
    )
    channel_id = accepted["channelId"]

    async with connected_websocket_pair(args.base_url, caller, callee, args.insecure):
        for current in (caller, callee):
            request(
                args.base_url,
                f"/v1/channels/{channel_id}/join",
                current["handle"],
                method="POST",
                body={"deviceId": current["device_id"]},
                insecure=args.insecure,
            )

        caller_readiness = request(
            args.base_url,
            f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
            caller["handle"],
            insecure=args.insecure,
        )
        callee_readiness = request(
            args.base_url,
            f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
            callee["handle"],
            insecure=args.insecure,
        )

    require(
        peer_identity_fingerprint(caller_readiness) == callee["identity"]["fingerprint"],
        f"caller readiness did not project callee Direct QUIC identity: {caller_readiness}",
    )
    require(
        peer_identity_fingerprint(callee_readiness) == caller["identity"]["fingerprint"],
        f"callee readiness did not project caller Direct QUIC identity: {callee_readiness}",
    )

    print(
        "DIRECT QUIC PROVISIONING PROBE PASSED: "
        f"{caller['device_id']} <-> {callee['device_id']} against {args.base_url}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
