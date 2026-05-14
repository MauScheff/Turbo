#!/usr/bin/env python3

import argparse
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import convert_production_replay
import merged_diagnostics
import reliability_intake
import slo_dashboard


def sample_report(
    *,
    handle: str = "@avery",
    device_id: str = "device-avery",
    snapshot: dict[str, str] | None = None,
    invariant_violations: list[merged_diagnostics.InvariantViolation] | None = None,
) -> merged_diagnostics.Report:
    return merged_diagnostics.Report(
        handle=handle,
        device_id=device_id,
        app_version="1.0",
        scenario_name=None,
        scenario_run_id=None,
        uploaded_at="2026-05-14T10:00:00Z",
        structured_diagnostics=None,
        snapshot=snapshot
        or {
            "selectedPeerPhase": "ready",
            "selectedPeerStatus": "Ready",
            "selectedContact": "@blake",
            "backendSelfJoined": "true",
            "backendPeerJoined": "true",
            "backendPeerDeviceConnected": "true",
            "backendChannelStatus": "ready",
            "backendReadiness": "ready",
            "isJoined": "true",
            "systemSession": "active(contactID: 123, channelUUID: 456)",
        },
        state_timeline=[],
        invariant_violations=invariant_violations or [],
        backend_invariant_violations=[],
        diagnostics=[],
        wake_events=[],
    )


class MergedDiagnosticsClassificationTests(unittest.TestCase):
    def test_current_violations_keep_latest_recorded_invariants(self) -> None:
        recorded_violation = merged_diagnostics.InvariantViolation(
            subject="@avery",
            invariant_id="selected.backend_ready_ui_not_live",
            scope="local",
            message="backend is ready while selected UI is idle",
            source="structured",
            timestamp=datetime(2026, 5, 14, 10, 0, 0, tzinfo=timezone.utc),
        )

        violations, current_violations, historical_violations = merged_diagnostics.classify_violations(
            [sample_report(invariant_violations=[recorded_violation])],
            [],
            [],
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["selected.backend_ready_ui_not_live"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in current_violations],
            ["selected.backend_ready_ui_not_live"],
        )
        self.assertEqual(historical_violations, [])

    def test_historical_violations_capture_telemetry_only_events(self) -> None:
        historical_event = merged_diagnostics.TelemetryEvent(
            timestamp=datetime(2026, 5, 14, 10, 0, 1, tzinfo=timezone.utc),
            handle="@avery",
            device_id="device-avery",
            session_id="session-1",
            event_name="invariant",
            source="ios",
            severity="error",
            phase="requested",
            reason="ui-projection",
            message="selected route flapped between requested and call-visible without a phase change",
            channel_id="channel-1",
            peer_handle="@blake",
            invariant_id="selected.request_call_flap",
            metadata_text="",
        )

        violations, current_violations, historical_violations = merged_diagnostics.classify_violations(
            [sample_report()],
            [],
            [historical_event],
        )

        self.assertEqual(
            [violation.invariant_id for violation in current_violations],
            [],
        )
        self.assertEqual(
            [violation.invariant_id for violation in historical_violations],
            ["selected.request_call_flap"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["selected.request_call_flap"],
        )

    def test_mixed_current_pair_and_historical_local_violations_stay_split(self) -> None:
        left_report = sample_report()
        right_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedPeerPhase": "idle",
                "selectedPeerStatus": "Blake is online",
                "selectedContact": "none",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        historical_event = merged_diagnostics.TelemetryEvent(
            timestamp=datetime(2026, 5, 14, 10, 0, 1, tzinfo=timezone.utc),
            handle="@avery",
            device_id="device-avery",
            session_id="session-1",
            event_name="invariant",
            source="ios",
            severity="error",
            phase="requested",
            reason="ui-projection",
            message="selected route flapped between requested and call-visible without a phase change",
            channel_id="channel-1",
            peer_handle="@blake",
            invariant_id="selected.request_call_flap",
            metadata_text="",
        )

        violations, current_violations, historical_violations = merged_diagnostics.classify_violations(
            [left_report, right_report],
            [],
            [historical_event],
        )

        self.assertEqual(
            [violation.invariant_id for violation in current_violations],
            ["pair.one_sided_ready_session"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in historical_violations],
            ["selected.request_call_flap"],
        )
        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["pair.one_sided_ready_session", "selected.request_call_flap"],
        )

    def test_pair_one_sided_connectable_session_catches_connecting_vs_request_split(self) -> None:
        left_report = sample_report(
            snapshot={
                "selectedPeerPhase": "waitingForPeer",
                "selectedPeerStatus": "Connecting",
                "selectedContact": "@blake",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "waiting-for-peer",
                "backendReadiness": "waiting-for-peer",
                "isJoined": "false",
                "systemSession": "none",
            },
        )
        right_report = sample_report(
            handle="@blake",
            device_id="device-blake",
            snapshot={
                "selectedPeerPhase": "incomingRequest",
                "selectedPeerStatus": "Incoming request",
                "selectedContact": "@avery",
                "selectedPeerRelationship": "incomingRequest(1)",
                "backendSelfJoined": "false",
                "backendPeerJoined": "false",
                "backendPeerDeviceConnected": "false",
                "backendChannelStatus": "none",
                "backendReadiness": "inactive",
                "isJoined": "false",
                "systemSession": "none",
            },
        )

        violations = merged_diagnostics.analyze_reports(
            [left_report, right_report],
            include_recorded_violations=False,
        )

        self.assertEqual(
            [violation.invariant_id for violation in violations],
            ["pair.one_sided_connectable_session"],
        )


class ProductionReplayInvariantIDTests(unittest.TestCase):
    def test_invariant_ids_include_current_and_historical_violation_lists(self) -> None:
        payload = {
            "currentViolations": [
                {"invariantId": "selected.call_visible_peer_online"},
            ],
            "historicalViolations": [
                {"invariantId": "selected.request_call_flap"},
            ],
        }

        self.assertEqual(
            convert_production_replay.invariant_ids_from(payload),
            {"selected.call_visible_peer_online", "selected.request_call_flap"},
        )

    def test_mixed_fixture_preserves_current_and_historical_violation_lists(self) -> None:
        fixture_path = Path(__file__).resolve().parent.parent / "fixtures" / "production_replay" / "merged_diagnostics_mixed.json"
        with fixture_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)

        self.assertEqual(
            [violation["invariantId"] for violation in payload["currentViolations"]],
            ["pair.one_sided_ready_session"],
        )
        self.assertEqual(
            [violation["invariantId"] for violation in payload["historicalViolations"]],
            ["selected.request_call_flap"],
        )
        self.assertEqual(
            convert_production_replay.invariant_ids_from(payload),
            {"pair.one_sided_ready_session", "selected.request_call_flap"},
        )


class DownstreamSplitConsumerTests(unittest.TestCase):
    def test_reliability_intake_split_violations_prefers_split_keys(self) -> None:
        payload = {
            "violations": [{"invariantId": "legacy.flattened"}],
            "currentViolations": [{"invariantId": "pair.one_sided_ready_session"}],
            "historicalViolations": [{"invariantId": "selected.request_call_flap"}],
        }

        current, historical = reliability_intake.split_violations(payload)

        self.assertEqual(
            [violation["invariantId"] for violation in current],
            ["pair.one_sided_ready_session"],
        )
        self.assertEqual(
            [violation["invariantId"] for violation in historical],
            ["selected.request_call_flap"],
        )

    def test_reliability_intake_split_violations_falls_back_to_legacy_list(self) -> None:
        payload = {
            "violations": [{"invariantId": "selected.backend_ready_ui_not_live"}],
        }

        current, historical = reliability_intake.split_violations(payload)

        self.assertEqual(
            [violation["invariantId"] for violation in current],
            ["selected.backend_ready_ui_not_live"],
        )
        self.assertEqual(historical, [])

    def test_slo_dashboard_breaches_only_on_current_violations(self) -> None:
        objective = slo_dashboard.diagnostics_objectives(
            [
                {
                    "_sourcePath": "fixture.json",
                    "currentViolations": [{"invariantId": "pair.one_sided_ready_session"}],
                    "historicalViolations": [{"invariantId": "selected.request_call_flap"}],
                }
            ]
        )[0]

        self.assertEqual(objective.status, "breach")
        self.assertEqual(objective.observed, "1")
        self.assertEqual(objective.details["currentCount"], 1)
        self.assertEqual(objective.details["historicalCount"], 1)
        self.assertEqual(
            objective.details["byInvariantId"],
            {"pair.one_sided_ready_session": 1},
        )
        self.assertEqual(
            objective.details["historicalByInvariantId"],
            {"selected.request_call_flap": 1},
        )

    def test_slo_dashboard_passes_when_only_historical_violations_exist(self) -> None:
        objective = slo_dashboard.diagnostics_objectives(
            [
                {
                    "_sourcePath": "fixture.json",
                    "currentViolations": [],
                    "historicalViolations": [{"invariantId": "selected.request_call_flap"}],
                }
            ]
        )[0]

        self.assertEqual(objective.status, "pass")
        self.assertEqual(objective.observed, "0")
        self.assertEqual(objective.details["currentCount"], 0)
        self.assertEqual(objective.details["historicalCount"], 1)

    def test_reliability_intake_summary_separates_current_and_historical_sections(self) -> None:
        args = argparse.Namespace(
            surface="production",
            incident_id="",
            base_url="https://beepbeep.to",
        )
        payload = {
            "reports": [],
            "telemetrySnapshotReports": [],
            "sourceWarnings": [],
            "violations": [
                {"invariantId": "pair.one_sided_ready_session"},
                {"invariantId": "selected.request_call_flap"},
            ],
            "currentViolations": [
                {
                    "invariantId": "pair.one_sided_ready_session",
                    "scope": "pair",
                    "source": "merged",
                    "subject": "pair",
                    "timestamp": "2026-05-14T10:00:08Z",
                }
            ],
            "historicalViolations": [
                {
                    "invariantId": "selected.request_call_flap",
                    "scope": "local",
                    "source": "ios",
                    "subject": "@mixedavery",
                    "timestamp": "2026-05-14T10:00:04Z",
                }
            ],
            "telemetryEventCount": 0,
            "telemetryEvents": [],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            summary_path = Path(temp_dir) / "summary.md"
            reliability_intake.write_summary(
                summary_path,
                args=args,
                handles=["@mixedavery", "@mixedblake"],
                devices=[],
                output_dir=Path(temp_dir),
                payload=payload,
                text_result=argparse.Namespace(returncode=0),
                json_result=argparse.Namespace(returncode=0),
                json_error="",
                replay_result=None,
                replay_dir=Path(temp_dir) / "replay",
            )
            summary = summary_path.read_text(encoding="utf-8")

        self.assertIn("- current invariant violations: `1`", summary)
        self.assertIn("- historical invariant violations: `1`", summary)
        self.assertIn("## Current Invariant Violations", summary)
        self.assertIn("## Historical Invariant Violations", summary)


if __name__ == "__main__":
    unittest.main()
