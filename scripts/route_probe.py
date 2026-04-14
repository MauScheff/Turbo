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


def is_local_base_url(base_url: str) -> bool:
    hostname = urllib.parse.urlparse(base_url).hostname
    return hostname in {"localhost", "127.0.0.1"}


def require_request_relationship_contract(payload: dict[str, Any], *, label: str) -> None:
    relationship = payload.get("requestRelationship")
    require(isinstance(relationship, dict), f"{label} missing requestRelationship contract: {payload}")
    kind = relationship.get("kind")
    require(
        kind in {"none", "incoming", "outgoing", "mutual"},
        f"{label} requestRelationship kind invalid: {relationship}",
    )
    has_incoming = payload.get("hasIncomingRequest")
    has_outgoing = payload.get("hasOutgoingRequest")
    expected_kind = (
        "mutual" if has_incoming and has_outgoing
        else "incoming" if has_incoming
        else "outgoing" if has_outgoing
        else "none"
    )
    require(kind == expected_kind, f"{label} requestRelationship disagrees with legacy flags: {payload}")
    if expected_kind == "none":
        require(relationship.get("requestCount") in (None, 0), f"{label} none relationship carried a requestCount: {relationship}")
    else:
        require(
            relationship.get("requestCount") == payload.get("requestCount"),
            f"{label} requestRelationship count disagrees with legacy count: {payload}",
        )


def require_membership_contract(payload: dict[str, Any], *, label: str) -> None:
    membership = payload.get("membership")
    require(isinstance(membership, dict), f"{label} missing membership contract: {payload}")
    kind = membership.get("kind")
    require(
        kind in {"absent", "self-only", "peer-only", "both"},
        f"{label} membership kind invalid: {membership}",
    )
    self_joined = payload.get("selfJoined")
    peer_joined = payload.get("peerJoined")
    expected_kind = (
        "both" if self_joined and peer_joined
        else "self-only" if self_joined
        else "peer-only" if peer_joined
        else "absent"
    )
    require(kind == expected_kind, f"{label} membership disagrees with legacy join flags: {payload}")
    if expected_kind in {"peer-only", "both"}:
        require(
            membership.get("peerDeviceConnected") == payload.get("peerDeviceConnected"),
            f"{label} membership peerDeviceConnected disagrees with legacy field: {payload}",
        )
    else:
        require(
            membership.get("peerDeviceConnected") in (None, False),
            f"{label} membership unexpectedly carried peerDeviceConnected: {membership}",
        )


def require_summary_status_contract(payload: dict[str, Any], *, label: str) -> None:
    summary_status = payload.get("summaryStatus")
    require(isinstance(summary_status, dict), f"{label} missing summaryStatus contract: {payload}")
    kind = summary_status.get("kind")
    require(
        kind in {"offline", "online", "requested", "incoming", "connecting", "ready", "talking", "receiving"},
        f"{label} summaryStatus kind invalid: {summary_status}",
    )
    require(kind == payload.get("badgeStatus"), f"{label} summaryStatus disagrees with legacy badgeStatus: {payload}")
    active_transmitter = summary_status.get("activeTransmitterUserId")
    if kind in {"talking", "receiving"}:
        require(
            isinstance(active_transmitter, str) and active_transmitter,
            f"{label} missing active transmitter for talking/receiving: {summary_status}",
        )
    else:
        require(
            active_transmitter in (None, ""),
            f"{label} unexpected active transmitter for non-transmitting summary state: {summary_status}",
        )


def require_conversation_status_contract(payload: dict[str, Any], *, label: str) -> None:
    conversation_status = payload.get("conversationStatus")
    require(isinstance(conversation_status, dict), f"{label} missing conversationStatus contract: {payload}")
    kind = conversation_status.get("kind")
    require(
        kind in {"idle", "requested", "incoming-request", "connecting", "waiting-for-peer", "ready", "self-transmitting", "peer-transmitting"},
        f"{label} conversationStatus kind invalid: {conversation_status}",
    )
    require(kind == payload.get("status"), f"{label} conversationStatus disagrees with legacy status: {payload}")
    active_transmitter = conversation_status.get("activeTransmitterUserId")
    if kind in {"self-transmitting", "peer-transmitting"}:
        require(
            isinstance(active_transmitter, str) and active_transmitter,
            f"{label} missing active transmitter for transmitting conversation state: {conversation_status}",
        )
        require(
            active_transmitter == payload.get("activeTransmitterUserId"),
            f"{label} conversationStatus active transmitter disagrees with legacy field: {payload}",
        )
    else:
        require(
            active_transmitter in (None, ""),
            f"{label} unexpected active transmitter for non-transmitting conversation state: {conversation_status}",
        )


def require_readiness_contract(payload: dict[str, Any], *, label: str) -> None:
    readiness = payload.get("readiness")
    require(isinstance(readiness, dict), f"{label} missing readiness contract: {payload}")
    kind = readiness.get("kind")
    require(
        kind in {"waiting-for-self", "waiting-for-peer", "ready", "self-transmitting", "peer-transmitting"},
        f"{label} readiness kind invalid: {readiness}",
    )
    require(kind == payload.get("status"), f"{label} readiness contract disagrees with legacy status: {payload}")
    active_transmitter = readiness.get("activeTransmitterUserId")
    if kind == "waiting-for-self":
        require(payload.get("selfHasActiveDevice") is False, f"{label} readiness expected self device to be inactive: {payload}")
    if kind == "waiting-for-peer":
        require(payload.get("selfHasActiveDevice") is True, f"{label} readiness expected self device to be active: {payload}")
        require(payload.get("peerHasActiveDevice") is False, f"{label} readiness expected peer device to be inactive: {payload}")
    if kind == "ready":
        require(payload.get("selfHasActiveDevice") is True, f"{label} readiness expected self device to be active: {payload}")
        require(payload.get("peerHasActiveDevice") is True, f"{label} readiness expected peer device to be active: {payload}")
    if kind in {"self-transmitting", "peer-transmitting"}:
        require(
            isinstance(active_transmitter, str) and active_transmitter,
            f"{label} readiness missing active transmitter for transmitting state: {readiness}",
        )
        require(
            active_transmitter == payload.get("activeTransmitterUserId"),
            f"{label} readiness active transmitter disagrees with legacy field: {payload}",
        )
    else:
        require(
            active_transmitter in (None, ""),
            f"{label} readiness unexpectedly carried active transmitter: {readiness}",
        )


def require_audio_readiness_contract(payload: dict[str, Any], *, label: str) -> None:
    audio_readiness = payload.get("audioReadiness")
    require(isinstance(audio_readiness, dict), f"{label} missing audioReadiness contract: {payload}")

    self_readiness = audio_readiness.get("self")
    peer_readiness = audio_readiness.get("peer")
    require(isinstance(self_readiness, dict), f"{label} audioReadiness missing self readiness: {audio_readiness}")
    require(isinstance(peer_readiness, dict), f"{label} audioReadiness missing peer readiness: {audio_readiness}")

    self_kind = self_readiness.get("kind")
    peer_kind = peer_readiness.get("kind")
    valid_kinds = {"unknown", "waiting", "wake-capable", "ready"}
    require(self_kind in valid_kinds, f"{label} invalid self audio readiness kind: {audio_readiness}")
    require(peer_kind in valid_kinds, f"{label} invalid peer audio readiness kind: {audio_readiness}")

    self_has_active_device = payload.get("selfHasActiveDevice")
    peer_has_active_device = payload.get("peerHasActiveDevice")

    if self_has_active_device:
        require(
            self_kind in {"waiting", "wake-capable", "ready"},
            f"{label} self audio readiness should not be unknown when self has an active device: {audio_readiness}",
        )
    else:
        require(
            self_kind == "unknown",
            f"{label} self audio readiness should be unknown without an active device: {audio_readiness}",
        )

    peer_target_device_id = audio_readiness.get("peerTargetDeviceId")
    if peer_has_active_device:
        require(
            peer_kind in {"waiting", "wake-capable", "ready"},
            f"{label} peer audio readiness should not be unknown when peer has an active device: {audio_readiness}",
        )
        require(
            isinstance(peer_target_device_id, str) and peer_target_device_id,
            f"{label} peer audio readiness missing peerTargetDeviceId for active peer device: {audio_readiness}",
        )
    else:
        require(
            peer_kind == "unknown",
            f"{label} peer audio readiness should be unknown without an active device: {audio_readiness}",
        )
        require(
            peer_target_device_id in (None, ""),
            f"{label} peer audio readiness unexpectedly carried peerTargetDeviceId: {audio_readiness}",
        )


def require_wake_readiness_contract(payload: dict[str, Any], *, label: str) -> None:
    wake_readiness = payload.get("wakeReadiness")
    require(isinstance(wake_readiness, dict), f"{label} missing wakeReadiness contract: {payload}")

    self_wake = wake_readiness.get("self")
    peer_wake = wake_readiness.get("peer")
    require(isinstance(self_wake, dict), f"{label} wakeReadiness missing self readiness: {wake_readiness}")
    require(isinstance(peer_wake, dict), f"{label} wakeReadiness missing peer readiness: {wake_readiness}")

    valid_kinds = {"unavailable", "wake-capable"}
    self_kind = self_wake.get("kind")
    peer_kind = peer_wake.get("kind")
    require(self_kind in valid_kinds, f"{label} invalid self wake readiness kind: {wake_readiness}")
    require(peer_kind in valid_kinds, f"{label} invalid peer wake readiness kind: {wake_readiness}")

    def require_target(kind: Any, target: Any, *, side: str) -> None:
        if kind == "wake-capable":
            require(
                isinstance(target, str) and target,
                f"{label} {side} wake readiness missing targetDeviceId: {wake_readiness}",
            )
        else:
            require(
                target in (None, ""),
                f"{label} {side} wake readiness unexpectedly carried targetDeviceId: {wake_readiness}",
            )

    require_target(self_kind, self_wake.get("targetDeviceId"), side="self")
    require_target(peer_kind, peer_wake.get("targetDeviceId"), side="peer")


def require_diagnostics_report(
    response: dict[str, Any],
    *,
    expected_status: str,
    expected_device_id: str,
    expected_app_version: str,
    expected_selected_handle: str,
) -> dict[str, Any]:
    require(response.get("status") == expected_status, f"unexpected diagnostics payload: {response}")
    report = response.get("report")
    require(isinstance(report, dict), f"diagnostics response missing report: {response}")
    require(report.get("deviceId") == expected_device_id, f"diagnostics latest mismatched device: {report}")
    require(report.get("appVersion") == expected_app_version, f"diagnostics latest mismatched appVersion: {report}")
    require(report.get("selectedHandle") == expected_selected_handle, f"diagnostics latest mismatched selected handle: {report}")
    require(bool(report.get("uploadedAt")), f"diagnostics latest missing uploadedAt: {report}")
    return report


async def receive_json_or_timeout(connection, timeout_seconds: int) -> dict:
    try:
        raw = await asyncio.wait_for(connection.recv(), timeout=timeout_seconds)
        return json.loads(raw)
    except Exception as exc:
        return {"error": repr(exc)}


async def send_signal(
    connection,
    *,
    type: str,
    channel_id: str,
    from_user_id: str,
    from_device_id: str,
    to_user_id: str,
    to_device_id: str,
    payload: str,
) -> None:
    await connection.send(json.dumps({
        "type": type,
        "channelId": channel_id,
        "fromUserId": from_user_id,
        "fromDeviceId": from_device_id,
        "toUserId": to_user_id,
        "toDeviceId": to_device_id,
        "payload": payload,
    }))


async def expect_forwarded_signal(
    connection,
    *,
    expected_type: str,
    expected_channel_id: str,
    expected_from_user_id: str,
    expected_from_device_id: str,
    expected_to_user_id: str,
    expected_to_device_id: str,
) -> dict[str, Any]:
    envelope = await receive_json_or_timeout(connection, timeout_seconds=10)
    require(envelope.get("type") == expected_type, f"unexpected forwarded signal type: {envelope}")
    require(envelope.get("channelId") == expected_channel_id, f"unexpected forwarded channel id: {envelope}")
    require(envelope.get("fromUserId") == expected_from_user_id, f"unexpected forwarded fromUserId: {envelope}")
    require(envelope.get("fromDeviceId") == expected_from_device_id, f"unexpected forwarded fromDeviceId: {envelope}")
    require(envelope.get("toUserId") == expected_to_user_id, f"unexpected forwarded toUserId: {envelope}")
    require(envelope.get("toDeviceId") == expected_to_device_id, f"unexpected forwarded toDeviceId: {envelope}")
    return envelope


@contextlib.asynccontextmanager
async def connected_websocket_pair(
    base_url: str,
    caller: dict[str, str],
    callee: dict[str, str],
    insecure: bool,
):
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    websocket_scheme = urllib.parse.urlparse(ws_base).scheme
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
    ssl_context = None
    if websocket_scheme == "wss":
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


async def run_async_check(results: list[CheckResult], name: str, fn) -> Any:
    try:
        payload = await fn()
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
            peer = callee if current is caller else caller
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
                        "appVersion": f"route-probe:{current['device_id']}",
                        "backendBaseURL": args.base_url,
                        "selectedHandle": peer["handle"],
                        "snapshot": f"snapshot for {current['handle']}",
                        "transcript": f"transcript for {current['handle']}",
                    },
                    insecure=args.insecure,
                ),
            )
            expected_app_version = f"route-probe:{current['device_id']}"
            require_diagnostics_report(
                diagnostics_upload,
                expected_status="uploaded",
                expected_device_id=current["device_id"],
                expected_app_version=expected_app_version,
                expected_selected_handle=peer["handle"],
            )

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
            require_diagnostics_report(
                diagnostics_latest,
                expected_status="ok",
                expected_device_id=current["device_id"],
                expected_app_version=expected_app_version,
                expected_selected_handle=peer["handle"],
            )

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
            require_diagnostics_report(
                diagnostics_latest_for_user,
                expected_status="ok",
                expected_device_id=current["device_id"],
                expected_app_version=expected_app_version,
                expected_selected_handle=peer["handle"],
            )

            overwrite_app_version = f"{expected_app_version}:overwrite"
            diagnostics_overwrite = run_check(
                results,
                f"diagnostics-overwrite:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics",
                    current["handle"],
                    method="POST",
                    body={
                        "deviceId": current["device_id"],
                        "appVersion": overwrite_app_version,
                        "backendBaseURL": args.base_url,
                        "selectedHandle": peer["handle"],
                        "snapshot": f"overwrite snapshot for {current['handle']}",
                        "transcript": f"overwrite transcript for {current['handle']}",
                    },
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report(
                diagnostics_overwrite,
                expected_status="uploaded",
                expected_device_id=current["device_id"],
                expected_app_version=overwrite_app_version,
                expected_selected_handle=peer["handle"],
            )

            diagnostics_latest_after_overwrite = run_check(
                results,
                f"diagnostics-latest-after-overwrite:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    f"/v1/dev/diagnostics/latest/{urllib.parse.quote(current['device_id'])}",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report(
                diagnostics_latest_after_overwrite,
                expected_status="ok",
                expected_device_id=current["device_id"],
                expected_app_version=overwrite_app_version,
                expected_selected_handle=peer["handle"],
            )

            diagnostics_latest_for_user_after_overwrite = run_check(
                results,
                f"diagnostics-latest-current-after-overwrite:{current['handle']}",
                lambda current=current: request(
                    args.base_url,
                    "/v1/dev/diagnostics/latest",
                    current["handle"],
                    insecure=args.insecure,
                ),
            )
            require_diagnostics_report(
                diagnostics_latest_for_user_after_overwrite,
                expected_status="ok",
                expected_device_id=current["device_id"],
                expected_app_version=overwrite_app_version,
                expected_selected_handle=peer["handle"],
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
        prejoin_state = run_check(
            results,
            "channel-state:prejoin-requested",
            lambda: request(
                args.base_url,
                f"/v1/channels/{invite_cancel['channelId']}/state/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require(prejoin_state.get("status") == "requested", f"prejoin state should be requested: {prejoin_state}")
        require(prejoin_state.get("selfJoined") is False, f"prejoin state should not show caller joined: {prejoin_state}")
        require(prejoin_state.get("peerJoined") is False, f"prejoin state should not show peer joined: {prejoin_state}")
        if is_local_base_url(args.base_url):
            require_request_relationship_contract(prejoin_state, label="channel-state:prejoin-requested")
            require_membership_contract(prejoin_state, label="channel-state:prejoin-requested")
            require_conversation_status_contract(prejoin_state, label="channel-state:prejoin-requested")
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
        post_direct_summaries = run_check(
            results,
            "contact-summaries:caller:post-direct",
            lambda: request(
                args.base_url,
                f"/v1/contacts/summaries/{urllib.parse.quote(caller['device_id'])}",
                caller["handle"],
                insecure=args.insecure,
            ),
        )
        require(isinstance(post_direct_summaries, list), f"post-direct contact summaries returned unexpected payload: {post_direct_summaries}")
        caller_summary = next(
            (summary for summary in post_direct_summaries if summary.get("handle") == callee["handle"]),
            None,
        )
        require(isinstance(caller_summary, dict), f"callee summary missing after direct channel creation: {post_direct_summaries}")
        require_request_relationship_contract(caller_summary, label="contact-summaries:caller:post-direct")
        require(isinstance(caller_summary.get("membership"), dict), f"contact-summaries:caller:post-direct missing membership contract: {caller_summary}")
        require_summary_status_contract(caller_summary, label="contact-summaries:caller:post-direct")

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
            if is_local_base_url(args.base_url):
                require_request_relationship_contract(caller_state, label="channel-state:caller")
                require_membership_contract(caller_state, label="channel-state:caller")
                require_conversation_status_contract(caller_state, label="channel-state:caller")
                require_request_relationship_contract(callee_state, label="channel-state:callee")
                require_membership_contract(callee_state, label="channel-state:callee")
                require_conversation_status_contract(callee_state, label="channel-state:callee")

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
            if is_local_base_url(args.base_url):
                require_readiness_contract(caller_readiness, label="channel-readiness:caller")
                require_audio_readiness_contract(caller_readiness, label="channel-readiness:caller")

            await run_async_check(
                results,
                "signal:receiver-ready:callee-to-caller",
                lambda: send_signal(
                    websocket_pair["callee"],
                    type="receiver-ready",
                    channel_id=channel_id,
                    from_user_id=callee["user_id"],
                    from_device_id=callee["device_id"],
                    to_user_id=caller["user_id"],
                    to_device_id=caller["device_id"],
                    payload="receiver-ready",
                ),
            )
            await run_async_check(
                results,
                "signal:receiver-ready-forwarded:caller",
                lambda: expect_forwarded_signal(
                    websocket_pair["caller"],
                    expected_type="receiver-ready",
                    expected_channel_id=channel_id,
                    expected_from_user_id=callee["user_id"],
                    expected_from_device_id=callee["device_id"],
                    expected_to_user_id=caller["user_id"],
                    expected_to_device_id=caller["device_id"],
                ),
            )
            await run_async_check(
                results,
                "signal:receiver-ready:caller-to-callee",
                lambda: send_signal(
                    websocket_pair["caller"],
                    type="receiver-ready",
                    channel_id=channel_id,
                    from_user_id=caller["user_id"],
                    from_device_id=caller["device_id"],
                    to_user_id=callee["user_id"],
                    to_device_id=callee["device_id"],
                    payload="receiver-ready",
                ),
            )
            await run_async_check(
                results,
                "signal:receiver-ready-forwarded:callee",
                lambda: expect_forwarded_signal(
                    websocket_pair["callee"],
                    expected_type="receiver-ready",
                    expected_channel_id=channel_id,
                    expected_from_user_id=caller["user_id"],
                    expected_from_device_id=caller["device_id"],
                    expected_to_user_id=callee["user_id"],
                    expected_to_device_id=callee["device_id"],
                ),
            )

            caller_readiness_after_signal = run_check(
                results,
                "channel-readiness:caller:receiver-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            callee_readiness_after_signal = run_check(
                results,
                "channel-readiness:callee:receiver-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
                    callee["handle"],
                    insecure=args.insecure,
                ),
            )
            if is_local_base_url(args.base_url):
                require_readiness_contract(caller_readiness_after_signal, label="channel-readiness:caller:receiver-ready")
                require_readiness_contract(callee_readiness_after_signal, label="channel-readiness:callee:receiver-ready")
                require_audio_readiness_contract(caller_readiness_after_signal, label="channel-readiness:caller:receiver-ready")
                require_audio_readiness_contract(callee_readiness_after_signal, label="channel-readiness:callee:receiver-ready")
                require_wake_readiness_contract(caller_readiness_after_signal, label="channel-readiness:caller:receiver-ready")
                require_wake_readiness_contract(callee_readiness_after_signal, label="channel-readiness:callee:receiver-ready")
                require(
                    caller_readiness_after_signal.get("audioReadiness", {}).get("peer", {}).get("kind") == "ready",
                    f"caller readiness should show ready peer audio after receiver-ready signal: {caller_readiness_after_signal}",
                )
                require(
                    callee_readiness_after_signal.get("audioReadiness", {}).get("peer", {}).get("kind") == "ready",
                    f"callee readiness should show ready peer audio after receiver-ready signal: {callee_readiness_after_signal}",
                )

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

            caller_readiness_after_token = run_check(
                results,
                "channel-readiness:caller:wake-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                    caller["handle"],
                    insecure=args.insecure,
                ),
            )
            callee_readiness_after_token = run_check(
                results,
                "channel-readiness:callee:wake-ready",
                lambda: request(
                    args.base_url,
                    f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
                    callee["handle"],
                    insecure=args.insecure,
                ),
            )
            require_wake_readiness_contract(caller_readiness_after_token, label="channel-readiness:caller:wake-ready")
            require_wake_readiness_contract(callee_readiness_after_token, label="channel-readiness:callee:wake-ready")
            require(
                caller_readiness_after_token.get("wakeReadiness", {}).get("peer", {}).get("kind") == "wake-capable",
                f"caller readiness should expose wake-capable peer after token upload: {caller_readiness_after_token}",
            )
            require(
                caller_readiness_after_token.get("wakeReadiness", {}).get("peer", {}).get("targetDeviceId") == callee["device_id"],
                f"caller readiness should expose callee wake target after token upload: {caller_readiness_after_token}",
            )
            require(
                callee_readiness_after_token.get("wakeReadiness", {}).get("self", {}).get("kind") == "wake-capable",
                f"callee readiness should expose self wake capability after token upload: {callee_readiness_after_token}",
            )
            require(
                callee_readiness_after_token.get("wakeReadiness", {}).get("self", {}).get("targetDeviceId") == callee["device_id"],
                f"callee readiness should expose local wake target after token upload: {callee_readiness_after_token}",
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
            if is_local_base_url(args.base_url):
                caller_state_transmitting = run_check(
                    results,
                    "channel-state:caller:transmitting",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
                        caller["handle"],
                        insecure=args.insecure,
                    ),
                )
                callee_state_receiving = run_check(
                    results,
                    "channel-state:callee:receiving",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(callee['device_id'])}",
                        callee["handle"],
                        insecure=args.insecure,
                    ),
                )
                require_conversation_status_contract(caller_state_transmitting, label="channel-state:caller:transmitting")
                require_conversation_status_contract(callee_state_receiving, label="channel-state:callee:receiving")
                require(
                    caller_state_transmitting.get("conversationStatus", {}).get("kind") == "self-transmitting",
                    f"caller state should show self-transmitting after begin-transmit: {caller_state_transmitting}",
                )
                require(
                    callee_state_receiving.get("conversationStatus", {}).get("kind") == "peer-transmitting",
                    f"callee state should show peer-transmitting after begin-transmit: {callee_state_receiving}",
                )
                require(
                    caller_state_transmitting.get("conversationStatus", {}).get("activeTransmitterUserId") == caller["user_id"],
                    f"caller transmitting state should carry caller as active transmitter: {caller_state_transmitting}",
                )
                require(
                    callee_state_receiving.get("conversationStatus", {}).get("activeTransmitterUserId") == caller["user_id"],
                    f"callee receiving state should carry caller as active transmitter: {callee_state_receiving}",
                )

                caller_readiness_transmitting = run_check(
                    results,
                    "channel-readiness:caller:transmitting",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(caller['device_id'])}",
                        caller["handle"],
                        insecure=args.insecure,
                    ),
                )
                callee_readiness_receiving = run_check(
                    results,
                    "channel-readiness:callee:receiving",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/readiness/{urllib.parse.quote(callee['device_id'])}",
                        callee["handle"],
                        insecure=args.insecure,
                    ),
                )
                require_readiness_contract(caller_readiness_transmitting, label="channel-readiness:caller:transmitting")
                require_readiness_contract(callee_readiness_receiving, label="channel-readiness:callee:receiving")
                require_audio_readiness_contract(caller_readiness_transmitting, label="channel-readiness:caller:transmitting")
                require_audio_readiness_contract(callee_readiness_receiving, label="channel-readiness:callee:receiving")
                require(
                    caller_readiness_transmitting.get("readiness", {}).get("kind") == "self-transmitting",
                    f"caller readiness should show self-transmitting after begin-transmit: {caller_readiness_transmitting}",
                )
                require(
                    callee_readiness_receiving.get("readiness", {}).get("kind") == "peer-transmitting",
                    f"callee readiness should show peer-transmitting after begin-transmit: {callee_readiness_receiving}",
                )

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
            if is_local_base_url(args.base_url):
                caller_state_after_end = run_check(
                    results,
                    "channel-state:caller:post-transmit",
                    lambda: request(
                        args.base_url,
                        f"/v1/channels/{channel_id}/state/{urllib.parse.quote(caller['device_id'])}",
                        caller["handle"],
                        insecure=args.insecure,
                    ),
                )
                require_conversation_status_contract(caller_state_after_end, label="channel-state:caller:post-transmit")
                require(
                    caller_state_after_end.get("conversationStatus", {}).get("kind") == "ready",
                    f"caller state should return to ready after end-transmit: {caller_state_after_end}",
                )

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
