#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the full Turbo non-UI test bundle and fail if the requested Swift test names do not execute."
    )
    parser.add_argument(
        "--name",
        action="append",
        dest="names",
        required=True,
        help="Exact Swift test function name to require in the output. May be repeated.",
    )
    parser.add_argument("--project", default="Turbo.xcodeproj")
    parser.add_argument("--scheme", default="BeepBeep")
    parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17")
    parser.add_argument("--derived-data", default="/tmp/turbo-dd-targeted-swift-tests")
    parser.add_argument("--lock-file", default="/tmp/turbo-simulator-test.lock")
    return parser.parse_args()


def parse_destination(destination: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for part in destination.split(","):
        key, separator, value = part.partition("=")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


def parse_runtime_version(runtime: str) -> tuple[int, ...]:
    version = runtime.rsplit("iOS-", 1)[-1].replace("-", ".")
    return tuple(int(part) for part in version.split(".") if part.isdigit())


def resolve_simulator_destination(destination: str) -> tuple[str, str | None]:
    fields = parse_destination(destination)
    if fields.get("platform") != "iOS Simulator":
        return destination, None

    if "id" in fields:
        return f"platform=iOS Simulator,id={fields['id']}", fields["id"]

    name = fields.get("name")
    if not name:
        return destination, None

    requested_os = fields.get("OS")
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    payload = json.loads(result.stdout)
    candidates: list[tuple[tuple[int, ...], int, str]] = []
    for runtime, devices in payload.get("devices", {}).items():
        if "iOS-" not in runtime:
            continue
        runtime_version = parse_runtime_version(runtime)
        runtime_text = ".".join(str(part) for part in runtime_version)
        if requested_os and runtime_text != requested_os:
            continue
        for device in devices:
            if not device.get("isAvailable", False):
                continue
            if device.get("name") != name:
                continue
            state_rank = 0 if device.get("state") == "Booted" else 1
            candidates.append((runtime_version, state_rank, device["udid"]))

    if not candidates:
        return destination, None

    runtime_version, _, udid = sorted(
        candidates,
        key=lambda candidate: (-candidate[0][0],) + tuple(-part for part in candidate[0][1:]) + (candidate[1],),
    )[0]
    version_text = ".".join(str(part) for part in runtime_version)
    return f"platform=iOS Simulator,id={udid},OS={version_text}", udid


def run_simctl(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["xcrun", "simctl", *args],
        capture_output=True,
        text=True,
        check=check,
    )


def ensure_simulator_ready(udid: str) -> None:
    boot = run_simctl("boot", udid, check=False)
    if boot.returncode not in (0, 149):
        raise subprocess.CalledProcessError(
            boot.returncode,
            boot.args,
            output=boot.stdout,
            stderr=boot.stderr,
        )
    run_simctl("bootstatus", udid, "-b")
    run_simctl("terminate", udid, "com.rounded.Turbo", check=False)


def recover_simulator(udid: str) -> None:
    print(
        f"swift-test-target: recovering simulator {udid} after launch preflight failure",
        file=sys.stderr,
    )
    run_simctl("shutdown", udid, check=False)
    time.sleep(1.0)
    ensure_simulator_ready(udid)


def build_xcodebuild_command(args: argparse.Namespace, destination: str) -> list[str]:
    return [
        "xcodebuild",
        "-project", args.project,
        "-scheme", args.scheme,
        "-destination", destination,
        "-skip-testing:TurboUITests",
        "-parallel-testing-enabled", "NO",
        "-maximum-concurrent-test-simulator-destinations", "1",
        "-maximum-parallel-testing-workers", "1",
        "-derivedDataPath", args.derived_data,
        "test",
        "CODE_SIGNING_ALLOWED=NO",
    ]


def run_xcodebuild(command: list[str], seen: dict[str, bool]) -> tuple[int, bool]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    saw_launch_preflight_failure = False
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if (
            "Application failed preflight checks" in line
            or "Simulator device failed to launch" in line
        ):
            saw_launch_preflight_failure = True
        for name in seen:
            if f"Test {name}()" in line:
                seen[name] = True

    return process.wait(), saw_launch_preflight_failure


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    else:
        return True


@contextmanager
def acquire_lock(lock_path: Path):
    while True:
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w", encoding="utf-8") as lock_file:
                lock_file.write(f"{os.getpid()}\n")
            break
        except FileExistsError:
            try:
                lock_pid = int(lock_path.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                lock_pid = 0
            if lock_pid == 0:
                lock_path.unlink(missing_ok=True)
                continue
            if lock_pid and not process_exists(lock_pid):
                lock_path.unlink(missing_ok=True)
                continue
            time.sleep(0.2)

    try:
        yield
    finally:
        lock_path.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    lock_path = repo_root / args.lock_file

    with acquire_lock(lock_path):
        destination, simulator_udid = resolve_simulator_destination(args.destination)
        if simulator_udid:
            print(
                f"swift-test-target: preparing simulator {simulator_udid}",
                file=sys.stderr,
            )
            ensure_simulator_ready(simulator_udid)

        command = build_xcodebuild_command(args, destination)
        seen = {name: False for name in args.names}
        exit_code, saw_launch_preflight_failure = run_xcodebuild(command, seen)

        if exit_code != 0 and saw_launch_preflight_failure and simulator_udid:
            recover_simulator(simulator_udid)
            exit_code, _ = run_xcodebuild(command, seen)

        missing = [name for name, was_seen in seen.items() if not was_seen]
        if missing:
            print(
                "Requested Swift tests did not execute: " + ", ".join(missing),
                file=sys.stderr,
            )
            return 1
        return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
