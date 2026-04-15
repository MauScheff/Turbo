#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable


SECTION_HEADER_RE = re.compile(r"^(STATE SNAPSHOT|STATE TIMELINE|DIAGNOSTICS)$")
TIMELINE_RE = re.compile(r"^\[(?P<timestamp>[^\]]+)\] \[(?P<label>[^\]]+)\] (?P<body>.*)$")
CONTACT_FIELD_RE = re.compile(r"^contact\[(?P<handle>[^\]]+)\]\.(?P<field>.+)$")


@dataclass
class Report:
    handle: str
    device_id: str
    uploaded_at: str
    snapshot: dict[str, str]
    state_timeline: list[tuple[datetime, str]]
    diagnostics: list[tuple[datetime, str]]
    wake_events: list[tuple[datetime, str]]


def snapshot_bool(snapshot: dict[str, str], key: str) -> bool | None:
    value = snapshot.get(key)
    if value is None or value == "none":
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch and merge the latest BeepBeep diagnostics for multiple handles."
    )
    parser.add_argument(
        "--base-url",
        default="https://beepbeep.to",
        help="Backend base URL.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS certificate verification for development endpoints.",
    )
    parser.add_argument(
        "--device",
        action="append",
        default=[],
        metavar="HANDLE=DEVICE_ID",
        help="Fetch diagnostics for an exact device, e.g. --device @avery=sim-scenario-avery",
    )
    parser.add_argument(
        "handles",
        nargs="*",
        help="One or more handles, e.g. @avery @blake",
    )
    return parser.parse_args()


def normalize_handle(handle: str) -> str:
    handle = handle.strip()
    return handle if handle.startswith("@") else f"@{handle}"


def fetch_latest_report(base_url: str, handle: str, insecure: bool, device_id: str | None = None) -> Report:
    command = [
        "curl",
        "--fail-with-body",
        "-sS",
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
    ]
    if insecure:
        command.append("--insecure")
    path = "/v1/dev/diagnostics/latest"
    if device_id:
        # Local cloud exact-device diagnostics routes currently require a trailing slash
        # after the captured device id, while hosted tolerates both forms.
        path = f"{path}/{device_id}/"
    command.append(f"{base_url.rstrip('/')}{path}")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as exc:
        body = (exc.stderr or exc.stdout).strip()
        raise RuntimeError(f"{handle}: request failed: {body}") from exc

    payload = json.loads(result.stdout)

    report = payload["report"]
    transcript = report.get("transcript", "")
    sections = split_sections(transcript)
    return Report(
        handle=handle,
        device_id=report.get("deviceId", device_id or "unknown"),
        uploaded_at=report.get("uploadedAt", ""),
        snapshot=parse_snapshot(sections.get("STATE SNAPSHOT", "")),
        state_timeline=parse_timeline_section(handle, "state", sections.get("STATE TIMELINE", "")),
        diagnostics=parse_timeline_section(handle, "diag", sections.get("DIAGNOSTICS", "")),
        wake_events=fetch_wake_events(base_url, handle, insecure),
    )


def fetch_json(base_url: str, handle: str, path: str, insecure: bool) -> dict:
    command = [
        "curl",
        "--fail-with-body",
        "-sS",
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
    ]
    if insecure:
        command.append("--insecure")
    command.append(f"{base_url.rstrip('/')}{path}")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as exc:
        body = (exc.stderr or exc.stdout).strip()
        raise RuntimeError(f"{handle}: request failed: {body}") from exc
    return json.loads(result.stdout)


def fetch_wake_events(base_url: str, handle: str, insecure: bool) -> list[tuple[datetime, str]]:
    payload = fetch_json(base_url, handle, "/v1/dev/wake-events/recent", insecure)
    raw_events = payload.get("events", [])
    if not isinstance(raw_events, list):
        return []
    events: list[tuple[datetime, str]] = []
    for raw_event in raw_events:
        if not isinstance(raw_event, dict):
            continue
        recorded_at = parse_timestamp(str(raw_event.get("recordedAt", "")))
        if recorded_at is None:
            continue
        result = str(raw_event.get("result", "unknown"))
        status_code = str(raw_event.get("statusCode", ""))
        channel_id = str(raw_event.get("channelId", ""))
        target_device_id = str(raw_event.get("targetDeviceId", ""))
        started_at = str(raw_event.get("startedAt", ""))
        body = str(raw_event.get("responseBody", "")).strip()
        summary = (
            f"[{handle}] [wake:apns] result={result} status={status_code} "
            f"channelId={channel_id} targetDeviceId={target_device_id} startedAt={started_at}"
        )
        if body and body != "None":
            summary += f" body={body}"
        events.append((recorded_at, summary))
    return events


def split_sections(transcript: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_header: str | None = None
    for raw_line in transcript.splitlines():
        line = raw_line.rstrip("\n")
        if SECTION_HEADER_RE.match(line):
            current_header = line
            sections[current_header] = []
            continue
        if current_header is not None:
            sections[current_header].append(line)
    return {header: "\n".join(lines).strip() for header, lines in sections.items()}


def parse_snapshot(section: str) -> dict[str, str]:
    snapshot: dict[str, str] = {}
    for line in section.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        snapshot[key] = value
    return snapshot


def parse_timeline_section(handle: str, prefix: str, section: str) -> list[tuple[datetime, str]]:
    events: list[tuple[datetime, str]] = []
    for line in section.splitlines():
        match = TIMELINE_RE.match(line)
        if not match:
            continue
        timestamp = parse_timestamp(match.group("timestamp"))
        if timestamp is None:
            continue
        label = match.group("label")
        body = match.group("body")
        events.append((timestamp, f"[{handle}] [{prefix}:{label}] {body}"))
    return events


def parse_timestamp(text: str) -> datetime | None:
    text = text.strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            return datetime.fromisoformat(text.replace("Z", "+00:00"))
        if "+" in text[10:] or "-" in text[10:]:
            return datetime.fromisoformat(text)
    except ValueError:
        pass

    # Fallback for old localized time-only entries: keep them at epoch day in UTC.
    for fmt in ("%I:%M:%S %p", "%H:%M:%S", "%I:%M:%S\u202fa.m.", "%I:%M:%S\u202fp.m."):
        try:
            parsed = datetime.strptime(text, fmt)
            return datetime(1970, 1, 1, parsed.hour, parsed.minute, parsed.second, tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def render_snapshot(report: Report) -> str:
    keys = [
        "selectedContact",
        "selectedPeerPhase",
        "selectedPeerPhaseDetail",
        "selectedPeerRelationship",
        "selectedPeerStatus",
        "pendingAction",
        "isJoined",
        "isTransmitting",
        "systemSession",
        "backendChannelStatus",
        "backendSelfJoined",
        "backendPeerJoined",
        "backendPeerDeviceConnected",
        "status",
        "backendStatus",
    ]
    details = " ".join(f"{key}={report.snapshot.get(key, 'none')}" for key in keys)
    contact_summaries = []
    for handle, fields in sorted(parse_contact_snapshot(report.snapshot).items()):
        contact_summaries.append(
            f"{handle} online={fields.get('isOnline', 'none')} listState={fields.get('listState', 'none')} badge={fields.get('badgeStatus', 'none')}"
        )
    contact_details = "" if not contact_summaries else " contacts=[" + "; ".join(contact_summaries) + "]"
    return f"{report.handle} deviceId={report.device_id} uploadedAt={report.uploaded_at} {details}{contact_details}"


def parse_contact_snapshot(snapshot: dict[str, str]) -> dict[str, dict[str, str]]:
    contacts: dict[str, dict[str, str]] = {}
    for key, value in snapshot.items():
        match = CONTACT_FIELD_RE.match(key)
        if not match:
            continue
        handle = match.group("handle")
        field = match.group("field")
        contacts.setdefault(handle, {})[field] = value
    return contacts


def parse_device_mapping(raw_value: str) -> tuple[str, str]:
    if "=" not in raw_value:
        raise RuntimeError(f"invalid --device mapping: {raw_value!r}; expected HANDLE=DEVICE_ID")
    handle, device_id = raw_value.split("=", 1)
    return normalize_handle(handle), device_id.strip()


def merged_events(reports: Iterable[Report]) -> list[tuple[datetime, str]]:
    events: list[tuple[datetime, str]] = []
    for report in reports:
        events.extend(report.state_timeline)
        events.extend(report.diagnostics)
        events.extend(report.wake_events)
    return sorted(events, key=lambda item: item[0])


def analyze_report(report: Report) -> list[str]:
    snapshot = report.snapshot
    anomalies: list[str] = []
    contacts = parse_contact_snapshot(snapshot)

    phase = snapshot.get("selectedPeerPhase", "none")
    backend_self_joined = snapshot_bool(snapshot, "backendSelfJoined")
    backend_peer_joined = snapshot_bool(snapshot, "backendPeerJoined")
    backend_peer_device = snapshot_bool(snapshot, "backendPeerDeviceConnected")
    backend_can_transmit = snapshot_bool(snapshot, "backendCanTransmit")
    is_joined = snapshot_bool(snapshot, "isJoined")
    local_join_failure = snapshot.get("localJoinFailure", "none")
    system_session = snapshot.get("systemSession", "none")

    if backend_self_joined and backend_peer_joined and backend_peer_device:
        if phase in {"idle", "requested", "incomingRequest"}:
            anomalies.append(
                f"{report.handle}: backend says both sides are ready, but selectedPeerPhase={phase}"
            )

    if backend_peer_joined and not backend_self_joined:
        if phase in {"idle", "requested"}:
            anomalies.append(
                f"{report.handle}: peer already joined, but selectedPeerPhase={phase} instead of peerReady/connectable"
            )

    if phase == "ready" and not is_joined:
        anomalies.append(f"{report.handle}: selectedPeerPhase=ready while isJoined=false")

    if phase == "ready" and backend_can_transmit is False:
        anomalies.append(f"{report.handle}: selectedPeerPhase=ready while backendCanTransmit=false")

    if local_join_failure != "none":
        anomalies.append(
            f"{report.handle}: localJoinFailure={local_join_failure} systemSession={system_session}"
        )

    selected_contact = snapshot.get("selectedContact", "none")
    selected_contact_projection = contacts.get(selected_contact) if selected_contact != "none" else None
    if phase == "idle" and selected_contact_projection is not None:
        contact_online = snapshot_bool(selected_contact_projection, "isOnline")
        if contact_online and "online" not in snapshot.get("selectedPeerStatus", "").lower():
            anomalies.append(
                f"{report.handle}: selected contact {selected_contact} is online in contact projection, but selectedPeerStatus={snapshot.get('selectedPeerStatus', 'none')}"
            )

    return anomalies


def analyze_reports(reports: list[Report]) -> list[str]:
    anomalies: list[str] = []
    for report in reports:
        anomalies.extend(analyze_report(report))

    if len(reports) == 2:
        left, right = reports
        left_phase = left.snapshot.get("selectedPeerPhase", "none")
        right_phase = right.snapshot.get("selectedPeerPhase", "none")
        left_backend_ready = (
            snapshot_bool(left.snapshot, "backendSelfJoined")
            and snapshot_bool(left.snapshot, "backendPeerJoined")
            and snapshot_bool(left.snapshot, "backendPeerDeviceConnected")
        )
        right_backend_ready = (
            snapshot_bool(right.snapshot, "backendSelfJoined")
            and snapshot_bool(right.snapshot, "backendPeerJoined")
            and snapshot_bool(right.snapshot, "backendPeerDeviceConnected")
        )

        if left_backend_ready and right_backend_ready:
            not_ready_phases = {"idle", "requested", "incomingRequest", "peerReady"}
            if left_phase in not_ready_phases or right_phase in not_ready_phases:
                anomalies.append(
                    "pair: backend is ready on both devices, but at least one UI is still not in a live session state"
                )

    return anomalies


def main() -> int:
    args = parse_args()
    requested_devices = [parse_device_mapping(raw_value) for raw_value in args.device]
    handles = [normalize_handle(handle) for handle in args.handles]

    if not handles and not requested_devices:
        raise RuntimeError("expected at least one handle or --device mapping")

    try:
        reports = [fetch_latest_report(args.base_url, handle, args.insecure) for handle in handles]
        reports.extend(
            fetch_latest_report(args.base_url, handle, args.insecure, device_id=device_id)
            for handle, device_id in requested_devices
        )
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print("LATEST SNAPSHOTS")
    for report in reports:
        print(render_snapshot(report))

    anomalies = analyze_reports(reports)
    print("\nANOMALIES")
    if anomalies:
        for anomaly in anomalies:
            print(f"- {anomaly}")
    else:
        print("- none")

    print("\nMERGED TIMELINE")
    for timestamp, line in merged_events(reports):
        print(f"{timestamp.isoformat()} {line}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
