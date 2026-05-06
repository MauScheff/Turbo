#!/usr/bin/env python3

import argparse
import json
import statistics
import subprocess
import sys
import time
import urllib.parse
from dataclasses import asdict, dataclass
from typing import Any


@dataclass
class RequestResult:
    iteration: int
    endpoint: str
    method: str
    url: str
    ok: bool
    httpCode: int
    durationMs: int
    error: str | None
    responsePreview: str


def endpoint_url(base_url: str, path: str) -> str:
    return urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))


def run_request(
    *,
    base_url: str,
    iteration: int,
    endpoint: str,
    method: str,
    path: str,
    timeout_seconds: float,
    handle: str,
    body: dict[str, Any] | None = None,
    insecure: bool = False,
) -> RequestResult:
    url = endpoint_url(base_url, path)
    command = [
        "curl",
        "-sS",
        "--max-time",
        str(timeout_seconds),
        "-w",
        "\n__curl_http_code=%{http_code} __curl_time_total=%{time_total}\n",
        "-X",
        method,
    ]
    if insecure:
        command.append("-k")
    if endpoint == "auth":
        command.extend([
            "-H",
            f"x-turbo-user-handle: {handle}",
            "-H",
            f"Authorization: Bearer {handle}",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            json.dumps(body or {}),
        ])
    started = time.monotonic()
    completed = subprocess.run(command + [url], capture_output=True, text=True)
    elapsed_ms = int((time.monotonic() - started) * 1000)
    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    http_code = 0
    curl_time_ms = elapsed_ms
    response = stdout
    marker = "__curl_http_code="
    if marker in stdout:
        response, metrics = stdout.rsplit("\n", 1)
        parts = dict(
            part.split("=", 1)
            for part in metrics.split()
            if "=" in part
        )
        http_code = int(parts.get("__curl_http_code", "0"))
        try:
            curl_time_ms = int(float(parts.get("__curl_time_total", "0")) * 1000)
        except ValueError:
            curl_time_ms = elapsed_ms
    ok = completed.returncode == 0 and 200 <= http_code < 300
    return RequestResult(
        iteration=iteration,
        endpoint=endpoint,
        method=method,
        url=url,
        ok=ok,
        httpCode=http_code,
        durationMs=curl_time_ms,
        error=None if ok else (stderr or f"curl exited {completed.returncode}"),
        responsePreview=response[:240],
    )


def summarize(results: list[RequestResult]) -> dict[str, Any]:
    by_endpoint: dict[str, list[RequestResult]] = {}
    for result in results:
        by_endpoint.setdefault(result.endpoint, []).append(result)
    summary: dict[str, Any] = {}
    for endpoint, endpoint_results in by_endpoint.items():
        durations = [result.durationMs for result in endpoint_results]
        failures = [result for result in endpoint_results if not result.ok]
        summary[endpoint] = {
            "total": len(endpoint_results),
            "ok": len(endpoint_results) - len(failures),
            "failed": len(failures),
            "failureRate": len(failures) / len(endpoint_results),
            "minMs": min(durations),
            "medianMs": int(statistics.median(durations)),
            "maxMs": max(durations),
        }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe Turbo backend route stability with repeated simple requests.")
    parser.add_argument("--base-url", default="https://beepbeep.to")
    parser.add_argument("--handle", default="@mau")
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--sleep", type=float, default=0.0)
    parser.add_argument("--fail-on-any-error", action="store_true", default=True)
    parser.add_argument("--allow-failures", type=int, default=0)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--insecure", action="store_true")
    args = parser.parse_args()

    results: list[RequestResult] = []
    for iteration in range(1, args.iterations + 1):
        requests = [
            ("health", "GET", "v1/health", None),
            ("config", "GET", "v1/config", None),
            (
                "auth",
                "POST",
                "v1/auth/session",
                {"deviceId": f"stability-probe-{iteration}", "deviceLabel": "backend-stability-probe"},
            ),
        ]
        for endpoint, method, path, body in requests:
            result = run_request(
                base_url=args.base_url,
                iteration=iteration,
                endpoint=endpoint,
                method=method,
                path=path,
                timeout_seconds=args.timeout,
                handle=args.handle,
                body=body,
                insecure=args.insecure,
            )
            results.append(result)
            if not args.json:
                status = "ok" if result.ok else "FAIL"
                print(
                    f"{iteration:02d} {endpoint:6s} {status:4s} "
                    f"http={result.httpCode:03d} timeMs={result.durationMs}"
                    + (f" error={result.error}" if result.error else "")
                )
        if args.sleep > 0 and iteration != args.iterations:
            time.sleep(args.sleep)

    summary = summarize(results)
    failed_count = sum(1 for result in results if not result.ok)
    payload = {
        "baseUrl": args.base_url,
        "handle": args.handle,
        "iterations": args.iterations,
        "timeoutSeconds": args.timeout,
        "failedCount": failed_count,
        "summary": summary,
        "results": [asdict(result) for result in results],
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print("\nsummary")
        print(json.dumps({k: v for k, v in payload.items() if k != "results"}, indent=2, sort_keys=True))
    return 1 if failed_count > args.allow_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
