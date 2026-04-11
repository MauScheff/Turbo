#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import time

from send_ptt_apns import APNSJWTProvider, load_private_key_pem, send_apns


def request_json(url: str, handle: str, method: str = "GET", body: dict | None = None, insecure: bool = False) -> tuple[int, dict]:
    command = [
        "curl",
        "-sS",
        "-X",
        method,
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
        "-H",
        "Accept: application/json",
        "-w",
        "\n%{http_code}",
    ]
    if insecure:
        command.append("-k")
    if body is not None:
        command.extend(["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)])
    command.append(url)
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
        raw = completed.stdout
    except subprocess.CalledProcessError as error:
        raw = error.stdout or error.stderr or ""
    payload_text, _, status_text = raw.rpartition("\n")
    try:
        payload = json.loads(payload_text) if payload_text.strip() else {}
    except json.JSONDecodeError:
        payload = {"error": payload_text.strip()}
    try:
        status = int(status_text.strip())
    except ValueError:
        status = 0
    return status, payload


def direct_channel(base_url: str, handle: str, other_handle: str, insecure: bool) -> str:
    status, payload = request_json(
        f"{base_url.rstrip('/')}/v1/channels/direct",
        handle,
        method="POST",
        body={"otherHandle": other_handle},
        insecure=insecure,
    )
    if status < 200 or status >= 300:
        raise SystemExit(f"direct channel lookup failed for {handle}->{other_handle}: {status} {payload}")
    return payload["channelId"]


def main() -> int:
    parser = argparse.ArgumentParser(description="Bridge active Turbo transmit state to real PushToTalk APNs wake pushes.")
    parser.add_argument("--base-url", default="https://beepbeep.to")
    parser.add_argument("--handle-a", required=True)
    parser.add_argument("--handle-b", required=True)
    parser.add_argument("--bundle-id", default="com.rounded.Turbo")
    parser.add_argument("--interval", type=float, default=0.75)
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    team_id = os.environ.get("TURBO_APNS_TEAM_ID")
    key_id = os.environ.get("TURBO_APNS_KEY_ID")
    if not team_id or not key_id:
        raise SystemExit("Missing TURBO_APNS_TEAM_ID or TURBO_APNS_KEY_ID")

    jwt_provider = APNSJWTProvider(team_id, key_id, load_private_key_pem())
    channel_id = direct_channel(args.base_url, args.handle_a, args.handle_b, args.insecure)
    print(f"[bridge] watching channel {channel_id} for {args.handle_a} <-> {args.handle_b}", flush=True)

    seen_starts: set[tuple[str, str, str]] = set()
    senders = [args.handle_a, args.handle_b]

    while True:
        for sender in senders:
            status, payload = request_json(
                f"{args.base_url.rstrip('/')}/v1/channels/{channel_id}/ptt-push-target",
                sender,
                insecure=args.insecure,
            )
            if status == 404:
                continue
            if status == 403:
                continue
            if status == 401 and payload.get("error") == "active transmit not owned by caller":
                continue
            if status < 200 or status >= 300:
                print(f"[bridge] {sender} target lookup failed: {status} {payload}", file=sys.stderr, flush=True)
                continue

            started_at = payload.get("startedAt", "")
            dedupe_key = (sender, payload.get("targetDeviceId", ""), started_at)
            if dedupe_key in seen_starts:
                continue

            apns_payload = {
                "aps": {},
                "event": payload["event"],
                "channelId": payload["channelId"],
                "activeSpeaker": payload["activeSpeaker"],
                "senderUserId": payload["senderUserId"],
                "senderDeviceId": payload["senderDeviceId"],
            }
            try:
                status_code, body = send_apns(
                    payload["token"],
                    apns_payload,
                    jwt_provider.current_token(),
                    args.bundle_id,
                )
            except Exception as error:
                print(
                    f"[bridge] push send crashed sender={sender} error={error}",
                    file=sys.stderr,
                    flush=True,
                )
                continue
            if 200 <= status_code < 300:
                seen_starts.add(dedupe_key)
                print(
                    f"[bridge] sent wake push sender={sender} target={payload.get('targetDeviceId')} startedAt={started_at} status={status_code}",
                    flush=True,
                )
            else:
                if status_code == 403 and body == '{"reason":"ExpiredProviderToken"}':
                    try:
                        status_code, body = send_apns(
                            payload["token"],
                            apns_payload,
                            jwt_provider.force_refresh(),
                            args.bundle_id,
                        )
                    except Exception as error:
                        print(
                            f"[bridge] push retry crashed sender={sender} error={error}",
                            file=sys.stderr,
                            flush=True,
                        )
                        continue
                    if 200 <= status_code < 300:
                        seen_starts.add(dedupe_key)
                        print(
                            f"[bridge] sent wake push sender={sender} target={payload.get('targetDeviceId')} startedAt={started_at} status={status_code} retry=refreshed-token",
                            flush=True,
                        )
                        continue
                print(
                    f"[bridge] push send failed sender={sender} status={status_code} body={body}",
                    file=sys.stderr,
                    flush=True,
                )
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
