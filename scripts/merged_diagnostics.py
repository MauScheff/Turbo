#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Iterable

import query_telemetry


SECTION_HEADER_RE = re.compile(
    r"^(STATE SNAPSHOT|STRUCTURED DIAGNOSTICS|STATE TIMELINE|INVARIANT VIOLATIONS|DIAGNOSTICS)$"
)
TIMELINE_RE = re.compile(r"^\[(?P<timestamp>[^\]]+)\] \[(?P<label>[^\]]+)\] (?P<body>.*)$")
INVARIANT_RE = re.compile(
    r"^\[(?P<timestamp>[^\]]+)\] \[(?P<invariant_id>[^\]]+)\] \[(?P<scope>[^\]]+)\](?: (?P<body>.*))?$"
)
CONTACT_FIELD_RE = re.compile(r"^contact\[(?P<handle>[^\]]+)\]\.(?P<field>.+)$")
APP_VERSION_SCENARIO_RE = re.compile(r"^scenario:(?P<name>[^:]+):(?P<run_id>[^:]+):(?P<device_id>.+)$")
TIMELINE_SUBJECT_RE = re.compile(r"^\[(?P<subject>[^\]]+)\]")
TEXT_CONTEXT_RE = re.compile(
    r"(?P<key>"
    r"scenarioRunID|scenarioRunId|scenario_run_id|"
    r"sessionID|sessionId|session_id|webSocketSessionID|webSocketSessionId|"
    r"channelUUID|channelID|channelId|channel_id|activeChannelID|activeChannelId|backendChannelID|"
    r"contactID|contactId|contact_id|selectedContactID|selectedContactId|selectedHandle|systemActiveContactID|"
    r"transmitActiveContactID|peer_handle|selectedContact|"
    r"attemptID|attemptId|attempt_id|directQuicAttemptId|directQuicAttemptID"
    r")=(?P<value>\"[^\"]*\"|[^\s,;]+)"
)
TEXT_CONTEXT_COLON_RE = re.compile(
    r"(?P<key>"
    r"scenarioRunID|scenarioRunId|"
    r"sessionID|sessionId|webSocketSessionID|webSocketSessionId|"
    r"channelUUID|channelID|channelId|activeChannelID|backendChannelID|"
    r"contactID|contactId|selectedContactID|selectedHandle|systemActiveContactID|transmitActiveContactID|"
    r"attemptID|attemptId|directQuicAttemptId|directQuicAttemptID"
    r"): (?P<value>\"[^\"]*\"|[^\s,\)]+)"
)
GROUP_DIMENSION_ORDER = ("scenarioRun", "session", "channel", "contact", "attempt")
KEY_VALUE_RE = re.compile(r"(?P<key>[A-Za-z][A-Za-z0-9_]*)=(?P<value>\"[^\"]*\"|[^\s]+)")


@dataclass(frozen=True)
class InvariantViolation:
    subject: str
    invariant_id: str
    scope: str
    message: str
    source: str
    timestamp: datetime | None = None
    metadata: dict[str, str] = field(default_factory=dict)


@dataclass
class Report:
    handle: str
    device_id: str
    app_version: str
    scenario_name: str | None
    scenario_run_id: str | None
    uploaded_at: str
    structured_diagnostics: dict | None
    snapshot: dict[str, str]
    state_timeline: list[tuple[datetime, str]]
    invariant_violations: list[InvariantViolation]
    backend_invariant_violations: list[InvariantViolation]
    diagnostics: list[tuple[datetime, str]]
    wake_events: list[tuple[datetime, str]]


@dataclass(frozen=True)
class SourceWarning:
    subject: str
    source: str
    message: str


@dataclass(frozen=True)
class TelemetryEvent:
    timestamp: datetime
    handle: str
    device_id: str
    session_id: str
    event_name: str
    source: str
    severity: str
    phase: str
    reason: str
    message: str
    channel_id: str
    peer_handle: str
    invariant_id: str
    metadata_text: str


@dataclass
class DiagnosticGroup:
    dimension: str
    value: str
    event_count: int = 0
    violation_count: int = 0
    subjects: set[str] = field(default_factory=set)
    sources: set[str] = field(default_factory=set)
    first_seen: datetime | None = None
    last_seen: datetime | None = None
    samples: list[str] = field(default_factory=list)

    def add(
        self,
        *,
        timestamp: datetime | None,
        subject: str,
        source: str,
        line: str,
        is_violation: bool,
    ) -> None:
        if is_violation:
            self.violation_count += 1
        else:
            self.event_count += 1
        if subject:
            self.subjects.add(subject)
        if source:
            self.sources.add(source)
        if timestamp is not None:
            if self.first_seen is None or timestamp < self.first_seen:
                self.first_seen = timestamp
            if self.last_seen is None or timestamp > self.last_seen:
                self.last_seen = timestamp
        if line and len(self.samples) < 3:
            self.samples.append(line if len(line) <= 220 else line[:220] + "...<truncated>")


@dataclass
class ConnectionTimingAttempt:
    channel_id: str
    request_id: str
    subjects: set[str] = field(default_factory=set)
    published_join_accepted_at: datetime | None = None
    received_join_accepted_at: datetime | None = None
    first_media_prewarm_at: datetime | None = None
    last_media_ready_at: datetime | None = None
    first_ptt_joined_at: datetime | None = None
    last_ptt_joined_at: datetime | None = None
    backend_ready_projection_at: datetime | None = None


@dataclass
class DuplicateReadinessPublish:
    subject: str
    contact_id: str
    channel_id: str
    state: str
    count: int
    first_seen: datetime
    last_seen: datetime
    reasons: set[str] = field(default_factory=set)


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
        "--backend-timeout",
        type=int,
        default=15,
        help="Maximum seconds for each backend diagnostics HTTP request.",
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
        "--full-metadata",
        action="store_true",
        help="Do not truncate telemetry metadata in the human timeline.",
    )
    telemetry_group = parser.add_mutually_exclusive_group()
    telemetry_group.add_argument(
        "--include-telemetry",
        dest="include_telemetry",
        action="store_true",
        default=True,
        help="Merge compact Cloudflare telemetry events into the timeline. This is the default.",
    )
    telemetry_group.add_argument(
        "--no-telemetry",
        dest="include_telemetry",
        action="store_false",
        help="Use only backend latest diagnostics snapshots/transcripts.",
    )
    parser.add_argument(
        "--telemetry-hours",
        type=int,
        default=6,
        help="Telemetry lookback window used with --include-telemetry.",
    )
    parser.add_argument(
        "--telemetry-limit",
        type=int,
        default=500,
        help="Maximum Cloudflare telemetry rows to merge.",
    )
    parser.add_argument(
        "--include-heartbeats",
        action="store_true",
        help="Include backend presence heartbeat telemetry events in the merged timeline.",
    )
    parser.add_argument(
        "--telemetry-dataset",
        default=query_telemetry.DEFAULT_DATASET,
        help="Cloudflare Analytics Engine dataset name.",
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


def fetch_latest_report(
    base_url: str,
    handle: str,
    insecure: bool,
    *,
    timeout: int,
    device_id: str | None = None,
) -> Report:
    command = [
        "curl",
        "--fail-with-body",
        "-sS",
        "--connect-timeout",
        "5",
        "--max-time",
        str(timeout),
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
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout + 2)
    except subprocess.CalledProcessError as exc:
        body = (exc.stderr or exc.stdout).strip()
        raise RuntimeError(f"{handle}: request failed: {body}") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{handle}: request timed out after {timeout}s") from exc

    payload = json.loads(result.stdout)

    report = payload["report"]
    transcript = report.get("transcript", "")
    sections = split_sections(transcript)
    structured_diagnostics = parse_structured_diagnostics(sections.get("STRUCTURED DIAGNOSTICS", ""))
    raw_app_version = (
        structured_diagnostics.get("appVersion")
        if isinstance(structured_diagnostics, dict)
        else report.get("appVersion", "")
    )
    app_version = raw_app_version if isinstance(raw_app_version, str) else ""
    scenario_name = (
        structured_diagnostics.get("scenarioName")
        if isinstance(structured_diagnostics, dict) and isinstance(structured_diagnostics.get("scenarioName"), str)
        else None
    )
    scenario_run_id = (
        structured_diagnostics.get("scenarioRunId")
        if isinstance(structured_diagnostics, dict) and isinstance(structured_diagnostics.get("scenarioRunId"), str)
        else None
    )
    if scenario_name is None or scenario_run_id is None:
        parsed_scenario = scenario_context_from_app_version(app_version)
        scenario_name = scenario_name or parsed_scenario.get("scenarioName")
        scenario_run_id = scenario_run_id or parsed_scenario.get("scenarioRunId")
    structured_snapshot = snapshot_from_structured_diagnostics(structured_diagnostics)
    structured_invariant_violations = invariant_violations_from_structured_diagnostics(
        handle,
        structured_diagnostics,
    )
    return Report(
        handle=handle,
        device_id=report.get("deviceId", device_id or "unknown"),
        app_version=app_version,
        scenario_name=scenario_name,
        scenario_run_id=scenario_run_id,
        uploaded_at=report.get("uploadedAt", ""),
        structured_diagnostics=structured_diagnostics,
        snapshot=structured_snapshot or parse_snapshot(sections.get("STATE SNAPSHOT", "")),
        state_timeline=parse_timeline_section(handle, "state", sections.get("STATE TIMELINE", "")),
        invariant_violations=(
            structured_invariant_violations
            if structured_diagnostics is not None
            else parse_invariant_section(handle, sections.get("INVARIANT VIOLATIONS", ""))
        ),
        backend_invariant_violations=fetch_backend_invariant_events(base_url, handle, insecure, timeout=timeout),
        diagnostics=parse_timeline_section(handle, "diag", sections.get("DIAGNOSTICS", "")),
        wake_events=fetch_wake_events(base_url, handle, insecure, timeout=timeout),
    )


def fetch_json(base_url: str, handle: str, path: str, insecure: bool, *, timeout: int) -> dict:
    command = [
        "curl",
        "--fail-with-body",
        "-sS",
        "--connect-timeout",
        "5",
        "--max-time",
        str(timeout),
        "-H",
        f"x-turbo-user-handle: {handle}",
        "-H",
        f"Authorization: Bearer {handle}",
    ]
    if insecure:
        command.append("--insecure")
    command.append(f"{base_url.rstrip('/')}{path}")
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout + 2)
    except subprocess.CalledProcessError as exc:
        body = (exc.stderr or exc.stdout).strip()
        raise RuntimeError(f"{handle}: request failed: {body}") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{handle}: request timed out after {timeout}s") from exc
    return json.loads(result.stdout)


def fetch_wake_events(base_url: str, handle: str, insecure: bool, *, timeout: int) -> list[tuple[datetime, str]]:
    payload = fetch_json(base_url, handle, "/v1/dev/wake-events/recent", insecure, timeout=timeout)
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


def missing_latest_diagnostics_error(exc: RuntimeError) -> bool:
    message = str(exc).lower()
    return "diagnostics report not found" in message or "request timed out" in message or missing_route_error(exc)


def fetch_backend_invariant_events(
    base_url: str,
    handle: str,
    insecure: bool,
    *,
    timeout: int,
) -> list[InvariantViolation]:
    try:
        payload = fetch_json(base_url, handle, "/v1/dev/invariant-events/recent", insecure, timeout=timeout)
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


def parse_structured_diagnostics(section: str) -> dict | None:
    if not section or section == "<empty>":
        return None
    try:
        payload = json.loads(section)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def snapshot_from_structured_diagnostics(payload: dict | None) -> dict[str, str]:
    if not payload:
        return {}
    projection = payload.get("projection")
    if not isinstance(projection, dict):
        return {}
    selected = projection.get("selectedSession")
    if not isinstance(selected, dict):
        return {}

    snapshot: dict[str, str] = {}

    def put(key: str, value: object) -> None:
        if value is None:
            snapshot[key] = "none"
        elif isinstance(value, bool):
            snapshot[key] = "true" if value else "false"
        else:
            snapshot[key] = str(value)

    selected_key_map = {
        "selectedHandle": "selectedContact",
        "selectedPhase": "selectedPeerPhase",
        "selectedPhaseDetail": "selectedPeerPhaseDetail",
        "relationship": "selectedPeerRelationship",
        "statusMessage": "selectedPeerStatus",
        "canTransmitNow": "selectedPeerCanTransmit",
        "isJoined": "isJoined",
        "isTransmitting": "isTransmitting",
        "activeChannelID": "activeChannelID",
        "pendingAction": "pendingAction",
        "reconciliationAction": "selectedPeerReconciliationAction",
        "hadConnectedSessionContinuity": "hadConnectedSessionContinuity",
        "systemSession": "systemSession",
        "mediaState": "mediaState",
        "backendChannelStatus": "backendChannelStatus",
        "backendReadiness": "backendReadiness",
        "backendMembership": "backendMembership",
        "backendRequestRelationship": "backendRequestRelationship",
        "backendSelfJoined": "backendSelfJoined",
        "backendPeerJoined": "backendPeerJoined",
        "backendPeerDeviceConnected": "backendPeerDeviceConnected",
        "backendActiveTransmitterUserId": "backendActiveTransmitterUserId",
        "backendActiveTransmitId": "backendActiveTransmitId",
        "backendActiveTransmitExpiresAt": "backendActiveTransmitExpiresAt",
        "backendServerTimestamp": "backendServerTimestamp",
        "remoteAudioReadiness": "remoteAudioReadiness",
        "remoteWakeCapability": "remoteWakeCapability",
        "remoteWakeCapabilityKind": "remoteWakeCapabilityKind",
        "backendCanTransmit": "backendCanTransmit",
        "firstTalkStartupProfile": "firstTalkStartupProfile",
        "pttTokenRegistrationKind": "pttTokenRegistrationKind",
        "incomingWakeActivationState": "incomingWakeActivationState",
        "incomingWakeBufferedChunkCount": "incomingWakeBufferedChunkCount",
    }
    for source_key, snapshot_key in selected_key_map.items():
        put(snapshot_key, selected.get(source_key))

    put("backendWebSocketConnected", projection.get("isWebSocketConnected"))
    put("status", projection.get("statusMessage"))
    put("backendStatus", projection.get("backendStatusMessage"))
    put("identity", payload.get("handle"))

    contacts = projection.get("contacts")
    if isinstance(contacts, list):
        contact_key_map = {
            "isOnline": "isOnline",
            "listState": "listState",
            "badgeStatus": "badgeStatus",
            "listSection": "listSection",
            "presencePill": "presencePill",
            "requestRelationship": "requestRelationship",
            "hasIncomingRequest": "hasIncomingRequest",
            "hasOutgoingRequest": "hasOutgoingRequest",
            "requestCount": "requestCount",
            "incomingInviteCount": "incomingInviteCount",
            "outgoingInviteCount": "outgoingInviteCount",
        }
        for contact in contacts:
            if not isinstance(contact, dict):
                continue
            handle = contact.get("handle")
            if not isinstance(handle, str) or not handle:
                continue
            for source_key, snapshot_key in contact_key_map.items():
                put(f"contact[{handle}].{snapshot_key}", contact.get(source_key))

    return snapshot


def invariant_violations_from_structured_diagnostics(
    handle: str,
    payload: dict | None,
) -> list[InvariantViolation]:
    if not payload:
        return []
    raw_violations = payload.get("invariantViolations")
    if not isinstance(raw_violations, list):
        return []
    violations: list[InvariantViolation] = []
    for raw_violation in raw_violations:
        if not isinstance(raw_violation, dict):
            continue
        invariant_id = raw_violation.get("invariantID") or raw_violation.get("invariantId")
        scope = raw_violation.get("scope")
        if not isinstance(invariant_id, str) or not isinstance(scope, str):
            continue
        message = raw_violation.get("message")
        metadata = raw_violation.get("metadata")
        violations.append(
            InvariantViolation(
                subject=handle,
                invariant_id=invariant_id,
                scope=scope,
                message=message if isinstance(message, str) else "",
                source="structured",
                timestamp=parse_timestamp(str(raw_violation.get("timestamp", ""))),
                metadata={
                    str(key): str(value)
                    for key, value in metadata.items()
                } if isinstance(metadata, dict) else {},
            )
        )
    return violations


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

    # Cloudflare SQL returns UTC timestamps without an explicit timezone. Old
    # localized transcript entries may be time-only; keep those at epoch day.
    for fmt in ("%Y-%m-%d %H:%M:%S", "%I:%M:%S %p", "%H:%M:%S", "%I:%M:%S\u202fa.m.", "%I:%M:%S\u202fp.m."):
        try:
            parsed = datetime.strptime(text, fmt)
            if fmt.startswith("%Y"):
                return parsed.replace(tzinfo=timezone.utc)
            return datetime(1970, 1, 1, parsed.hour, parsed.minute, parsed.second, tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def parse_backend_instant(text: str) -> datetime | None:
    text = text.strip()
    if not text or text == "none" or not text.endswith("Z"):
        return None
    without_zone = text[:-1]
    base, separator, fractional = without_zone.partition(".")
    base_timestamp = parse_timestamp(base + "Z")
    if base_timestamp is None or not separator:
        return base_timestamp
    digits = "".join(character for character in fractional if character.isdigit())
    if not digits:
        return base_timestamp
    fractional_seconds = int(digits) / (10 ** len(digits))
    return base_timestamp.replace(microsecond=0) + timedelta(seconds=fractional_seconds)


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


def merged_events(
    reports: Iterable[Report],
    telemetry_events: Iterable[TelemetryEvent] = (),
    *,
    full_metadata: bool = False,
) -> list[TelemetryEvent]:
    events: list[tuple[datetime, str]] = []
    for report in reports:
        events.extend(report.state_timeline)
        events.extend(render_invariant_events(report.invariant_violations))
        events.extend(render_invariant_events(report.backend_invariant_violations))
        events.extend(report.diagnostics)
        events.extend(report.wake_events)
    events.extend(render_telemetry_events(telemetry_events, full_metadata=full_metadata))
    return sorted(events, key=lambda item: item[0])


def fetch_telemetry_events(
    handles: Iterable[str],
    device_ids: Iterable[str],
    *,
    hours: int,
    limit: int,
    dataset: str,
    insecure: bool,
    include_heartbeats: bool,
) -> list[TelemetryEvent]:
    account_id = query_telemetry.DEFAULT_ACCOUNT_ID
    api_token = query_telemetry.DEFAULT_API_TOKEN
    if not account_id or not api_token:
        print(
            "telemetry skipped: missing TURBO_CLOUDFLARE_ACCOUNT_ID or "
            "TURBO_CLOUDFLARE_ANALYTICS_READ_TOKEN",
            file=sys.stderr,
        )
        return []

    identity_filters: list[str] = []
    for handle in sorted(set(handles)):
        identity_filters.append(f"blob5 = {sql_string(handle)}")
    for device_id in sorted(set(device_id for device_id in device_ids if device_id)):
        identity_filters.append(f"blob6 = {sql_string(device_id)}")
    if not identity_filters:
        return []

    filters = [
        f"timestamp > NOW() - INTERVAL '{hours}' HOUR",
        "(" + " OR ".join(identity_filters) + ")",
    ]
    if not include_heartbeats:
        filters.append(f"blob1 != {sql_string('backend.presence.heartbeat')}")
    where_clause = " AND ".join(filters)
    query = f"""
SELECT
  timestamp,
  blob1 AS event_name,
  blob2 AS source,
  blob3 AS severity,
  blob5 AS user_handle,
  blob6 AS device_id,
  blob7 AS session_id,
  blob8 AS channel_id,
  blob11 AS peer_handle,
  blob14 AS invariant_id,
  blob15 AS phase,
  blob16 AS reason,
  blob17 AS message,
  blob18 AS metadata_text,
  blob19 AS dev_traffic,
  double2 AS alert_flag
FROM {dataset}
WHERE {where_clause}
ORDER BY timestamp DESC
LIMIT {limit}
""".strip()
    try:
        response = query_telemetry.execute_query(account_id, api_token, query, insecure=insecure)
    except SystemExit as exc:
        print(f"telemetry skipped: {exc}", file=sys.stderr)
        return []

    rows = response.get("data")
    if not isinstance(rows, list):
        return []

    events: list[TelemetryEvent] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        timestamp = parse_timestamp(str(row.get("timestamp", "")))
        if timestamp is None:
            continue
        events.append(
            TelemetryEvent(
                timestamp=timestamp,
                handle=str(row.get("user_handle") or row.get("device_id") or "unknown"),
                device_id=str(row.get("device_id") or ""),
                session_id=str(row.get("session_id") or ""),
                event_name=str(row.get("event_name") or "unknown"),
                source=str(row.get("source") or "unknown"),
                severity=str(row.get("severity") or "unknown"),
                phase=str(row.get("phase") or ""),
                reason=str(row.get("reason") or ""),
                message=str(row.get("message") or ""),
                channel_id=str(row.get("channel_id") or ""),
                peer_handle=str(row.get("peer_handle") or ""),
                invariant_id=str(row.get("invariant_id") or ""),
                metadata_text=str(row.get("metadata_text") or ""),
            )
        )
    return events


def render_telemetry_events(
    telemetry_events: Iterable[TelemetryEvent],
    *,
    full_metadata: bool,
) -> list[tuple[datetime, str]]:
    events: list[tuple[datetime, str]] = []
    for event in telemetry_events:
        pieces = [
            f"severity={event.severity}",
            f"source={event.source}",
            f"event={event.event_name}",
        ]
        for key, value in (
            ("device_id", event.device_id),
            ("session_id", event.session_id),
            ("phase", event.phase),
            ("reason", event.reason),
            ("message", event.message),
            ("channel_id", event.channel_id),
            ("peer_handle", event.peer_handle),
            ("invariant_id", event.invariant_id),
        ):
            if value:
                pieces.append(f"{key}={value}")
        if event.metadata_text:
            metadata_text = event.metadata_text
            if not full_metadata and len(metadata_text) > 500:
                metadata_text = metadata_text[:500] + "...<truncated>"
            pieces.append(f"metadata={metadata_text}")
        events.append((event.timestamp, f"[{event.handle}] [telemetry] " + " ".join(pieces)))
    return events


def telemetry_metadata(event: TelemetryEvent) -> dict[str, str]:
    if not event.metadata_text:
        return {}
    try:
        parsed = json.loads(event.metadata_text)
    except json.JSONDecodeError:
        return {}
    if not isinstance(parsed, dict):
        return {}
    return {str(key): str(value) for key, value in parsed.items()}


def telemetry_invariant_violations(events: Iterable[TelemetryEvent]) -> list[InvariantViolation]:
    violations: list[InvariantViolation] = []
    for event in events:
        invariant_id = event.invariant_id.strip()
        if not invariant_id:
            continue
        metadata = telemetry_metadata(event)
        scope = metadata.get("scope") or event.reason or "telemetry"
        violations.append(
            build_violation(
                subject=event.handle,
                invariant_id=invariant_id,
                scope=scope,
                message=event.message or event.event_name,
                source="telemetry",
                timestamp=event.timestamp,
                metadata=metadata,
            )
        )
    return violations


TELEMETRY_SNAPSHOT_REQUIRED_KEYS = {
    "selectedPeerRelationship",
    "pendingAction",
    "isJoined",
    "systemSession",
    "backendChannelStatus",
    "backendReadiness",
    "backendSelfJoined",
    "backendPeerJoined",
    "backendPeerDeviceConnected",
}


def snapshot_from_telemetry_event(event: TelemetryEvent) -> dict[str, str] | None:
    metadata = telemetry_metadata(event)
    if not TELEMETRY_SNAPSHOT_REQUIRED_KEYS.issubset(metadata.keys()):
        return None

    snapshot: dict[str, str] = {
        "selectedPeerPhase": event.phase or metadata.get("selectedPeerPhase", "none"),
        "selectedContact": event.peer_handle or metadata.get("selectedHandle", "none"),
        "identity": event.handle,
    }
    for key, value in metadata.items():
        if value:
            snapshot[key] = value
    if event.channel_id:
        snapshot.setdefault("backendChannelID", event.channel_id)
        snapshot.setdefault("backendChannelId", event.channel_id)
    return snapshot


def telemetry_snapshot_reports(
    events: Iterable[TelemetryEvent],
    reports: Iterable[Report],
) -> list[Report]:
    existing_subjects = {(report.handle, report.device_id) for report in reports}
    latest_by_subject: dict[tuple[str, str], tuple[TelemetryEvent, dict[str, str]]] = {}
    for event in events:
        snapshot = snapshot_from_telemetry_event(event)
        if snapshot is None:
            continue
        subject = (event.handle, event.device_id)
        if subject in existing_subjects:
            continue
        previous = latest_by_subject.get(subject)
        if previous is None or event.timestamp > previous[0].timestamp:
            latest_by_subject[subject] = (event, snapshot)

    synthetic_reports: list[Report] = []
    for event, snapshot in latest_by_subject.values():
        synthetic_reports.append(
            Report(
                handle=event.handle,
                device_id=event.device_id,
                app_version="telemetry",
                scenario_name=None,
                scenario_run_id=None,
                uploaded_at=event.timestamp.isoformat(),
                structured_diagnostics=None,
                snapshot=snapshot,
                state_timeline=[],
                invariant_violations=[],
                backend_invariant_violations=[],
                diagnostics=[],
                wake_events=[],
            )
        )
    return synthetic_reports


def sql_string(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def scenario_context_from_app_version(app_version: str) -> dict[str, str]:
    match = APP_VERSION_SCENARIO_RE.match(app_version.strip())
    if not match:
        return {}
    return {
        "scenarioName": match.group("name"),
        "scenarioRunId": match.group("run_id"),
        "deviceId": match.group("device_id"),
    }


def empty_contexts() -> dict[str, set[str]]:
    return {dimension: set() for dimension in GROUP_DIMENSION_ORDER}


def context_dimension_for_key(key: str) -> str | None:
    normalized = key.strip()
    if normalized in {"scenarioRunID", "scenarioRunId", "scenario_run_id"}:
        return "scenarioRun"
    if normalized in {
        "sessionID",
        "sessionId",
        "session_id",
        "webSocketSessionID",
        "webSocketSessionId",
    }:
        return "session"
    if normalized in {
        "channelUUID",
        "channelID",
        "channelId",
        "channel_id",
        "activeChannelID",
        "activeChannelId",
        "backendChannelID",
    }:
        return "channel"
    if normalized in {
        "contactID",
        "contactId",
        "contact_id",
        "selectedContactID",
        "selectedContactId",
        "selectedHandle",
        "systemActiveContactID",
        "transmitActiveContactID",
        "peer_handle",
        "selectedContact",
    }:
        return "contact"
    if normalized in {
        "attemptID",
        "attemptId",
        "attempt_id",
        "directQuicAttemptId",
        "directQuicAttemptID",
    }:
        return "attempt"
    return None


def normalized_context_value(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip().strip(",;")
    if text.startswith('"') and text.endswith('"') and len(text) >= 2:
        text = text[1:-1]
    while text.startswith("Optional(") and text.endswith(")"):
        text = text[len("Optional("):-1].strip()
    text = text.strip().strip(",;)").strip('"')
    if not text or text in {"none", "nil", "null", "unknown", "<missing>"}:
        return None
    return text


def add_context_value(contexts: dict[str, set[str]], key: str, value: object) -> None:
    dimension = context_dimension_for_key(key)
    normalized_value = normalized_context_value(value)
    if dimension is None or normalized_value is None:
        return
    contexts.setdefault(dimension, set()).add(normalized_value)


def merge_contexts(*context_sets: dict[str, set[str]]) -> dict[str, set[str]]:
    merged = empty_contexts()
    for contexts in context_sets:
        for dimension, values in contexts.items():
            if dimension in merged:
                merged[dimension].update(values)
    return merged


def contexts_from_text(text: str) -> dict[str, set[str]]:
    contexts = empty_contexts()
    for match in TEXT_CONTEXT_RE.finditer(text):
        add_context_value(contexts, match.group("key"), match.group("value"))
    for match in TEXT_CONTEXT_COLON_RE.finditer(text):
        add_context_value(contexts, match.group("key"), match.group("value"))
    return contexts


def contexts_from_structured_diagnostics(payload: dict | None) -> dict[str, set[str]]:
    contexts = empty_contexts()
    if not payload:
        return contexts

    add_context_value(contexts, "scenarioRunId", payload.get("scenarioRunId"))
    scenario_from_app = scenario_context_from_app_version(str(payload.get("appVersion") or ""))
    add_context_value(contexts, "scenarioRunId", scenario_from_app.get("scenarioRunId"))

    projection = payload.get("projection")
    if isinstance(projection, dict):
        local_session = projection.get("localSession")
        if isinstance(local_session, dict):
            for key in (
                "selectedContactID",
                "selectedHandle",
                "activeChannelID",
                "systemActiveContactID",
                "systemChannelUUID",
                "transmitActiveContactID",
            ):
                add_context_value(contexts, key, local_session.get(key))

        selected = projection.get("selectedSession")
        if isinstance(selected, dict):
            add_context_value(contexts, "selectedContact", selected.get("selectedHandle"))
            add_context_value(contexts, "activeChannelID", selected.get("activeChannelID"))

    direct_quic = payload.get("directQuic")
    if isinstance(direct_quic, dict):
        add_context_value(contexts, "attemptID", direct_quic.get("attemptID"))
        add_context_value(contexts, "channelID", direct_quic.get("channelID"))

    state_captures = payload.get("stateCaptures")
    if isinstance(state_captures, list):
        for capture in state_captures:
            if not isinstance(capture, dict):
                continue
            fields = capture.get("fields")
            if not isinstance(fields, dict):
                continue
            for key, value in fields.items():
                add_context_value(contexts, str(key), value)

    reducer_reports = payload.get("reducerTransitionReports")
    if isinstance(reducer_reports, list):
        for report in reducer_reports:
            if not isinstance(report, dict):
                continue
            correlation_ids = report.get("correlationIDs")
            if isinstance(correlation_ids, dict):
                for key, value in correlation_ids.items():
                    add_context_value(contexts, str(key), value)
            for key in ("previousStateSummary", "nextStateSummary", "eventName"):
                value = report.get(key)
                if isinstance(value, str):
                    contexts = merge_contexts(contexts, contexts_from_text(value))
            effects = report.get("effectsEmitted")
            if isinstance(effects, list):
                for effect in effects:
                    if isinstance(effect, str):
                        contexts = merge_contexts(contexts, contexts_from_text(effect))

    return contexts


def contexts_from_report(report: Report) -> dict[str, set[str]]:
    contexts = contexts_from_structured_diagnostics(report.structured_diagnostics)
    add_context_value(contexts, "scenarioRunId", report.scenario_run_id)
    add_context_value(contexts, "selectedContact", report.handle)
    for key in (
        "selectedContactID",
        "selectedContact",
        "activeChannelID",
        "activeChannelId",
        "systemActiveContactID",
        "systemChannelUUID",
        "transmitActiveContactID",
    ):
        add_context_value(contexts, key, report.snapshot.get(key))
    return merge_contexts(contexts, contexts_from_text(report.app_version))


def contexts_from_violation(violation: InvariantViolation) -> dict[str, set[str]]:
    contexts = contexts_from_text(violation.message)
    add_context_value(contexts, "selectedContact", violation.subject)
    for key, value in violation.metadata.items():
        add_context_value(contexts, key, value)
    return contexts


def contexts_from_telemetry(event: TelemetryEvent) -> dict[str, set[str]]:
    contexts = empty_contexts()
    add_context_value(contexts, "selectedContact", event.handle)
    add_context_value(contexts, "session_id", event.session_id)
    add_context_value(contexts, "channel_id", event.channel_id)
    add_context_value(contexts, "peer_handle", event.peer_handle)
    add_context_value(contexts, "attemptId", metadata_value(event.metadata_text, "attemptId"))
    add_context_value(contexts, "attemptID", metadata_value(event.metadata_text, "attemptID"))
    return merge_contexts(contexts, contexts_from_text(event.metadata_text), contexts_from_text(event.message))


def metadata_value(metadata_text: str, key: str) -> object:
    if not metadata_text:
        return None
    try:
        parsed = json.loads(metadata_text)
    except json.JSONDecodeError:
        return None
    if isinstance(parsed, dict):
        return parsed.get(key)
    return None


def subject_from_timeline_line(line: str) -> str:
    match = TIMELINE_SUBJECT_RE.match(line)
    return match.group("subject") if match else "unknown"


def add_contexts_to_groups(
    groups: dict[tuple[str, str], DiagnosticGroup],
    contexts: dict[str, set[str]],
    *,
    timestamp: datetime | None,
    subject: str,
    source: str,
    line: str,
    is_violation: bool,
) -> None:
    for dimension in GROUP_DIMENSION_ORDER:
        for value in contexts.get(dimension, set()):
            key = (dimension, value)
            group = groups.get(key)
            if group is None:
                group = DiagnosticGroup(dimension=dimension, value=value)
                groups[key] = group
            group.add(
                timestamp=timestamp,
                subject=subject,
                source=source,
                line=line,
                is_violation=is_violation,
            )


def build_diagnostic_groups(
    reports: Iterable[Report],
    violations: Iterable[InvariantViolation],
    telemetry_events: Iterable[TelemetryEvent],
    timeline: Iterable[tuple[datetime, str]],
) -> list[DiagnosticGroup]:
    groups: dict[tuple[str, str], DiagnosticGroup] = {}
    report_contexts_by_subject: dict[str, dict[str, set[str]]] = {}

    for report in reports:
        contexts = contexts_from_report(report)
        report_contexts_by_subject[report.handle] = contexts
        add_contexts_to_groups(
            groups,
            contexts,
            timestamp=parse_timestamp(report.uploaded_at),
            subject=report.handle,
            source="report",
            line=f"latest diagnostics for {report.handle}",
            is_violation=False,
        )

    for violation in violations:
        base_contexts = report_contexts_by_subject.get(violation.subject, empty_contexts())
        contexts = merge_contexts(base_contexts, contexts_from_violation(violation))
        add_contexts_to_groups(
            groups,
            contexts,
            timestamp=violation.timestamp,
            subject=violation.subject,
            source=f"invariant:{violation.source}",
            line=render_violation(violation),
            is_violation=True,
        )

    for event in telemetry_events:
        base_contexts = report_contexts_by_subject.get(event.handle, empty_contexts())
        contexts = merge_contexts(base_contexts, contexts_from_telemetry(event))
        add_contexts_to_groups(
            groups,
            contexts,
            timestamp=event.timestamp,
            subject=event.handle,
            source="telemetry",
            line=f"{event.event_name} {event.message}".strip(),
            is_violation=False,
        )

    for timestamp, line in timeline:
        if " [telemetry] " in line:
            continue
        subject = subject_from_timeline_line(line)
        base_contexts = report_contexts_by_subject.get(subject, empty_contexts())
        contexts = merge_contexts(base_contexts, contexts_from_text(line))
        add_contexts_to_groups(
            groups,
            contexts,
            timestamp=timestamp,
            subject=subject,
            source="timeline",
            line=line,
            is_violation=False,
        )

    return sorted(
        groups.values(),
        key=lambda group: (
            GROUP_DIMENSION_ORDER.index(group.dimension),
            -(group.event_count + group.violation_count),
            group.value,
        ),
    )


def diagnostic_group_payload(group: DiagnosticGroup) -> dict[str, object]:
    return {
        "dimension": group.dimension,
        "value": group.value,
        "eventCount": group.event_count,
        "violationCount": group.violation_count,
        "subjects": sorted(group.subjects),
        "sources": sorted(group.sources),
        "firstSeen": group.first_seen.isoformat() if group.first_seen else None,
        "lastSeen": group.last_seen.isoformat() if group.last_seen else None,
        "samples": group.samples,
    }


def connection_timing_payload(attempt: ConnectionTimingAttempt) -> dict[str, object]:
    def iso(value: datetime | None) -> str | None:
        return value.isoformat() if value else None

    return {
        "channelId": attempt.channel_id,
        "requestId": attempt.request_id,
        "subjects": sorted(attempt.subjects),
        "publishedJoinAcceptedAt": iso(attempt.published_join_accepted_at),
        "receivedJoinAcceptedAt": iso(attempt.received_join_accepted_at),
        "firstMediaPrewarmAt": iso(attempt.first_media_prewarm_at),
        "lastMediaReadyAt": iso(attempt.last_media_ready_at),
        "firstPTTJoinedAt": iso(attempt.first_ptt_joined_at),
        "lastPTTJoinedAt": iso(attempt.last_ptt_joined_at),
        "backendReadyProjectionAt": iso(attempt.backend_ready_projection_at),
    }


def duplicate_readiness_payload(duplicate: DuplicateReadinessPublish) -> dict[str, object]:
    return {
        "subject": duplicate.subject,
        "contactId": duplicate.contact_id,
        "channelId": duplicate.channel_id,
        "state": duplicate.state,
        "count": duplicate.count,
        "firstSeen": duplicate.first_seen.isoformat(),
        "lastSeen": duplicate.last_seen.isoformat(),
        "spanMs": int((duplicate.last_seen - duplicate.first_seen).total_seconds() * 1000),
        "reasons": sorted(duplicate.reasons),
    }


def render_diagnostic_groups(groups: list[DiagnosticGroup], *, limit_per_dimension: int = 12) -> list[str]:
    if not groups:
        return ["- none"]

    lines: list[str] = []
    for dimension in GROUP_DIMENSION_ORDER:
        dimension_groups = [group for group in groups if group.dimension == dimension]
        if not dimension_groups:
            continue
        lines.append(f"{dimension}:")
        for group in dimension_groups[:limit_per_dimension]:
            subjects = ",".join(sorted(group.subjects)) or "none"
            sources = ",".join(sorted(group.sources)) or "none"
            first_seen = group.first_seen.isoformat() if group.first_seen else "unknown"
            last_seen = group.last_seen.isoformat() if group.last_seen else "unknown"
            lines.append(
                f"- {group.value} events={group.event_count} violations={group.violation_count} "
                f"subjects={subjects} sources={sources} first={first_seen} last={last_seen}"
            )
        remaining = len(dimension_groups) - limit_per_dimension
        if remaining > 0:
            lines.append(f"- ... {remaining} more {dimension} group(s)")
    return lines if lines else ["- none"]


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


def parse_key_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for match in KEY_VALUE_RE.finditer(text):
        value = match.group("value")
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        values[match.group("key")] = value
    return values


def connection_timing_attempts(
    timeline: Iterable[tuple[datetime, str]],
) -> list[ConnectionTimingAttempt]:
    attempts: dict[tuple[str, str], ConnectionTimingAttempt] = {}
    latest_by_channel: dict[str, ConnectionTimingAttempt] = {}

    def attempt_for(channel_id: str, request_id: str) -> ConnectionTimingAttempt:
        key = (channel_id, request_id)
        attempt = attempts.get(key)
        if attempt is None:
            attempt = ConnectionTimingAttempt(channel_id=channel_id, request_id=request_id)
            attempts[key] = attempt
        latest_by_channel[channel_id] = attempt
        return attempt

    for timestamp, line in timeline:
        values = parse_key_values(line)
        subject = subject_from_timeline_line(line)
        channel_id = values.get("channelId") or values.get("channelID") or values.get("channel_id")

        if "Published join accepted control signal" in line:
            request_id = values.get("inviteId") or values.get("requestId")
            if channel_id and request_id:
                attempt = attempt_for(channel_id, request_id)
                attempt.subjects.add(subject)
                attempt.published_join_accepted_at = attempt.published_join_accepted_at or timestamp
            continue

        if "Join accepted control signal received" in line:
            request_id = values.get("requestId") or values.get("inviteId")
            if channel_id and request_id:
                attempt = attempt_for(channel_id, request_id)
                attempt.subjects.add(subject)
                attempt.received_join_accepted_at = attempt.received_join_accepted_at or timestamp
            continue

        if not channel_id:
            continue
        attempt = latest_by_channel.get(channel_id)
        if attempt is None:
            continue
        attempt.subjects.add(subject)

        if "Prewarming interactive audio for joined session" in line:
            if attempt.first_media_prewarm_at is None or timestamp < attempt.first_media_prewarm_at:
                attempt.first_media_prewarm_at = timestamp
        elif "Media session start await completed" in line:
            if attempt.last_media_ready_at is None or timestamp > attempt.last_media_ready_at:
                attempt.last_media_ready_at = timestamp
        elif "Joined channel" in line:
            if attempt.first_ptt_joined_at is None or timestamp < attempt.first_ptt_joined_at:
                attempt.first_ptt_joined_at = timestamp
            if attempt.last_ptt_joined_at is None or timestamp > attempt.last_ptt_joined_at:
                attempt.last_ptt_joined_at = timestamp
        elif "Applied accepted backend join projection" in line and "status=ready" in line:
            attempt.backend_ready_projection_at = attempt.backend_ready_projection_at or timestamp

    return sorted(
        attempts.values(),
        key=lambda attempt: attempt.published_join_accepted_at
        or attempt.received_join_accepted_at
        or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )


def render_connection_timing_attempts(
    attempts: Iterable[ConnectionTimingAttempt],
    *,
    limit: int = 5,
) -> list[str]:
    rendered: list[str] = []
    for attempt in list(attempts)[:limit]:
        anchors = [
            attempt.published_join_accepted_at,
            attempt.received_join_accepted_at,
            attempt.first_media_prewarm_at,
            attempt.last_media_ready_at,
            attempt.first_ptt_joined_at,
            attempt.last_ptt_joined_at,
            attempt.backend_ready_projection_at,
        ]
        if not any(anchors):
            continue
        start = next(anchor for anchor in anchors if anchor is not None)

        def ms_since(value: datetime | None) -> str:
            if value is None:
                return "missing"
            return f"+{int((value - start).total_seconds() * 1000)}ms"

        subjects = ",".join(sorted(attempt.subjects)) or "unknown"
        rendered.append(
            f"- channel={attempt.channel_id} request={attempt.request_id} subjects={subjects} "
            f"published={ms_since(attempt.published_join_accepted_at)} "
            f"received={ms_since(attempt.received_join_accepted_at)} "
            f"firstMediaPrewarm={ms_since(attempt.first_media_prewarm_at)} "
            f"lastMediaReady={ms_since(attempt.last_media_ready_at)} "
            f"firstPTTJoined={ms_since(attempt.first_ptt_joined_at)} "
            f"lastPTTJoined={ms_since(attempt.last_ptt_joined_at)} "
            f"backendReadyProjection={ms_since(attempt.backend_ready_projection_at)}"
        )
    return rendered or ["- none"]


def duplicate_readiness_publishes(
    timeline: Iterable[tuple[datetime, str]],
    *,
    window_ms: int = 1000,
) -> list[DuplicateReadinessPublish]:
    buckets: dict[tuple[str, str, str, str], list[tuple[datetime, str]]] = {}
    for timestamp, line in timeline:
        if "Published receiver audio readiness" not in line:
            continue
        values = parse_key_values(line)
        subject = subject_from_timeline_line(line)
        contact_id = values.get("contactId") or values.get("contactID") or "unknown"
        channel_id = values.get("channelId") or values.get("channelID") or "unknown"
        state = values.get("state") or "unknown"
        reason = values.get("reason") or "unknown"
        buckets.setdefault((subject, contact_id, channel_id, state), []).append((timestamp, reason))

    duplicates: list[DuplicateReadinessPublish] = []
    for (subject, contact_id, channel_id, state), events in buckets.items():
        events.sort(key=lambda item: item[0])
        cluster: list[tuple[datetime, str]] = []
        for event in events:
            if not cluster:
                cluster = [event]
                continue
            if int((event[0] - cluster[-1][0]).total_seconds() * 1000) <= window_ms:
                cluster.append(event)
            else:
                if len(cluster) > 1:
                    duplicates.append(
                        DuplicateReadinessPublish(
                            subject=subject,
                            contact_id=contact_id,
                            channel_id=channel_id,
                            state=state,
                            count=len(cluster),
                            first_seen=cluster[0][0],
                            last_seen=cluster[-1][0],
                            reasons={reason for _, reason in cluster},
                        )
                    )
                cluster = [event]
        if len(cluster) > 1:
            duplicates.append(
                DuplicateReadinessPublish(
                    subject=subject,
                    contact_id=contact_id,
                    channel_id=channel_id,
                    state=state,
                    count=len(cluster),
                    first_seen=cluster[0][0],
                    last_seen=cluster[-1][0],
                    reasons={reason for _, reason in cluster},
                )
            )

    return sorted(duplicates, key=lambda duplicate: duplicate.last_seen, reverse=True)


def render_duplicate_readiness_publishes(
    duplicates: Iterable[DuplicateReadinessPublish],
    *,
    limit: int = 8,
) -> list[str]:
    lines: list[str] = []
    for duplicate in list(duplicates)[:limit]:
        span_ms = int((duplicate.last_seen - duplicate.first_seen).total_seconds() * 1000)
        reasons = ",".join(sorted(duplicate.reasons))
        lines.append(
            f"- subject={duplicate.subject} contactId={duplicate.contact_id} "
            f"channelId={duplicate.channel_id} state={duplicate.state} "
            f"count={duplicate.count} spanMs={span_ms} reasons={reasons}"
        )
    return lines or ["- none"]


def build_violation(
    *,
    subject: str,
    invariant_id: str,
    scope: str,
    message: str,
    source: str = "derived",
    timestamp: datetime | None = None,
    metadata: dict[str, str] | None = None,
) -> InvariantViolation:
    return InvariantViolation(
        subject=subject,
        invariant_id=invariant_id,
        scope=scope,
        message=message,
        source=source,
        timestamp=timestamp,
        metadata=metadata or {},
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
    backend_active_transmitter_user_id = snapshot.get("backendActiveTransmitterUserId", "none")
    backend_active_transmit_id = snapshot.get("backendActiveTransmitId", "none")
    backend_active_transmit_expires_at = snapshot.get("backendActiveTransmitExpiresAt", "none")
    backend_server_timestamp = snapshot.get("backendServerTimestamp", "none")
    remote_wake_capability_kind = snapshot.get("remoteWakeCapabilityKind", "unavailable")
    phase_detail = snapshot.get("selectedPeerPhaseDetail", "none")
    pending_action = snapshot.get("pendingAction", "none")
    ui_call_screen_visible = snapshot_bool(snapshot, "uiCallScreenVisible")
    ui_primary_action_kind = snapshot.get("uiPrimaryActionKind", "none")
    ui_selected_peer_phase = snapshot.get("uiSelectedPeerPhase", phase)

    if ui_call_screen_visible and ui_selected_peer_phase == "idle":
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="ui.call_screen_visible_for_idle_peer",
                scope="local",
                message=(
                    "call screen is visible while selected peer is idle "
                    f"uiCallScreenContact={snapshot.get('uiCallScreenContact', 'none')} "
                    f"uiPrimaryActionKind={ui_primary_action_kind}"
                ),
                metadata={
                    "uiCallScreenVisible": str(ui_call_screen_visible),
                    "uiCallScreenContact": snapshot.get("uiCallScreenContact", "none"),
                    "uiCallScreenRequestedExpanded": snapshot.get("uiCallScreenRequestedExpanded", "none"),
                    "uiCallScreenMinimized": snapshot.get("uiCallScreenMinimized", "none"),
                    "uiSelectedPeerPhase": ui_selected_peer_phase,
                    "selectedPeerPhase": phase,
                },
            )
        )

    if (
        ui_call_screen_visible
        and ui_primary_action_kind == "holdToTalk"
        and ui_selected_peer_phase in {"idle", "requested", "incomingRequest"}
    ):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="ui.call_screen_talk_action_for_non_live_peer",
                scope="local",
                message=(
                    "call screen exposes Hold To Talk for non-live selected peer phase "
                    f"uiSelectedPeerPhase={ui_selected_peer_phase}"
                ),
                metadata={
                    "uiCallScreenVisible": str(ui_call_screen_visible),
                    "uiCallScreenContact": snapshot.get("uiCallScreenContact", "none"),
                    "uiPrimaryActionKind": ui_primary_action_kind,
                    "uiPrimaryActionLabel": snapshot.get("uiPrimaryActionLabel", "none"),
                    "uiPrimaryActionEnabled": snapshot.get("uiPrimaryActionEnabled", "none"),
                    "uiSelectedPeerPhase": ui_selected_peer_phase,
                    "selectedPeerPhase": phase,
                },
            )
        )

    if (
        phase == "waitingForPeer"
        and "disconnecting" in phase_detail
        and "reconciledTeardown(" in pending_action
        and is_joined is False
        and system_session == "none"
        and backend_self_joined is False
        and backend_peer_joined is False
    ):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.reconciled_teardown_without_local_session",
                scope="local",
                message=(
                    "selected peer is disconnecting for reconciled teardown after local and "
                    f"backend sessions are already absent pendingAction={pending_action} "
                    f"backendChannelStatus={backend_channel_status}"
                ),
            )
        )

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

    if snapshot_has_stale_peer_ready_membership(snapshot, phase):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.stale_membership_peer_ready_without_session",
                scope="backend",
                message=(
                    "backend retained durable channel membership while selectedPeerPhase=peerReady "
                    "without a local session"
                ),
            )
        )

    if snapshot_has_stale_backend_membership_without_local_session(snapshot):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.stale_backend_membership_without_local_session",
                scope="backend",
                message=(
                    "backend retained inactive durable channel membership without local "
                    "session evidence"
                ),
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

    if phase == "receiving" and (not is_joined or system_session == "none"):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.receiving_without_joined_session",
                scope="local",
                message=(
                    "selectedPeerPhase=receiving without joined local session evidence "
                    f"isJoined={is_joined} systemSession={system_session} "
                    f"backendChannelStatus={backend_channel_status} "
                    f"backendReadiness={backend_readiness}"
                ),
                metadata={
                    "selectedPeerPhase": phase,
                    "isJoined": str(is_joined),
                    "systemSession": system_session,
                    "backendChannelStatus": backend_channel_status,
                    "backendReadiness": backend_readiness,
                    "remoteWakeCapabilityKind": remote_wake_capability_kind,
                },
            )
        )

    if phase == "transmitting" and not is_joined:
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="selected.live_projection_after_membership_exit",
                scope="local",
                message=(
                    "selectedPeerPhase=transmitting after local membership exit "
                    f"isJoined={is_joined} systemSession={system_session} "
                    f"backendChannelStatus={backend_channel_status} "
                    f"backendReadiness={backend_readiness}"
                ),
                metadata={
                    "selectedPeerPhase": phase,
                    "isJoined": str(is_joined),
                    "systemSession": system_session,
                    "backendChannelStatus": backend_channel_status,
                    "backendReadiness": backend_readiness,
                },
            )
        )

    lease_expiration = parse_backend_instant(backend_active_transmit_expires_at)
    observed_at = parse_timestamp(report.uploaded_at) or datetime.now(timezone.utc)
    if phase in {"transmitting", "receiving"} and lease_expiration is not None:
        expired_by_ms = int((observed_at - lease_expiration).total_seconds() * 1000)
        if expired_by_ms > 5000:
            violations.append(
                build_violation(
                    subject=report.handle,
                    invariant_id="transmit.live_projection_after_lease_expiry",
                    scope="convergence",
                    message=(
                        "selectedPeerPhase remained live after backend transmit lease expiry "
                        f"selectedPeerPhase={phase} backendChannelStatus={backend_channel_status} "
                        f"backendReadiness={backend_readiness} expiredByMs={expired_by_ms}"
                    ),
                    metadata={
                        "selectedPeerPhase": phase,
                        "backendChannelStatus": backend_channel_status,
                        "backendReadiness": backend_readiness,
                        "backendActiveTransmitterUserId": backend_active_transmitter_user_id,
                        "backendActiveTransmitId": backend_active_transmit_id,
                        "backendActiveTransmitExpiresAt": backend_active_transmit_expires_at,
                        "backendServerTimestamp": backend_server_timestamp,
                        "expiredByMs": str(expired_by_ms),
                        "graceMs": "5000",
                        "transmitPhase": snapshot.get("transmitPhase", "none"),
                        "remoteReceiveActive": snapshot.get("remoteReceiveActive", "none"),
                    },
                )
            )

    backend_has_active_transmit = (
        backend_active_transmit_id != "none"
        or backend_channel_status in {"self-transmitting", "peer-transmitting"}
        or backend_readiness in {"self-transmitting", "peer-transmitting"}
    )
    if (
        backend_has_active_transmit
        and backend_peer_joined is False
        and remote_wake_capability_kind != "wake-capable"
    ):
        violations.append(
            build_violation(
                subject=report.handle,
                invariant_id="channel.active_transmit_without_addressable_peer",
                scope="backend",
                message=(
                    "backend active transmit has no joined or wake-addressable selected peer "
                    f"backendChannelStatus={backend_channel_status} "
                    f"backendReadiness={backend_readiness} "
                    f"backendPeerJoined={backend_peer_joined} "
                    f"remoteWakeCapabilityKind={remote_wake_capability_kind}"
                ),
                metadata={
                    "selectedPeerPhase": phase,
                    "backendChannelStatus": backend_channel_status,
                    "backendReadiness": backend_readiness,
                    "backendPeerJoined": str(backend_peer_joined),
                    "remoteWakeCapabilityKind": remote_wake_capability_kind,
                    "backendActiveTransmitterUserId": backend_active_transmitter_user_id,
                    "backendActiveTransmitId": backend_active_transmit_id,
                },
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


def snapshot_has_stale_peer_ready_membership(snapshot: dict[str, str], phase: str) -> bool:
    return (
        phase == "peerReady"
        and snapshot.get("selectedPeerRelationship", "none") == "none"
        and snapshot.get("pendingAction", "none") == "none"
        and snapshot_bool(snapshot, "isJoined") is False
        and snapshot.get("systemSession", "none") == "none"
        and snapshot.get("backendReadiness", "none") == "inactive"
        and snapshot_bool(snapshot, "backendSelfJoined") is True
        and snapshot_bool(snapshot, "backendPeerJoined") is True
    )


def snapshot_has_stale_backend_membership_without_local_session(snapshot: dict[str, str]) -> bool:
    return (
        snapshot.get("selectedPeerRelationship", "none") == "none"
        and snapshot.get("pendingAction", "none") == "none"
        and snapshot_bool(snapshot, "isJoined") is False
        and snapshot.get("systemSession", "none") == "none"
        and snapshot.get("backendReadiness", "none") == "inactive"
        and snapshot_bool(snapshot, "backendSelfJoined") is True
        and snapshot_bool(snapshot, "backendPeerJoined") is True
        and snapshot_bool(snapshot, "backendPeerDeviceConnected") is False
    )


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


def violation_identity(violation: InvariantViolation) -> tuple[str, str, str]:
    return (violation.subject, violation.invariant_id, violation.scope)


def analyze_reports(
    reports: list[Report],
    *,
    include_recorded_violations: bool = True,
) -> list[InvariantViolation]:
    violations: list[InvariantViolation] = []
    for report in reports:
        if include_recorded_violations:
            violations.extend(report.invariant_violations)
            violations.extend(report.backend_invariant_violations)
        violations.extend(analyze_report(report))

    if len(reports) == 2:
        left, right = reports
        left_phase = left.snapshot.get("selectedPeerPhase", "none")
        right_phase = right.snapshot.get("selectedPeerPhase", "none")
        live_session_phases = {"waitingForPeer", "wakeReady", "ready", "startingTransmit", "transmitting", "receiving"}
        connectable_or_joining_phases = {"peerReady", "waitingForPeer"}
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

        def request_relationship(snapshot: dict[str, str]) -> str:
            relationship = snapshot.get("selectedPeerRelationship", "none")
            if relationship != "none":
                return relationship
            return snapshot.get("backendRequestRelationship", "none")

        def has_outgoing_request(snapshot: dict[str, str]) -> bool:
            relationship = request_relationship(snapshot)
            return relationship.startswith("outgoingRequest(") or relationship.startswith("outgoing(")

        def has_incoming_request(snapshot: dict[str, str]) -> bool:
            relationship = request_relationship(snapshot)
            return relationship.startswith("incomingRequest(") or relationship.startswith("incoming(")

        def report_observed_at(report: Report) -> datetime | None:
            return parse_timestamp(report.uploaded_at) or parse_backend_instant(
                report.snapshot.get("backendServerTimestamp", "none")
            )

        def append_pending_request_receiver_gap(requester: Report, receiver: Report) -> None:
            requester_observed_at = report_observed_at(requester)
            receiver_observed_at = report_observed_at(receiver)
            age_delta_ms = None
            if requester_observed_at is not None and receiver_observed_at is not None:
                age_delta_ms = int((requester_observed_at - receiver_observed_at).total_seconds() * 1000)
                if age_delta_ms < 0:
                    age_delta_ms = 0
            if age_delta_ms is not None and age_delta_ms < 5000:
                return
            violations.append(
                build_violation(
                    subject="pair",
                    invariant_id="pair.pending_request_receiver_not_observed",
                    scope="pair",
                    message=(
                        "one device observes a pending outgoing request while the peer's latest diagnostics "
                        "does not observe the matching incoming request "
                        f"requester={requester.handle}:{requester.snapshot.get('selectedPeerPhase', 'none')} "
                        f"receiver={receiver.handle}:{receiver.snapshot.get('selectedPeerPhase', 'none')} "
                        f"requesterObservedAt={requester.uploaded_at} receiverObservedAt={receiver.uploaded_at} "
                        f"ageDeltaMs={age_delta_ms if age_delta_ms is not None else 'unknown'}"
                    ),
                    metadata={
                        "requester": requester.handle,
                        "receiver": receiver.handle,
                        "requesterRelationship": request_relationship(requester.snapshot),
                        "receiverRelationship": request_relationship(receiver.snapshot),
                        "requesterObservedAt": requester.uploaded_at,
                        "receiverObservedAt": receiver.uploaded_at,
                        "ageDeltaMs": str(age_delta_ms if age_delta_ms is not None else "unknown"),
                    },
                )
            )

        if snapshot_has_stale_peer_ready_membership(
            left.snapshot, left_phase
        ) and snapshot_has_stale_peer_ready_membership(right.snapshot, right_phase):
            violations.append(
                build_violation(
                    subject="pair",
                    invariant_id="pair.symmetric_peer_ready_without_session",
                    scope="pair",
                    message=(
                        "both devices project peerReady from durable backend membership while neither has a local session "
                        f"left={left.handle}:{left_phase} right={right.handle}:{right_phase}"
                    ),
                )
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

        if has_outgoing_request(left.snapshot) and not has_incoming_request(right.snapshot):
            append_pending_request_receiver_gap(left, right)

        if has_outgoing_request(right.snapshot) and not has_incoming_request(left.snapshot):
            append_pending_request_receiver_gap(right, left)

        def snapshot_lacks_session_context(snapshot: dict[str, str]) -> bool:
            return (
                snapshot.get("selectedContact", "none") == "none"
                and snapshot.get("systemSession", "none") == "none"
                and snapshot.get("backendChannelStatus", "none") == "none"
                and snapshot_bool(snapshot, "isJoined") is False
            )

        def snapshot_has_connectable_or_joining_session(snapshot: dict[str, str], phase: str) -> bool:
            if phase not in connectable_or_joining_phases:
                return False

            backend_channel_status = snapshot.get("backendChannelStatus", "none")
            backend_readiness = snapshot.get("backendReadiness", "none")
            system_session = snapshot.get("systemSession", "none")

            return (
                backend_channel_status in {"waiting-for-peer", "ready", "transmitting", "receiving"}
                or backend_readiness in {"waiting-for-self", "waiting-for-peer", "ready"}
                or system_session.startswith("active(")
                or snapshot_bool(snapshot, "isJoined") is True
                or snapshot_bool(snapshot, "backendSelfJoined") is True
                or snapshot_bool(snapshot, "backendPeerJoined") is True
            )

        def snapshot_lacks_equivalent_connectable_projection(
            snapshot: dict[str, str], phase: str
        ) -> bool:
            if snapshot_lacks_session_context(snapshot):
                return True

            return (
                phase in {"idle", "requested", "incomingRequest"}
                and not snapshot_has_connectable_or_joining_session(snapshot, phase)
            )

        if snapshot_has_connectable_or_joining_session(
            left.snapshot, left_phase
        ) and snapshot_lacks_equivalent_connectable_projection(right.snapshot, right_phase):
            violations.append(
                build_violation(
                    subject="pair",
                    invariant_id="pair.one_sided_connectable_session",
                    scope="pair",
                    message=(
                        "one device advanced into a connectable or joining session while the peer has no local/backend session context "
                        f"left={left.handle}:{left_phase} right={right.handle}:{right_phase}"
                    ),
                )
            )

        if snapshot_has_connectable_or_joining_session(
            right.snapshot, right_phase
        ) and snapshot_lacks_equivalent_connectable_projection(left.snapshot, left_phase):
            violations.append(
                build_violation(
                    subject="pair",
                    invariant_id="pair.one_sided_connectable_session",
                    scope="pair",
                    message=(
                        "one device advanced into a connectable or joining session while the peer has no local/backend session context "
                        f"left={left.handle}:{left_phase} right={right.handle}:{right_phase}"
                    ),
                )
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


def classify_violations(
    reports: list[Report],
    telemetry_reports: list[Report],
    telemetry_events: list[TelemetryEvent],
) -> tuple[list[InvariantViolation], list[InvariantViolation], list[InvariantViolation]]:
    correlation_reports = reports + telemetry_reports
    current_violations = dedupe_violations(analyze_reports(correlation_reports))
    current_violation_keys = {violation_identity(violation) for violation in current_violations}

    violations = list(current_violations)
    violations.extend(telemetry_invariant_violations(telemetry_events))
    violations = dedupe_violations(violations)

    historical_violations = [
        violation
        for violation in violations
        if violation_identity(violation) not in current_violation_keys
    ]

    return violations, current_violations, historical_violations


def strict_merge_should_fail(
    current_violations: list[InvariantViolation],
    historical_violations: list[InvariantViolation],
) -> bool:
    return bool(current_violations or historical_violations)


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
        "metadata": violation.metadata,
    }


def report_payload(report: Report) -> dict[str, object]:
    return {
        "handle": report.handle,
        "deviceId": report.device_id,
        "appVersion": report.app_version,
        "scenarioName": report.scenario_name,
        "scenarioRunId": report.scenario_run_id,
        "uploadedAt": report.uploaded_at,
        "snapshot": report.snapshot,
        "explicitInvariantViolations": [violation_payload(violation) for violation in report.invariant_violations],
        "backendInvariantViolations": [violation_payload(violation) for violation in report.backend_invariant_violations],
    }


def warning_payload(warning: SourceWarning) -> dict[str, str]:
    return {
        "subject": warning.subject,
        "source": warning.source,
        "message": warning.message,
    }


def telemetry_payload(event: TelemetryEvent) -> dict[str, object]:
    parsed_metadata: object = None
    if event.metadata_text:
        try:
            parsed_metadata = json.loads(event.metadata_text)
        except json.JSONDecodeError:
            parsed_metadata = event.metadata_text
    return {
        "timestamp": event.timestamp.isoformat(),
        "handle": event.handle,
        "deviceId": event.device_id,
        "sessionId": event.session_id,
        "eventName": event.event_name,
        "source": event.source,
        "severity": event.severity,
        "phase": event.phase,
        "reason": event.reason,
        "message": event.message,
        "channelId": event.channel_id,
        "peerHandle": event.peer_handle,
        "invariantId": event.invariant_id,
        "metadataText": event.metadata_text,
        "metadata": parsed_metadata,
    }


def main() -> int:
    args = parse_args()
    requested_devices = [parse_device_mapping(raw_value) for raw_value in args.device]
    handles = [normalize_handle(handle) for handle in args.handles]

    if not handles and not requested_devices:
        raise RuntimeError("expected at least one handle or --device mapping")

    reports: list[Report] = []
    source_warnings: list[SourceWarning] = []
    requested_subjects: list[tuple[str, str | None]] = [(handle, None) for handle in handles]
    requested_subjects.extend(requested_devices)
    for handle, device_id in requested_subjects:
        subject = handle if device_id is None else f"{handle}/{device_id}"
        try:
            reports.append(
                fetch_latest_report(
                    args.base_url,
                    handle,
                    args.insecure,
                    timeout=args.backend_timeout,
                    device_id=device_id,
                )
            )
        except RuntimeError as exc:
            if missing_latest_diagnostics_error(exc):
                source_warnings.append(
                    SourceWarning(
                        subject=subject,
                        source="backend-latest-diagnostics",
                        message=(
                            "latest diagnostics snapshot not found or unavailable; using telemetry-only timeline "
                            "for this subject if Cloudflare telemetry is available"
                        ),
                    )
                )
                continue
            print(str(exc), file=sys.stderr)
            return 1

    telemetry_events: list[TelemetryEvent] = []
    if args.include_telemetry:
        # Exact device mappings should not implicitly widen telemetry back out to the
        # full handle history. That breaks strict simulator-hosted proofs because old
        # hosted runs for the same handles get merged into the current device-scoped run.
        telemetry_handles = list(handles)
        if not telemetry_handles and not requested_devices:
            telemetry_handles = [report.handle for report in reports]

        telemetry_device_ids = [device_id for _, device_id in requested_devices if device_id]
        if not telemetry_device_ids:
            telemetry_device_ids = [report.device_id for report in reports]

        telemetry_events = fetch_telemetry_events(
            telemetry_handles,
            telemetry_device_ids,
            hours=args.telemetry_hours,
            limit=args.telemetry_limit,
            dataset=args.telemetry_dataset,
            insecure=args.insecure,
            include_heartbeats=args.include_heartbeats,
        )

    telemetry_reports = telemetry_snapshot_reports(telemetry_events, reports)
    violations, current_violations, historical_violations = classify_violations(
        reports,
        telemetry_reports,
        telemetry_events,
    )

    timeline = merged_events(
        reports,
        telemetry_events,
        full_metadata=args.full_metadata,
    )
    connection_timings = connection_timing_attempts(timeline)
    readiness_duplicates = duplicate_readiness_publishes(timeline)
    diagnostic_groups = build_diagnostic_groups(
        reports,
        violations,
        telemetry_events,
        timeline,
    )

    if args.json:
        payload = {
            "reports": [report_payload(report) for report in reports],
            "telemetrySnapshotReports": [report_payload(report) for report in telemetry_reports],
            "sourceWarnings": [warning_payload(warning) for warning in source_warnings],
            "violations": [violation_payload(violation) for violation in violations],
            "currentViolations": [violation_payload(violation) for violation in current_violations],
            "historicalViolations": [violation_payload(violation) for violation in historical_violations],
            "telemetryEventCount": len(telemetry_events),
            "telemetryEvents": [telemetry_payload(event) for event in telemetry_events],
            "connectionTimings": [
                connection_timing_payload(attempt) for attempt in connection_timings
            ],
            "duplicateReadinessPublishes": [
                duplicate_readiness_payload(duplicate) for duplicate in readiness_duplicates
            ],
            "diagnosticGroups": [diagnostic_group_payload(group) for group in diagnostic_groups],
            "timeline": [
                {
                    "timestamp": timestamp.isoformat(),
                    "line": line,
                }
                for timestamp, line in timeline
            ],
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print("LATEST SNAPSHOTS")
        if reports:
            for report in reports:
                print(render_snapshot(report))
        else:
            print("- none")

        if telemetry_reports:
            print("\nTELEMETRY SNAPSHOT FACTS")
            for report in telemetry_reports:
                print(render_snapshot(report))

        if source_warnings:
            print("\nDIAGNOSTICS SOURCES")
            for warning in source_warnings:
                print(f"- [{warning.subject}] {warning.source}: {warning.message}")
            if args.include_telemetry:
                print(f"- telemetry: merged {len(telemetry_events)} Cloudflare events")
        elif args.include_telemetry:
            print("\nDIAGNOSTICS SOURCES")
            print(f"- telemetry: merged {len(telemetry_events)} Cloudflare events")

        print("\nCURRENT INVARIANT VIOLATIONS")
        if current_violations:
            for violation in current_violations:
                print(f"- {render_violation(violation)}")
        else:
            print("- none")

        print("\nHISTORICAL INVARIANT VIOLATIONS")
        if historical_violations:
            for violation in historical_violations:
                print(f"- {render_violation(violation)}")
        else:
            print("- none")

        print("\nCONNECTION TIMING SUMMARY")
        for line in render_connection_timing_attempts(connection_timings):
            print(line)

        print("\nDUPLICATE READINESS PUBLISHES")
        for line in render_duplicate_readiness_publishes(readiness_duplicates):
            print(line)

        print("\nDIAGNOSTIC GROUPS")
        for line in render_diagnostic_groups(diagnostic_groups):
            print(line)

        print("\nMERGED TIMELINE")
        for timestamp, line in timeline:
            print(f"{timestamp.isoformat()} {line}")

    if args.fail_on_violations and strict_merge_should_fail(current_violations, historical_violations):
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
