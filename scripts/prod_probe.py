#!/usr/bin/env python3

import argparse
import asyncio
import json
import ssl
import subprocess
import sys
import time
import urllib.parse
import uuid

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "The `websockets` package is required. Install it with `python3 -m pip install websockets`."
    ) from exc


class ProbeFailure(RuntimeError):
    pass


def request(base_url: str, path: str, handle: str, method: str = "GET", body: dict | None = None, insecure: bool = False) -> dict:
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
        raw = completed.stdout.strip()
        return json.loads(raw) if raw else {}
    except subprocess.CalledProcessError as exc:
        payload = exc.stderr.strip() or exc.stdout.strip()
        raise ProbeFailure(f"{method} {path} failed: {payload}") from exc


def timed_request(
    base_url: str,
    path: str,
    handle: str,
    method: str = "GET",
    body: dict | None = None,
    insecure: bool = False,
) -> dict:
    started = time.perf_counter()
    payload = request(base_url, path, handle, method=method, body=body, insecure=insecure)
    return {
        "durationMs": int((time.perf_counter() - started) * 1000),
        "payload": payload,
    }


def runtime_inspection(base_url: str, participant: dict, channel_id: str, insecure: bool) -> dict:
    return request(
        base_url,
        f"/v1/dev/runtime/{channel_id}/{urllib.parse.quote(participant['device_id'])}",
        participant["handle"],
        insecure=insecure,
    )


async def receive_json(connection, timeout_seconds: int) -> dict:
    try:
        raw = await asyncio.wait_for(connection.recv(), timeout=timeout_seconds)
        return json.loads(raw)
    except Exception as exc:
        return {"error": repr(exc)}


async def send_signal(
    connection,
    *,
    signal_type: str,
    channel_id: str,
    from_user_id: str,
    from_device_id: str,
    to_user_id: str,
    to_device_id: str,
    payload: str,
) -> None:
    await connection.send(
        json.dumps(
            {
                "type": signal_type,
                "channelId": channel_id,
                "fromUserId": from_user_id,
                "fromDeviceId": from_device_id,
                "toUserId": to_user_id,
                "toDeviceId": to_device_id,
                "payload": payload,
            }
        )
    )


async def expect_signal(
    connection,
    *,
    signal_type: str,
    channel_id: str,
    from_device_id: str,
    to_device_id: str,
) -> dict:
    message = await receive_json(connection, timeout_seconds=10)
    if message.get("type") != signal_type:
        raise ProbeFailure(f"expected {signal_type} signal but received: {message}")
    if message.get("channelId") != channel_id:
        raise ProbeFailure(f"{signal_type} signal targeted wrong channel: {message}")
    if message.get("fromDeviceId") != from_device_id:
        raise ProbeFailure(f"{signal_type} signal came from wrong device: {message}")
    if message.get("toDeviceId") != to_device_id:
        raise ProbeFailure(f"{signal_type} signal targeted wrong device: {message}")
    return message


def channel_state_pair(
    base_url: str,
    caller: dict,
    callee: dict,
    channel_id: str,
    insecure: bool,
) -> tuple[dict, dict]:
    caller_state = request(
        base_url,
        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
        caller["handle"],
        insecure=insecure,
    )
    callee_state = request(
        base_url,
        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(callee['device_id'])}",
        callee["handle"],
        insecure=insecure,
    )
    return caller_state, callee_state


async def wait_for_transmit_ready_pair(
    base_url: str,
    caller: dict,
    callee: dict,
    channel_id: str,
    insecure: bool,
) -> tuple[dict, dict]:
    deadline = time.monotonic() + 12
    last_caller_state: dict = {}
    last_callee_state: dict = {}
    while time.monotonic() < deadline:
        last_caller_state, last_callee_state = channel_state_pair(base_url, caller, callee, channel_id, insecure)
        if last_caller_state.get("canTransmit") and last_callee_state.get("canTransmit"):
            return last_caller_state, last_callee_state
        await asyncio.sleep(0.5)
    return last_caller_state, last_callee_state


async def websocket_roundtrip(
    base_url: str,
    caller: dict,
    callee: dict,
    channel_id: str,
    insecure: bool,
) -> tuple[dict, dict, dict, dict, dict, dict, dict, dict, dict]:
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    sender_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(caller['device_id'])}"
    receiver_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(callee['device_id'])}"
    sender_headers = {
        "x-turbo-user-handle": caller["handle"],
        "Authorization": f"Bearer {caller['handle']}",
    }
    receiver_headers = {
        "x-turbo-user-handle": callee["handle"],
        "Authorization": f"Bearer {callee['handle']}",
    }
    ssl_context = ssl._create_unverified_context() if insecure else ssl.create_default_context()

    async with websockets.connect(receiver_url, additional_headers=receiver_headers, open_timeout=20, ssl=ssl_context) as receiver_ws:
        async with websockets.connect(sender_url, additional_headers=sender_headers, open_timeout=20, ssl=ssl_context) as sender_ws:
            receiver_ack = await receive_json(receiver_ws, timeout_seconds=10)
            sender_ack = await receive_json(sender_ws, timeout_seconds=10)
            if receiver_ack.get("status") != "connected":
                raise ProbeFailure(f"unexpected receiver websocket ack: {receiver_ack}")
            if sender_ack.get("status") != "connected":
                raise ProbeFailure(f"unexpected sender websocket ack: {sender_ack}")
            if receiver_ack.get("deviceId") != callee["device_id"]:
                raise ProbeFailure(f"receiver ack targeted wrong device: {receiver_ack}")
            if sender_ack.get("deviceId") != caller["device_id"]:
                raise ProbeFailure(f"sender ack targeted wrong device: {sender_ack}")

            request(
                base_url,
                f"/v1/channels/{channel_id}/join",
                caller["handle"],
                method="POST",
                body={"deviceId": caller["device_id"]},
                insecure=insecure,
            )
            request(
                base_url,
                f"/v1/channels/{channel_id}/join",
                callee["handle"],
                method="POST",
                body={"deviceId": callee["device_id"]},
                insecure=insecure,
            )

            caller_state, callee_state = await wait_for_transmit_ready_pair(
                base_url,
                caller,
                callee,
                channel_id,
                insecure,
            )
            if not caller_state.get("canTransmit"):
                caller_diag = runtime_inspection(base_url, caller, channel_id, insecure)
                callee_diag = runtime_inspection(base_url, callee, channel_id, insecure)
                raise ProbeFailure(
                    "caller cannot transmit after both joins and websocket connect: "
                    f"callerState={caller_state} callerDiag={caller_diag} calleeDiag={callee_diag}"
                )
            if not callee_state.get("canTransmit"):
                caller_diag = runtime_inspection(base_url, caller, channel_id, insecure)
                callee_diag = runtime_inspection(base_url, callee, channel_id, insecure)
                raise ProbeFailure(
                    "callee cannot transmit after both joins and websocket connect: "
                    f"calleeState={callee_state} callerDiag={caller_diag} calleeDiag={callee_diag}"
                )

            await send_signal(
                receiver_ws,
                signal_type="receiver-ready",
                channel_id=channel_id,
                from_user_id=callee["user_id"],
                from_device_id=callee["device_id"],
                to_user_id=caller["user_id"],
                to_device_id=caller["device_id"],
                payload="receiver-ready",
            )
            callee_ready_forward = await expect_signal(
                sender_ws,
                signal_type="receiver-ready",
                channel_id=channel_id,
                from_device_id=callee["device_id"],
                to_device_id=caller["device_id"],
            )
            await send_signal(
                sender_ws,
                signal_type="receiver-ready",
                channel_id=channel_id,
                from_user_id=caller["user_id"],
                from_device_id=caller["device_id"],
                to_user_id=callee["user_id"],
                to_device_id=callee["device_id"],
                payload="receiver-ready",
            )
            caller_ready_forward = await expect_signal(
                receiver_ws,
                signal_type="receiver-ready",
                channel_id=channel_id,
                from_device_id=caller["device_id"],
                to_device_id=callee["device_id"],
            )

            envelope = {
                "type": "audio-chunk",
                "channelId": channel_id,
                "fromUserId": caller["user_id"],
                "fromDeviceId": caller["device_id"],
                "toUserId": callee["user_id"],
                "toDeviceId": "ignored-by-server",
                "payload": "c21va2U=",
            }
            await sender_ws.send(json.dumps(envelope))
            receiver_message, sender_message = await asyncio.gather(
                receive_json(receiver_ws, timeout_seconds=10),
                receive_json(sender_ws, timeout_seconds=10),
            )
            if receiver_message.get("type") != "audio-chunk":
                caller_diag = runtime_inspection(base_url, caller, channel_id, insecure)
                callee_diag = runtime_inspection(base_url, callee, channel_id, insecure)
                raise ProbeFailure(
                    "receiver did not get routed audio chunk; "
                    f"receiver={receiver_message} sender={sender_message} "
                    f"callerDiag={caller_diag} calleeDiag={callee_diag}"
                )
            if receiver_message.get("fromDeviceId") != caller["device_id"]:
                raise ProbeFailure(
                    "receiver got an audio chunk from the wrong sender device; "
                    f"expected={caller['device_id']} actual={receiver_message.get('fromDeviceId')} "
                    f"receiver={receiver_message}"
                )
            if receiver_message.get("toDeviceId") != callee["device_id"]:
                raise ProbeFailure(
                    "receiver got an audio chunk for the wrong target device; "
                    f"expected={callee['device_id']} actual={receiver_message.get('toDeviceId')} "
                    f"receiver={receiver_message}"
                )

            begin = timed_request(
                base_url,
                f"/v1/channels/{channel_id}/begin-transmit",
                caller["handle"],
                method="POST",
                body={"deviceId": caller["device_id"]},
                insecure=insecure,
            )
            renew = timed_request(
                base_url,
                f"/v1/channels/{channel_id}/renew-transmit",
                caller["handle"],
                method="POST",
                body={"deviceId": caller["device_id"]},
                insecure=insecure,
            )
            end = timed_request(
                base_url,
                f"/v1/channels/{channel_id}/end-transmit",
                caller["handle"],
                method="POST",
                body={"deviceId": caller["device_id"]},
                insecure=insecure,
            )

            return (
                receiver_ack,
                sender_ack,
                caller_state,
                callee_state,
                callee_ready_forward,
                caller_ready_forward,
                receiver_message,
                sender_message,
                begin,
                renew,
                end,
            )


async def main() -> int:
    parser = argparse.ArgumentParser(description="Run a direct production probe against Turbo.")
    parser.add_argument("--base-url", default="https://beepbeep.to")
    parser.add_argument("--caller", default="@quinn")
    parser.add_argument("--callee", default="@sasha")
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    caller = {"handle": args.caller, "device_id": f"probe-{uuid.uuid4()}"}
    callee = {"handle": args.callee, "device_id": f"probe-{uuid.uuid4()}"}

    config = request(args.base_url, "/v1/config", caller["handle"], insecure=args.insecure)
    if not config.get("supportsWebSocket"):
        raise ProbeFailure(f"runtime config does not advertise websocket support: {config}")

    reset_all = request(args.base_url, "/v1/dev/reset-all", caller["handle"], method="POST", insecure=args.insecure)
    if reset_all.get("status") != "reset-all":
        raise ProbeFailure(f"unexpected reset-all payload: {reset_all}")
    reset_state = request(args.base_url, "/v1/dev/reset-state", caller["handle"], method="POST", insecure=args.insecure)
    if reset_state.get("status") != "reset":
        raise ProbeFailure(f"unexpected reset-state payload: {reset_state}")
    request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure)

    for participant in (caller, callee):
        participant["user_id"] = request(
            args.base_url, "/v1/auth/session", participant["handle"], method="POST", insecure=args.insecure
        )["userId"]
        request(
            args.base_url,
            "/v1/devices/register",
            participant["handle"],
            method="POST",
            body={"deviceId": participant["device_id"], "deviceLabel": participant["device_id"]},
            insecure=args.insecure,
        )
        request(
            args.base_url,
            "/v1/presence/heartbeat",
            participant["handle"],
            method="POST",
            body={"deviceId": participant["device_id"]},
            insecure=args.insecure,
        )

    invite = request(
        args.base_url,
        "/v1/invites",
        caller["handle"],
        method="POST",
        body={"otherHandle": callee["handle"]},
        insecure=args.insecure,
    )
    accept = request(
        args.base_url,
        f"/v1/invites/{invite['inviteId']}/accept",
        callee["handle"],
        method="POST",
        insecure=args.insecure,
    )
    if accept.get("accepted") is not True:
        raise ProbeFailure(f"invite accept did not mark the relationship accepted: {accept}")

    direct = request(
        args.base_url,
        "/v1/channels/direct",
        caller["handle"],
        method="POST",
        body={"otherHandle": callee["handle"]},
        insecure=args.insecure,
    )
    channel_id = direct["channelId"]
    if channel_id != accept.get("channelId"):
        raise ProbeFailure(f"direct channel disagreed with accepted invite: direct={direct} accept={accept}")

    (
        receiver_ack,
        sender_ack,
        caller_state,
        callee_state,
        callee_ready_forward,
        caller_ready_forward,
        receiver_message,
        sender_message,
        begin,
        renew,
        end,
    ) = await websocket_roundtrip(
        args.base_url, caller, callee, channel_id, insecure=args.insecure
    )

    for participant in (caller, callee):
        request(
            args.base_url,
            f"/v1/channels/{channel_id}/leave",
            participant["handle"],
            method="POST",
            body={"deviceId": participant["device_id"]},
            insecure=args.insecure,
        )

    print(
        json.dumps(
            {
                "ok": True,
                "baseUrl": args.base_url,
                "channelId": channel_id,
                "callerState": caller_state,
                "calleeState": callee_state,
                "receiverAck": receiver_ack,
                "senderAck": sender_ack,
                "calleeReadyForward": callee_ready_forward,
                "callerReadyForward": caller_ready_forward,
                "receiverMessage": receiver_message,
                "senderMessage": sender_message,
                "beginTransmit": begin,
                "renewTransmit": renew,
                "endTransmit": end,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except ProbeFailure as exc:
        print(f"PROD PROBE FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
