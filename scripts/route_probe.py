#!/usr/bin/env python3

import argparse
import asyncio
import contextlib
import json
import ssl
import subprocess
import sys
import urllib.parse
import uuid
from dataclasses import asdict, dataclass
from typing import Any

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "The `websockets` package is required. Install it with `python3 -m pip install websockets`."
    ) from exc


class RouteProbeFailure(RuntimeError):
    pass


@dataclass
class CheckResult:
    name: str
    ok: bool
    detail: str
    payload: Any | None = None


def request(
    base_url: str,
    path: str,
    handle: str,
    *,
    method: str = "GET",
    body: dict | None = None,
    insecure: bool = False,
) -> dict | list:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    command = [
        "curl",
        "-sS",
        "--fail-with-body",
        "-X",
        method,
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
    ]
    if insecure:
        command.append("-k")
    if body is not None:
        command.extend(["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)])
    command.append(url)
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        payload = exc.stderr.strip() or exc.stdout.strip()
        raise RouteProbeFailure(f"{method} {path} failed: {payload}") from exc
    raw = completed.stdout.strip()
    return json.loads(raw) if raw else {}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RouteProbeFailure(message)


async def receive_json_or_timeout(connection, timeout_seconds: int) -> dict:
    try:
        raw = await asyncio.wait_for(connection.recv(), timeout=timeout_seconds)
        return json.loads(raw)
    except Exception as exc:
        return {"error": repr(exc)}


@contextlib.asynccontextmanager
async def connected_websocket_pair(
    base_url: str,
    caller: dict[str, str],
    callee: dict[str, str],
    insecure: bool,
):
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    caller_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(caller['device_id'])}"
    callee_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(callee['device_id'])}"
    caller_headers = {
        "x-turbo-user-handle": caller["handle"],
        "Authorization": f"Bearer {caller['handle']}",
    }
    callee_headers = {
        "x-turbo-user-handle": callee["handle"],
        "Authorization": f"Bearer {callee['handle']}",
    }
    ssl_context = ssl._create_unverified_context() if insecure else ssl.create_default_context()
    async with websockets.connect(
        callee_url,
        additional_headers=callee_headers,
        open_timeout=20,
        ssl=ssl_context,
    ) as callee_ws:
        async with websockets.connect(
            caller_url,
            additional_headers=caller_headers,
            open_timeout=20,
            ssl=ssl_context,
        ) as caller_ws:
            callee_ack = await receive_json_or_timeout(callee_ws, timeout_seconds=10)
            caller_ack = await receive_json_or_timeout(caller_ws, timeout_seconds=10)
            require(callee_ack.get("status") == "connected", f"unexpected callee ack: {callee_ack}")
            require(caller_ack.get("status") == "connected", f"unexpected caller ack: {caller_ack}")
            require(callee_ack.get("deviceId") == callee["device_id"], f"callee ack targeted wrong device: {callee_ack}")
            require(caller_ack.get("deviceId") == caller["device_id"], f"caller ack targeted wrong device: {caller_ack}")
            yield {
                "caller": caller_ws,
                "callee": callee_ws,
                "callerAck": caller_ack,
                "calleeAck": callee_ack,
            }


def run_check(results: list[CheckResult], name: str, fn) -> Any:
    try:
        payload = fn()
        results.append(CheckResult(name=name, ok=True, detail="ok", payload=payload))
        return payload
    except Exception as exc:
        results.append(CheckResult(name=name, ok=False, detail=str(exc)))
        raise


def participant(handle: str, prefix: str) -> dict[str, str]:
    return {
        "handle": handle,
        "device_id": f"{prefix}-{uuid.uuid4()}",
    }


async def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Turbo's deployed HTTP route surface.")
    parser.add_argument("--base-url", default="https://beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--insecure", action="store_true")
    parser.add_argument("--json", action="store_true", help="Print the full JSON report even on success.")
    args = parser.parse_args()

    results: list[CheckResult] = []
    caller = participant(args.caller, "route-probe-caller")
    callee = participant(args.callee, "route-probe-callee")

    try:
        config = run_check(
            results,
            "config",
            lambda: request(args.base_url, "/v1/config", caller["handle"], insecure=args.insecure),
        )
        require(isinstance(config, dict), f"/v1/config returned unexpected payload: {config}")

        run_check(
            results,
            "dev-seed",
            lambda: request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure),
        )
        reset_all = run_check(
            results,
            "dev-reset-all",
            lambda: request(args.base_url, "/v1/dev/reset-all", caller["handle"], method="POST", insecure=args.insecure),
        )
        require(reset_all.get("status") == "reset-all", f"unexpected reset-all payload: {reset_all}")
        reset_state = run_check(
            results,
            "dev-reset-state",
            lambda: request(args.base_url, "/v1/dev/reset-state", caller["handle"], method="POST", insecure=args.insecure),
        )
        require(reset_state.get("status") == "reset", f"unexpected reset-state payload: {reset_state}")
        run_check(
            results,
            "dev-seed-after-reset",
            lambda: request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure),
        )

        for current in (caller, callee):
            session = run_check(
                results,
                f"auth-session:{current['handle']}",
                lambda current=current: request(args.base_url, "/v1/auth/session", current["handle"], method="POST", insecure=args.insecure),
            )
            require(session.get("handle") == current["handle"], f"auth session mismatched handle: {session}")
            current["user_id"] = session["userId"]

            device = run_check(
                results,
                f"device-register:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/devices/register",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"], "deviceLabel": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(device.get("deviceId") == current["device_id"], f"device registration mismatched id: {device}")

            diagnostics_upload = run_check(
                results,
                f"diagnostics-upload:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics",
                    current["handle"],
                    method="POST",
                    body={
                        "deviceId": current["device_id"],
                        "appVersion": "route-probe",
                        "backendBaseURL": args.base_url,
                        "selectedHandle": callee["handle"] if current is caller else caller["handle"],
                        "snapshot": f"snapshot for {current['handle']}",
                        "transcript": f"transcript for {current['handle']}",
                    },
                    insecure=args.insecure,
                ),
            )
            require(diagnostics_upload.get("status") == "uploaded", f"diagnostics upload failed: {diagnostics_upload}")

            diagnostics_latest = run_check(
                results,
                f"diagnostics-latest:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/dev/diagnostics/latest/{urllib.parse.quote(current['device_id'])}",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require(diagnostics_latest.get("status") == "ok", f"diagnostics latest failed: {diagnostics_latest}")

            diagnostics_latest_for_user = run_check(
                results,
                f"diagnostics-latest-current:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics/latest",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require(
                diagnostics_latest_for_user.get("status") == "ok",
                f"diagnostics latest current-user failed: {diagnostics_latest_for_user}",
            )

            heartbeat = run_check(
                results,
                f"presence-heartbeat:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/presence/heartbeat",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(heartbeat.get("deviceId") == current["device_id"], f"presence heartbeat mismatched device: {heartbeat}")

            user_lookup = run_check(
                results,
                f"user-by-handle:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/users/by-handle/{urllib.parse.quote(current['handle'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(user_lookup.get("handle") == current["handle"], f"user lookup mismatched handle: {user_lookup}")

            presence_lookup = run_check(
                results,
                f"user-presence:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/users/by-handle/{urllib.parse.quote(current['handle'])}/presence",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(isinstance(presence_lookup, dict), f"presence lookup returned unexpected payload: {presence_lookup}")

        caller_summaries = run_check(
            results,
            "contact-summaries:caller",
            lambda: request(
                args.base_url,
                f"/v1/contacts/summaries/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require(isinstance(caller_summaries, list), f"contact summaries returned unexpected payload: {caller_summaries}")

        invite_cancel = run_check(
            results,
            "invite-create:cancel-flow",
            lambda: request(
                args.base_url,
                "/v1/invites",
                caller["handle"],
                method="POST",
                body={"otherHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        run_check(
            results,
            "invite-outgoing:list",
            lambda: request(args.base_url, "/v1/invites/outgoing", caller["handle"], insecure=args.insecure),
        )
        cancel_payload = run_check(
            results,
            "invite-cancel",
            lambda: request(
                args.base_url,
                f"/v1/invites/{invite_cancel['inviteId']}/cancel",
                caller["handle"],
                method="POST",
                insecure=args.insecure,
            ),
        )
        require(cancel_payload.get("status") == "cancelled", f"cancel route returned unexpected payload: {cancel_payload}")

        invite_decline = run_check(
            results,
            "invite-create:decline-flow",
            lambda: request(
                args.base_url,
                "/v1/invites",
                caller["handle"],
                method="POST",
                body={"otherHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        run_check(
            results,
            "invite-incoming:list",
            lambda: request(args.base_url, "/v1/invites/incoming", callee["handle"], insecure=args.insecure),
        )
        decline_payload = run_check(
            results,
            "invite-decline",
            lambda: request(
                args.base_url,
                f"/v1/invites/{invite_decline['inviteId']}/decline",
                callee["handle"],
                method="POST",
                insecure=args.insecure,
            ),
        )
        require(decline_payload.get("status") == "declined", f"decline route returned unexpected payload: {decline_payload}")

        invite_accept = run_check(
            results,
            "invite-create:accept-flow",
            lambda: request(
                args.base_url,
                "/v1/invites",
                caller["handle"],
                method="POST",
                body={"otherHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        accept_payload = run_check(
            results,
            "invite-accept",
            lambda: request(
                args.base_url,
                f"/v1/invites/{invite_accept['inviteId']}/accept",
                callee["handle"],
                method="POST",
                insecure=args.insecure,
            ),
        )
        require(accept_payload.get("accepted") is True, f"accept route did not mark invite accepted: {accept_payload}")
        require(accept_payload.get("pendingJoin") is True, f"accept route did not report pending join: {accept_payload}")
        accepted_channel_id = accept_payload["channelId"]

        direct = run_check(
            results,
            "channel-direct",
            lambda: request(
                args.base_url,
                "/v1/channels/direct",
                caller["handle"],
                method="POST",
                body={"otherHandle": callee["handle"]},
                insecure=args.insecure,
            ),
        )
        require(direct.get("channelId") == accepted_channel_id, f"direct channel disagreed with accepted invite channel: {direct}")
        channel_id = direct["channelId"]

        for current in (caller, callee):
            join_payload = run_check(
                results,
                f"channel-join:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/join",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(join_payload.get("channelId") == channel_id, f"join route mismatched channel: {join_payload}")

        async with connected_websocket_pair(args.base_url, caller, callee, args.insecure) as websocket_pair:
            results.append(
                CheckResult(
                    name="websocket-register",
                    ok=True,
                    detail="both websocket endpoints acknowledged the expected device id and stayed connected for readiness checks",
                    payload={"callerAck": websocket_pair["callerAck"], "calleeAck": websocket_pair["calleeAck"]},
                )
            )

            caller_state = run_check(
                results,
                "channel-state:caller",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            callee_state = run_check(
                results,
                "channel-state:callee",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/state/{urllib.parse.quote(callee['device_id'])}",
                    callee["handle"],
                    insecure=args.insecure,
                ),
            )
            require(caller_state.get("canTransmit") is True, f"caller cannot transmit after websocket registration: {caller_state}")
            require(callee_state.get("canTransmit") is True, f"callee cannot transmit after websocket registration: {callee_state}")

            caller_readiness = run_check(
                results,
                "channel-readiness:caller",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(isinstance(caller_readiness, dict), f"readiness returned unexpected payload: {caller_readiness}")

            run_check(
                results,
                "channel-ephemeral-token",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/ephemeral-token",
                    callee["handle"],
                    method="POST",
                    body={"deviceId": callee["device_id"], "token": "route-probe-token"},
                    insecure=args.insecure,
                ),
            )

            begin_payload = run_check(
                results,
                "channel-begin-transmit",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/begin-transmit",
                    caller["handle"],
                    method="POST",
                    body={"deviceId": caller["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(begin_payload.get("status") == "transmitting", f"begin-transmit returned unexpected payload: {begin_payload}")

            push_target = run_check(
                results,
                "channel-ptt-push-target",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/ptt-push-target",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            require(push_target.get("targetDeviceId") == callee["device_id"], f"ptt push target mismatched device: {push_target}")

            renew_payload = run_check(
                results,
                "channel-renew-transmit",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/renew-transmit",
                    caller["handle"],
                    method="POST",
                    body={"deviceId": caller["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(renew_payload.get("status") == "transmitting", f"renew-transmit returned unexpected payload: {renew_payload}")

            end_payload = run_check(
                results,
                "channel-end-transmit",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/end-transmit",
                    caller["handle"],
                    method="POST",
                    body={"deviceId": caller["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(end_payload.get("status") == "idle", f"end-transmit returned unexpected payload: {end_payload}")

        for current in (caller, callee):
            leave_payload = run_check(
                results,
                f"channel-leave:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/leave",
                    current["handle"],
                    method="POST",
                    body={"deviceId": current["device_id"]},
                    insecure=args.insecure,
                ),
            )
            require(leave_payload.get("channelId") == channel_id, f"leave route mismatched channel: {leave_payload}")

    except RouteProbeFailure as exc:
        report = {
            "ok": False,
            "baseUrl": args.base_url,
            "checks": [asdict(result) for result in results],
            "error": str(exc),
        }
        print(json.dumps(report, indent=2))
        return 1

    report = {
        "ok": True,
        "baseUrl": args.base_url,
        "checks": [asdict(result) for result in results],
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"ROUTE PROBE PASSED: {len(results)} checks against {args.base_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
