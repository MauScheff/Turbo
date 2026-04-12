#!/usr/bin/env python3

from __future__ import annotations

import argparse
import fcntl
import subprocess
import sys
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
    parser.add_argument("--destination", default="platform=iOS Simulator,name=iPhone 17,OS=26.4")
    parser.add_argument("--derived-data", default="/tmp/turbo-dd-targeted-swift-tests")
    parser.add_argument("--lock-file", default=".swift-test-target.lock")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    lock_path = repo_root / args.lock_file

    with lock_path.open("w", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        command = [
            "xcodebuild",
            "-project", args.project,
            "-scheme", args.scheme,
            "-destination", args.destination,
            "-skip-testing:TurboUITests",
            "-parallel-testing-enabled", "NO",
            "-maximum-concurrent-test-simulator-destinations", "1",
            "-maximum-parallel-testing-workers", "1",
            "-derivedDataPath", args.derived_data,
            "test",
            "CODE_SIGNING_ALLOWED=NO",
        ]

        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        seen = {name: False for name in args.names}
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            for name in seen:
                if f"Test {name}()" in line:
                    seen[name] = True

        exit_code = process.wait()
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
