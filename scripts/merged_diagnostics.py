#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable


SECTION_HEADER_RE = re.compile(r"^(STATE SNAPSHOT|STATE TIMELINE|INVARIANT VIOLATIONS|DIAGNOSTICS)$")
TIMELINE_RE = re.compile(r"^\[(?P<timestamp>[^\]]+)\] \[(?P<label>[^\]]+)\] (?P<body>.*)$")
INVARIANT_RE = re.compile(
    r"^\[(?P<timestamp>[^\]]+)\] \[(?P<invariant_id>[^\]]+)\] \[(?P<scope>[^\]]+)\](?: (?P<body>.*))?$"
)
CONTACT_FIELD_RE = re.compile(r"^contact\[(?P<handle>[^\]]+)\]\.(?P<field>.+)$")


@dataclass(frozen=True)
class InvariantViolation:
    subject: str
    invariant_id: str
    scope: str
    message: str
    source: str
    timestamp: datetime | None = None


@dataclass
class Report:
    handle: str
    device_id: str
    uploaded_at: str
    snapshot: dict[str, str]
    state_timeline: list[tuple[datetime, str]]
    invariant_violations: list[InvariantViolation]
    backend_invariant_violations: list[InvariantViolation]
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
        "--fail-on-violations",
        action="store_true",
        help="Exit non-zero when invariant violations are found.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a machine-readable JSON payload instead of the human report.",
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
        invariant_violations=parse_invariant_section(handle, sections.get("INVARIANT VIOLATIONS", "")),
        backend_invariant_violations=fetch_backend_invariant_events(base_url, handle, insecure),
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


def missing_route_error(exc: RuntimeError) -> bool:
    message = str(exc).lower()
    return any(fragment in message for fragment in ("404", "not found", "unknown route", "failed to match"))


def fetch_backend_invariant_events(base_url: str, handle: str, insecure: bool) -> list[InvariantViolation]:
    try:
        payload = fetch_json(base_url, handle, "/v1/dev/invariant-events/recent", insecure)
    except RuntimeError as exc:
        if missing_route_error(exc):
            return []
        raise

    if not isinstance(payload, dict):
        return []

    raw_events = payload.get("events", [])
    if not isinstance(raw_events, list):
        return []

    violations: list[InvariantViolation] = []
    for raw_event in raw_events:
        if not isinstance(raw_event, dict):
            continue
        invariant_id = str(raw_event.get("invariantId", "")).strip()
        if not invariant_id:
            continue
        message_parts = [str(raw_event.get("message", "")).strip()]
        metadata = str(raw_event.get("metadata", "")).strip()
        if metadata and metadata != "None":
            message_parts.append(f"metadata={metadata}")
        violations.append(
            InvariantViolation(
                subject=handle,
                invariant_id=invariant_id,
                scope=str(raw_event.get("scope", "backend")).strip() or "backend",
                message=" ".join(part for part in message_parts if part),
                source=str(raw_event.get("source", "backend")).strip() or "backend",
                timestamp=parse_timestamp(str(raw_event.get("recordedAt", ""))),
            )
        )
    return violations


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


def parse_invariant_section(handle: str, section: str) -> list[InvariantViolation]:
    violations: list[InvariantViolation] = []
    for line in section.splitlines():
        match = INVARIANT_RE.match(line)
        if not match:
            continue
        timestamp = parse_timestamp(match.group("timestamp"))
        invariant_id = match.group("invariant_id")
        scope = match.group("scope")
        message = (match.group("body") or "").strip()
        violations.append(
            InvariantViolation(
                subject=handle,
                invariant_id=invariant_id,
                scope=scope,
                message=message,
                source="explicit",
                timestamp=timestamp,
            )
        )
    return violations


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
        events.extend(render_invariant_events(report.invariant_violations))
        events.extend(render_invariant_events(report.backend_invariant_violations))
        events.extend(report.diagnostics)
        events.extend(report.wake_events)
    return sorted(events, key=lambda item: item[0])


def render_invariant_events(violations: Iterable[InvariantViolation]) -> list[tuple[datetime, str]]:
    events: list[tuple[datetime, str]] = []
    for violation in violations:
        if violation.timestamp is None:
            continue
        body = violation.message or "violation recorded"
        events.append(
            (
                violation.timestamp,
                (
                    f"[{violation.subject}] [invariant:{violation.scope}] "
                    f"{violation.invariant_id} source={violation.source} {body}"
                ).rstrip(),
            )
        )
    return events


def build_violation(
    *,
    subject: str,
    invariant_id: str,
    scope: str,
    message: str,
    source: str = "derived",
    timestamp: datetime | None = None,
) -> InvariantViolation:
    return InvariantViolation(
        subject=subject,
        invariant_id=invariant_id,
        scope=scope,
        message=message,
        source=source,
        timestamp=timestamp,
    )


def analyze_report(report: Report) -> list[InvariantViolation]:
    snapshot = report.snapshot
    violations: list[InvariantViolation] = []
    contacts = parse_contact_snapshot(snapshot)

    phase = snapshot.get("selectedPeerPhase", "none")
    backend_self_joined = snapshot_bool(snapshot, "backendSelfJoined")
    backend_peer_joined = snapshot_bool(snapshot, "backendPeerJoined")
    backend_peer_device = snapshot_bool(snapshot, "backendPeerDeviceConnected")
    backend_can_transmit = snapshot_bool(snapshot, "backendCanTransmit")
    is_joined = snapshot_bool(snapshot, "isJoined")
    had_connected_session_continuity = snapshot_bool(snapshot, "hadConnectedSessionContinuity")
    local_join_failure = snapshot.get("localJoinFailure", "none")
    system_session = snapshot.get("systemSession", "none")
    backend_channel_status = snapshot.get("backendChannelStatus", "none")
    backend_readiness = snapshot.get("backendReadiness", "none")
    remote_wake_capability_kind = snapshot.get("remoteWakeCapabilityKind", "unavailable")

    if backend_self_joined and backend_peer_joined and backend_peer_device:
        if phase in {"idle", "requested", "incomingRequest"}:
            violations.append(
                build_violation(
                    subject=report.handle,
                    invariant_id="selected.backend_ready_ui_not_live",
                    scope="backend",
                    message=f"backend says both sides are ready, but selectedPeerPhase={phase}",
                )
            )

    if backend_peer_joined and not backend_self_joined:
        if phase in {"idle", "requested"}:
            violations.append(
                build_violation(
                    subject=report.handle,
                    invariant_id="selected.peer_joined_ui_not_connectable",
                    scope="backend",
                    message=f"peer already joined, but selectedPeerPhase={phase} instead of peerReady/connectable",
                )
            )

    if backend_readiness == "waiting-for-self":
        if phase in {"idle", "requested", "incomingRequest"}:
            violations.append(
                build_violation(
                    subject=report.handle,
                    invariant_id="selected.waiting_for_self_ui_not_connectable",
                    scope="backend",
                    message=(
                        "backend says the peer is waiting for self, "
                        f"but selectedPeerPhase={phase} backendChannelStatus={backend_channel_status}"
                    ),
                )
            )

    if remote_wake_capability_kind == "wake-capable" and backend_channel_status in {
        "waiting-for-peer",
        "ready",
        "transmitting",
        "receiving",
    }:
        if phase in {"idle", "requested"}:
            violations.append(
                build_violation(
                    subject=report.handle,
                    invariant_id="selected.peer_wake_capable_ui_not_connectable",
                    scope="backend",
                    message=(
                        "backend channel is connectable and peer wake is available, "
                        f"but selectedPeerPhase={phase} backendChannelStatus={backend_channel_status} "
                        f"backendReadiness={backend_readiness}"
                    ),
                )
            )

    if (
        phase == "waitingForPeer"
        and is_joined is True
        and had_connected_session_continuity is True
        and system_session.startswith("active(")
        and backend_self_joined is True
        and backend_peer_joined is True
        and backend_peer_device is True
        and backend_channel_status == "waiting-for-peer"
        and remote_wake_capability_kind == "unavailable"
    ):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.joined_session_lost_wake_capability",
                scope="backend",
                message=(
                    "joined live session regressed to waiting-for-peer without wake capability "
                    f"backendReadiness={backend_readiness} systemSession={system_session}"
                ),
            )
        )

    if phase == "ready" and not is_joined:
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.ready_without_join",
                scope="local",
                message="selectedPeerPhase=ready while isJoined=false",
            )
        )

    if phase == "ready" and backend_can_transmit is False:
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.ready_while_backend_cannot_transmit",
                scope="backend",
                message="selectedPeerPhase=ready while backendCanTransmit=false",
            )
        )

    if local_join_failure != "none":
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.local_join_failure_present",
                scope="local",
                message=f"localJoinFailure={local_join_failure} systemSession={system_session}",
            )
        )

    selected_contact = snapshot.get("selectedContact", "none")
    selected_contact_projection = contacts.get(selected_contact) if selected_contact != "none" else None
    if phase == "idle" and selected_contact_projection is not None:
        contact_online = snapshot_bool(selected_contact_projection, "isOnline")
        if contact_online and "online" not in snapshot.get("selectedPeerStatus", "").lower():
            violations.append(
                build_violation(
                    subject=report.handle,
                    invariant_id="selected.online_contact_projected_offline",
                    scope="local",
                    message=(
                        f"selected contact {selected_contact} is online in contact projection, "
                        f"but selectedPeerStatus={snapshot.get('selectedPeerStatus', 'none')}"
                    ),
                )
            )

    return violations


def dedupe_violations(violations: Iterable[InvariantViolation]) -> list[InvariantViolation]:
    deduped: list[InvariantViolation] = []
    seen: set[tuple[str, str, str]] = set()
    for violation in violations:
        key = (violation.subject, violation.invariant_id, violation.scope)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(violation)
    return deduped


def analyze_reports(reports: list[Report]) -> list[InvariantViolation]:
    violations: list[InvariantViolation] = []
    for report in reports:
        violations.extend(report.invariant_violations)
        violations.extend(report.backend_invariant_violations)
        violations.extend(analyze_report(report))

    if len(reports) == 2:
        left, right = reports
        left_phase = left.snapshot.get("selectedPeerPhase", "none")
        right_phase = right.snapshot.get("selectedPeerPhase", "none")
        live_session_phases = {"waitingForPeer", "wakeReady", "ready", "startingTransmit", "transmitting", "receiving"}
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
                violations.append(
                    build_violation(
                        subject="pair",
                        invariant_id="pair.backend_ready_ui_not_live",
                        scope="pair",
                        message=(
                            "backend is ready on both devices, but at least one UI is still not in a live session state "
                            f"left={left.handle}:{left_phase} right={right.handle}:{right_phase}"
                        ),
                    )
                )

        def snapshot_lacks_session_context(snapshot: dict[str, str]) -> bool:
            return (
                snapshot.get("selectedContact", "none") == "none"
                and snapshot.get("systemSession", "none") == "none"
                and snapshot.get("backendChannelStatus", "none") == "none"
                and snapshot_bool(snapshot, "isJoined") is False
            )

        if left_backend_ready and left_phase in live_session_phases and snapshot_lacks_session_context(right.snapshot):
            violations.append(
                build_violation(
                    subject="pair",
                    invariant_id="pair.one_sided_ready_session",
                    scope="pair",
                    message=(
                        "one device restored or retained a live ready session while the peer has no local/backend session context "
                        f"left={left.handle}:{left_phase} right={right.handle}:{right_phase}"
                    ),
                )
            )

        if right_backend_ready and right_phase in live_session_phases and snapshot_lacks_session_context(left.snapshot):
            violations.append(
                build_violation(
                    subject="pair",
                    invariant_id="pair.one_sided_ready_session",
                    scope="pair",
                    message=(
                        "one device restored or retained a live ready session while the peer has no local/backend session context "
                        f"left={left.handle}:{left_phase} right={right.handle}:{right_phase}"
                    ),
                )
            )

    return dedupe_violations(violations)


def render_violation(violation: InvariantViolation) -> str:
    prefix = f"[{violation.scope}] [{violation.invariant_id}] subject={violation.subject} source={violation.source}"
    if violation.message:
        return f"{prefix} {violation.message}"
    return prefix


def violation_payload(violation: InvariantViolation) -> dict[str, str | None]:
    return {
        "subject": violation.subject,
        "invariantId": violation.invariant_id,
        "scope": violation.scope,
        "message": violation.message,
        "source": violation.source,
        "timestamp": violation.timestamp.isoformat() if violation.timestamp else None,
    }


def report_payload(report: Report) -> dict[str, object]:
    return {
        "handle": report.handle,
        "deviceId": report.device_id,
        "uploadedAt": report.uploaded_at,
        "snapshot": report.snapshot,
        "explicitInvariantViolations": [violation_payload(violation) for violation in report.invariant_violations],
        "backendInvariantViolations": [violation_payload(violation) for violation in report.backend_invariant_violations],
    }


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

    violations = analyze_reports(reports)

    if args.json:
        payload = {
            "reports": [report_payload(report) for report in reports],
            "violations": [violation_payload(violation) for violation in violations],
            "timeline": [
                {
                    "timestamp": timestamp.isoformat(),
                    "line": line,
                }
                for timestamp, line in merged_events(reports)
            ],
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print("LATEST SNAPSHOTS")
        for report in reports:
            print(render_snapshot(report))

        print("\nINVARIANT VIOLATIONS")
        if violations:
            for violation in violations:
                print(f"- {render_violation(violation)}")
        else:
            print("- none")

        print("\nMERGED TIMELINE")
        for timestamp, line in merged_events(reports):
            print(f"{timestamp.isoformat()} {line}")

    if args.fail_on_violations and violations:
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
