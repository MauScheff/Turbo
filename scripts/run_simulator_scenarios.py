#!/usr/bin/env python3

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path


TRANSIENT_FAILURE_MARKERS = (
    "Early unexpected exit",
    "operation never finished bootstrapping",
    "Restarting after unexpected exit, crash, or test timeout",
    "lost connection to test process",
    "Failed to background test runner",
    "test crashed with signal",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Turbo simulator scenarios with locking and transient retries.")
    parser.add_argument("--project", default="Turbo.xcodeproj")
    parser.add_argument("--scheme", default="BeepBeep")
    parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17")
    parser.add_argument("--derived-data", default="/tmp/turbo-dd-simulator-scenario")
    parser.add_argument("--scenario", default="")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--handle-a", default="@avery")
    parser.add_argument("--handle-b", default="@blake")
    parser.add_argument("--device-id-a", default="sim-scenario-avery")
    parser.add_argument("--device-id-b", default="sim-scenario-blake")
    parser.add_argument("--lock-file", default=".scenario-test.lock")
    parser.add_argument("--runtime-config", default=".scenario-runtime-config.json")
    parser.add_argument("--max-attempts", type=int, default=2)
    parser.add_argument("--retry-delay-seconds", type=float, default=3.0)
    return parser.parse_args()


def write_runtime_config(path: Path, args: argparse.Namespace) -> None:
    payload = {
        "enabledUntilEpochSeconds": time.time() + 600,
        "filter": args.scenario,
        "baseURL": args.base_url,
        "handleA": args.handle_a,
        "handleB": args.handle_b,
        "deviceIDA": args.device_id_a,
        "deviceIDB": args.device_id_b,
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


def run_command(command: list[str]) -> tuple[int, str]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    collected: list[str] = []
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        collected.append(line)
    return process.wait(), "".join(collected)


def is_transient_failure(output: str, exit_code: int) -> bool:
    if exit_code == 0:
        return False
    normalized = output.lower()
    return any(marker.lower() in normalized for marker in TRANSIENT_FAILURE_MARKERS)


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    lock_path = repo_root / args.lock_file
    runtime_config_path = repo_root / args.runtime_config

    with lock_path.open("w", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        write_runtime_config(runtime_config_path, args)
        try:
            command = [
                "xcodebuild",
                "-project", args.project,
                "-scheme", args.scheme,
                "-destination", args.destination,
                "-only-testing:TurboTests/SimulatorScenarioTests",
                "-skip-testing:TurboUITests",
                "-parallel-testing-enabled", "NO",
                "-maximum-concurrent-test-simulator-destinations", "1",
                "-maximum-parallel-testing-workers", "1",
                "-derivedDataPath", args.derived_data,
                "test",
                "CODE_SIGNING_ALLOWED=NO",
            ]

            last_exit_code = 1
            for attempt in range(1, args.max_attempts + 1):
                if attempt > 1:
                    print(f"Retrying simulator scenario run (attempt {attempt}/{args.max_attempts}) after transient failure...", flush=True)
                    time.sleep(args.retry_delay_seconds)
                last_exit_code, output = run_command(command)
                if last_exit_code == 0:
                    return 0
                if not is_transient_failure(output, last_exit_code):
                    return last_exit_code
            return last_exit_code
        finally:
            try:
                runtime_config_path.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
