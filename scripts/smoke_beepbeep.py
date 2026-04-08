#!/usr/bin/env python3

import argparse
import asyncio
import json
import ssl
import subprocess
import sys
import uuid
import urllib.parse

try:
    import certifi
except ImportError:  # pragma: no cover
    certifi = None

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "The `websockets` package is required. Install it with `python3 -m pip install websockets`."
    ) from exc


class SmokeFailure(RuntimeError):
    pass


def request(
    base_url: str,
    path: str,
    handle: str,
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
        raw = completed.stdout.strip()
        return json.loads(raw) if raw else {}
    except subprocess.CalledProcessError as exc:
        payload = exc.stderr.strip() or exc.stdout.strip()
        raise SmokeFailure(f"{method} {path} failed: {payload}") from exc


async def websocket_roundtrip(
    base_url: str,
    sender: dict,
    receiver: dict,
    channel_id: str,
    ssl_context: ssl.SSLContext | None,
) -> dict:
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    sender_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(sender['device_id'])}"
    receiver_url = f"{ws_base}/v1/ws?deviceId={urllib.parse.quote(receiver['device_id'])}"
    sender_headers = {
        "x-turbo-user-handle": sender["handle"],
        "Authorization": f"Bearer {sender['handle']}",
    }
    receiver_headers = {
        "x-turbo-user-handle": receiver["handle"],
        "Authorization": f"Bearer {receiver['handle']}",
    }

    last_error: Exception | None = None
    for attempt in range(1, 4):
        try:
            async with websockets.connect(receiver_url, additional_headers=receiver_headers, open_timeout=20, ssl=ssl_context) as receiver_ws:
                async with websockets.connect(sender_url, additional_headers=sender_headers, open_timeout=20, ssl=ssl_context) as sender_ws:
                    receiver_ack = await receive_json_or_timeout(receiver_ws, timeout_seconds=10)
                    sender_ack = await receive_json_or_timeout(sender_ws, timeout_seconds=10)
                    if receiver_ack.get("status") != "connected":
                        raise SmokeFailure(f"unexpected receiver websocket ack payload: {receiver_ack}")
                    if sender_ack.get("status") != "connected":
                        raise SmokeFailure(f"unexpected sender websocket ack payload: {sender_ack}")
                    if receiver_ack.get("deviceId") != receiver["device_id"]:
                        raise SmokeFailure(f"receiver websocket ack did not match device: {receiver_ack}")
                    if sender_ack.get("deviceId") != sender["device_id"]:
                        raise SmokeFailure(f"sender websocket ack did not match device: {sender_ack}")
                    # The server acks after registration, but a short delay makes the
                    # distributed socket lookup materially more stable in production.
                    await asyncio.sleep(0.5)
                    envelope = {
                        "type": "audio-chunk",
                        "channelId": channel_id,
                        "fromUserId": sender["user_id"],
                        "fromDeviceId": sender["device_id"],
                        "toUserId": receiver["user_id"],
                        "toDeviceId": "ignored-by-server",
                        "payload": "c21va2U=",
                    }
                    await sender_ws.send(json.dumps(envelope))
                    receiver_result, sender_result = await asyncio.gather(
                        receive_json_or_timeout(receiver_ws, timeout_seconds=10),
                        receive_json_or_timeout(sender_ws, timeout_seconds=10),
                    )
                    if "error" in receiver_result:
                        if "error" in sender_result:
                            raise SmokeFailure("timed out waiting for websocket signal on both sockets")
                        raise SmokeFailure(f"receiver did not get routed signal; sender saw: {sender_result}")
                    parsed = receiver_result
                    if parsed.get("type") != "audio-chunk":
                        raise SmokeFailure(f"unexpected receiver websocket payload: {parsed}")
                    if parsed["fromUserId"] != sender["user_id"]:
                        raise SmokeFailure(f"unexpected sender in websocket payload: {parsed}")
                    if parsed["toUserId"] != receiver["user_id"]:
                        raise SmokeFailure(f"unexpected receiver user in websocket payload: {parsed}")
                    if parsed["toDeviceId"] != receiver["device_id"]:
                        raise SmokeFailure(f"backend did not rewrite target device correctly: {parsed}")
                    return parsed
        except Exception as exc:  # pragma: no cover
            last_error = exc
            await asyncio.sleep(1.0)
    if last_error is None:
        raise SmokeFailure("websocket roundtrip failed after retries")
    raise SmokeFailure(
        f"websocket roundtrip failed after retries: {type(last_error).__name__}: {last_error!r}"
    )


async def receive_json_or_timeout(connection, timeout_seconds: int) -> dict:
    try:
        raw = await asyncio.wait_for(connection.recv(), timeout=timeout_seconds)
        return json.loads(raw)
    except Exception as exc:
        return {"error": repr(exc)}


async def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke test the deployed Turbo service.")
    parser.add_argument("--base-url", default="https://beepbeep.to")
    parser.add_argument("--caller", default="@avery")
    parser.add_argument("--callee", default="@blake")
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    if args.insecure:
        ssl_context = ssl._create_unverified_context()
    elif certifi is not None:
        ssl_context = ssl.create_default_context(cafile=certifi.where())
    else:
        ssl_context = ssl.create_default_context()

    caller = {
        "handle": args.caller,
        "device_id": f"smoke-{uuid.uuid4()}",
    }
    callee = {
        "handle": args.callee,
        "device_id": f"smoke-{uuid.uuid4()}",
    }

    config = request(args.base_url, "/v1/config", caller["handle"], insecure=args.insecure)
    if not config.get("supportsWebSocket"):
        raise SmokeFailure(f"runtime config does not advertise websocket support: {config}")

    request(args.base_url, "/v1/dev/seed", caller["handle"], method="POST", insecure=args.insecure)

    for participant in (caller, callee):
        session = request(args.base_url, "/v1/auth/session", participant["handle"], method="POST", insecure=args.insecure)
        participant["user_id"] = session["userId"]
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

    direct = request(
        args.base_url,
        "/v1/channels/direct",
        caller["handle"],
        method="POST",
        body={"otherHandle": callee["handle"]},
        insecure=args.insecure,
    )
    channel_id = direct["channelId"]

    request(
        args.base_url,
        f"/v1/channels/{channel_id}/join",
        caller["handle"],
        method="POST",
        body={"deviceId": caller["device_id"]},
        insecure=args.insecure,
    )
    request(
        args.base_url,
        f"/v1/channels/{channel_id}/join",
        callee["handle"],
        method="POST",
        body={"deviceId": callee["device_id"]},
        insecure=args.insecure,
    )

    caller_state = request(
        args.base_url,
        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
        caller["handle"],
        insecure=args.insecure,
    )
    callee_state = request(
        args.base_url,
        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(callee['device_id'])}",
        callee["handle"],
        insecure=args.insecure,
    )
    if not caller_state.get("canTransmit"):
        raise SmokeFailure(f"caller cannot transmit after both joins: {caller_state}")
    if not callee_state.get("canTransmit"):
        raise SmokeFailure(f"callee cannot transmit after both joins: {callee_state}")

    ws_payload = await websocket_roundtrip(args.base_url, caller, callee, channel_id, ssl_context)

    begin = request(
        args.base_url,
        f"/v1/channels/{channel_id}/begin-transmit",
        caller["handle"],
        method="POST",
        body={"deviceId": caller["device_id"]},
        insecure=args.insecure,
    )
    if begin.get("targetDeviceId") != callee["device_id"]:
        raise SmokeFailure(f"begin-transmit targeted the wrong device: {begin}")

    renew = request(
        args.base_url,
        f"/v1/channels/{channel_id}/renew-transmit",
        caller["handle"],
        method="POST",
        body={"deviceId": caller["device_id"]},
        insecure=args.insecure,
    )
    if renew.get("status") != "transmitting":
        raise SmokeFailure(f"renew-transmit failed: {renew}")

    end = request(
        args.base_url,
        f"/v1/channels/{channel_id}/end-transmit",
        caller["handle"],
        method="POST",
        body={"deviceId": caller["device_id"]},
        insecure=args.insecure,
    )
    if end.get("status") != "idle":
        raise SmokeFailure(f"end-transmit failed: {end}")

    for participant in (caller, callee):
        request(
            args.base_url,
            f"/v1/channels/{channel_id}/leave",
            participant["handle"],
            method="POST",
            body={"deviceId": participant["device_id"]},
        insecure=args.insecure,
    )

    print(json.dumps({
        "ok": True,
        "baseUrl": args.base_url,
        "channelId": channel_id,
        "websocketPayload": ws_payload,
        "beginTransmit": begin,
    }, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except SmokeFailure as exc:
        print(f"SMOKE TEST FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
