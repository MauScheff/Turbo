#!/usr/bin/env python3

import argparse
import base64
import json
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_private_key_pem() -> bytes:
    key_text = os.environ.get("TURBO_APNS_PRIVATE_KEY")
    if key_text:
        return key_text.encode("utf-8")

    key_path = os.environ.get("TURBO_APNS_PRIVATE_KEY_PATH")
    if key_path:
        return Path(key_path).read_bytes()

    raise SystemExit("Missing TURBO_APNS_PRIVATE_KEY or TURBO_APNS_PRIVATE_KEY_PATH")


def der_to_raw_ecdsa_signature(der: bytes, component_size: int = 32) -> bytes:
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("Unexpected DER signature format")

    index = 2
    if der[1] & 0x80:
        length_len = der[1] & 0x7F
        index = 2 + length_len

    if der[index] != 0x02:
        raise ValueError("Missing DER integer for r")
    r_len = der[index + 1]
    r = der[index + 2:index + 2 + r_len]
    index = index + 2 + r_len

    if der[index] != 0x02:
        raise ValueError("Missing DER integer for s")
    s_len = der[index + 1]
    s = der[index + 2:index + 2 + s_len]

    r = r.lstrip(b"\x00").rjust(component_size, b"\x00")
    s = s.lstrip(b"\x00").rjust(component_size, b"\x00")
    return r + s


def sign_es256(message: bytes, private_key_pem: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix="turbo-apns-sign-") as tmpdir:
        key_path = Path(tmpdir) / "AuthKey.p8"
        payload_path = Path(tmpdir) / "payload.txt"
        sig_path = Path(tmpdir) / "sig.der"
        key_path.write_bytes(private_key_pem)
        payload_path.write_bytes(message)
        subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-sign",
                str(key_path),
                "-out",
                str(sig_path),
                str(payload_path),
            ],
            check=True,
            capture_output=True,
        )
        der = sig_path.read_bytes()
    return der_to_raw_ecdsa_signature(der)


def make_apns_jwt(team_id: str, key_id: str, private_key_pem: bytes) -> str:
    header = {"alg": "ES256", "kid": key_id}
    claims = {"iss": team_id, "iat": int(time.time())}
    signing_input = (
        f"{b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url(json.dumps(claims, separators=(',', ':')).encode())}"
    ).encode("ascii")
    signature = sign_es256(signing_input, private_key_pem)
    return f"{signing_input.decode('ascii')}.{b64url(signature)}"


@dataclass
class APNSJWTProvider:
    team_id: str
    key_id: str
    private_key_pem: bytes
    refresh_interval_seconds: int = 30 * 60
    _token: str | None = None
    _issued_at: int = 0

    def current_token(self) -> str:
        now = int(time.time())
        if self._token is None or now - self._issued_at >= self.refresh_interval_seconds:
            self._token = make_apns_jwt(self.team_id, self.key_id, self.private_key_pem)
            self._issued_at = now
        return self._token

    def force_refresh(self) -> str:
        self._token = make_apns_jwt(self.team_id, self.key_id, self.private_key_pem)
        self._issued_at = int(time.time())
        return self._token


def backend_request(url: str, handle: str, insecure: bool) -> dict:
    command = [
        "curl",
        "-sS",
        "--fail-with-body",
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
        "-H",
        "Accept: application/json",
    ]
    if insecure:
        command.append("-k")
    command.append(url)
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    payload = completed.stdout.strip()
    return json.loads(payload) if payload else {}


def apns_host() -> str:
    use_sandbox = os.environ.get("TURBO_APNS_USE_SANDBOX", "1").lower() not in {"0", "false", "no"}
    return "api.sandbox.push.apple.com" if use_sandbox else "api.push.apple.com"


def send_apns(token: str, payload: dict, jwt_token: str, bundle_id: str) -> tuple[int, str]:
    url = f"https://{apns_host()}/3/device/{token}"
    command = [
        "curl",
        "-sS",
        "--http2",
        "-X",
        "POST",
        "-H",
        f"authorization: bearer {jwt_token}",
        "-H",
        "apns-push-type: pushtotalk",
        "-H",
        f"apns-topic: {bundle_id}.voip-ptt",
        "-H",
        "apns-priority: 10",
        "-H",
        "apns-expiration: 0",
        "-H",
        "content-type: application/json",
        "--data-binary",
        json.dumps(payload),
        "-w",
        "\n%{http_code}",
        url,
    ]
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
        raw = completed.stdout
    except subprocess.CalledProcessError as error:
        raw = error.stdout or error.stderr or ""
    body, _, status_text = raw.rpartition("\n")
    try:
        status = int(status_text.strip())
    except ValueError:
        status = 0
        body = raw.strip()
    return status, body.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Send a real PushToTalk APNs wake push using Turbo's canonical push-target route.")
    parser.add_argument("--base-url", default="https://beepbeep.to", help="Turbo backend base URL")
    parser.add_argument("--handle", required=True, help="Sender handle")
    parser.add_argument("--channel-id", required=True, help="Backend channel id")
    parser.add_argument("--bundle-id", default="com.rounded.Turbo", help="App bundle identifier")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification when talking to the Turbo backend")
    parser.add_argument("--print-only", action="store_true", help="Print the APNs request instead of sending it")
    args = parser.parse_args()

    push_target_url = f"{args.base_url.rstrip('/')}/v1/channels/{args.channel_id}/ptt-push-target"
    push_target = backend_request(push_target_url, args.handle, args.insecure)

    payload = {
        "aps": {},
        "event": push_target["event"],
        "channelId": push_target["channelId"],
        "activeSpeaker": push_target["activeSpeaker"],
        "senderUserId": push_target["senderUserId"],
        "senderDeviceId": push_target["senderDeviceId"],
    }

    if args.print_only:
        print(json.dumps({"token": push_target["token"], "payload": payload}, indent=2))
        return 0

    team_id = os.environ.get("TURBO_APNS_TEAM_ID")
    key_id = os.environ.get("TURBO_APNS_KEY_ID")
    if not team_id or not key_id:
        raise SystemExit("Missing TURBO_APNS_TEAM_ID or TURBO_APNS_KEY_ID")

    jwt_token = make_apns_jwt(team_id, key_id, load_private_key_pem())
    status, body = send_apns(push_target["token"], payload, jwt_token, args.bundle_id)
    print(json.dumps({"status": status, "body": body or "", "payload": payload}, indent=2))
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    raise SystemExit(main())
