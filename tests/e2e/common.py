#!/usr/bin/env python3
"""
Lingua Canvas - E2E Testing Harness Common Utilities
Provides HTTP client, server lifecycle management, assertions, and reporting.
Zero external dependencies (uses standard library only).
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union

# Colors for terminal output
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"


def find_project_root() -> Path:
    """Locate the monorepo root directory containing app/ and server/."""
    current = Path(__file__).resolve().parent
    for _ in range(5):
        if (current / "app").is_dir() and (current / "server").is_dir():
            return current
        current = current.parent
    return Path("/home/dp/AntigravityProjects/lingua_canvas")


PROJECT_ROOT = find_project_root()
DEFAULT_BASE_URL = os.environ.get("API_BASE_URL", "http://127.0.0.1:8080/api/v1")


class ApiClient:
    """HTTP client for opaque-box REST API verification."""

    def __init__(self, base_url: str = DEFAULT_BASE_URL, timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def request(
        self,
        method: str,
        endpoint: str,
        data: Optional[Union[Dict[str, Any], List[Any], str, bytes]] = None,
        params: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Tuple[int, Any, Dict[str, str]]:
        """
        Execute an HTTP request.
        Returns (status_code, parsed_body_or_raw, response_headers).
        """
        path = endpoint if endpoint.startswith("/") else f"/{endpoint}"
        url = f"{self.base_url}{path}"

        if params:
            query_string = urllib.parse.urlencode(params)
            url = f"{url}?{query_string}"

        req_headers = {
            "User-Agent": "LinguaCanvas-E2ETester/1.0",
        }
        if headers:
            req_headers.update(headers)

        payload_bytes = None
        if data is not None:
            if isinstance(data, (dict, list)):
                payload_bytes = json.dumps(data).encode("utf-8")
                if "Content-Type" not in req_headers:
                    req_headers["Content-Type"] = "application/json"
            elif isinstance(data, str):
                payload_bytes = data.encode("utf-8")
                if "Content-Type" not in req_headers:
                    req_headers["Content-Type"] = "application/json"
            elif isinstance(data, bytes):
                payload_bytes = data

        req = urllib.request.Request(
            url, data=payload_bytes, headers=req_headers, method=method.upper()
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                status_code = response.getcode()
                resp_headers = dict(response.info())
                raw_body = response.read().decode("utf-8", errors="replace")
                try:
                    parsed_body = json.loads(raw_body)
                except json.JSONDecodeError:
                    parsed_body = raw_body
                return status_code, parsed_body, resp_headers
        except urllib.error.HTTPError as e:
            status_code = e.code
            resp_headers = dict(e.headers)
            raw_body = e.read().decode("utf-8", errors="replace")
            try:
                parsed_body = json.loads(raw_body)
            except json.JSONDecodeError:
                parsed_body = raw_body
            return status_code, parsed_body, resp_headers
        except urllib.error.URLError as e:
            raise ConnectionError(f"Failed to connect to {url}: {e.reason}") from e

    def get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Tuple[int, Any, Dict[str, str]]:
        return self.request("GET", endpoint, params=params, headers=headers)

    def post(
        self,
        endpoint: str,
        data: Optional[Union[Dict[str, Any], List[Any], str, bytes]] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Tuple[int, Any, Dict[str, str]]:
        return self.request("POST", endpoint, data=data, headers=headers)


class ServerManager:
    """Manages the background Axum server lifecycle during test runs."""

    def __init__(self, base_url: str = DEFAULT_BASE_URL):
        self.base_url = base_url
        self.process: Optional[subprocess.Popen] = None
        self.spawned_by_us = False

    def is_running(self) -> bool:
        """Check if server is already running and responds to health endpoint."""
        client = ApiClient(self.base_url, timeout=2.0)
        try:
            status, body, _ = client.get("/health")
            return status == 200 and isinstance(body, dict) and body.get("status") == "healthy"
        except Exception:
            return False

    def ensure_running(self, timeout_sec: float = 20.0) -> bool:
        """Ensure server is running, compiling and starting it if needed."""
        if self.is_running():
            return True

        # Ensure server binary is built
        server_bin = PROJECT_ROOT / "server" / "target" / "debug" / "server"
        if not server_bin.is_file():
            print(f"{CYAN}Building server binary via cargo build...{RESET}")
            build_res = subprocess.run(
                ["cargo", "build", "--bin", "server"],
                cwd=str(PROJECT_ROOT / "server"),
                capture_output=True,
                text=True,
            )
            if build_res.returncode != 0:
                print(f"{RED}Server build failed:{RESET}\n{build_res.stderr}")
                return False

        print(f"{CYAN}Starting background Axum server binary...{RESET}")
        self.process = subprocess.Popen(
            [str(server_bin)],
            cwd=str(PROJECT_ROOT / "server"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.spawned_by_us = True

        start_time = time.time()
        while time.time() - start_time < timeout_sec:
            if self.is_running():
                print(f"{GREEN}Axum server ready and healthy.{RESET}")
                return True
            if self.process.poll() is not None:
                _, err = self.process.communicate()
                print(f"{RED}Server exited prematurely:{RESET}\n{err}")
                return False
            time.sleep(0.5)

        print(f"{RED}Server failed to respond within {timeout_sec}s timeout.{RESET}")
        self.stop()
        return False

    def stop(self):
        """Stop server if spawned by this test manager."""
        if self.spawned_by_us and self.process and self.process.poll() is None:
            print(f"{CYAN}Stopping Axum server process (PID {self.process.pid})...{RESET}")
            self.process.terminate()
            try:
                self.process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.spawned_by_us = False


class TestReporter:
    """Accumulates and formats test results."""

    def __init__(self, tier_name: str):
        self.tier_name = tier_name
        self.passed: List[Tuple[str, float]] = []
        self.failed: List[Tuple[str, str, float]] = []
        self.skipped: List[Tuple[str, str]] = []
        self.start_time = time.time()

    def record_pass(self, test_name: str, duration: float):
        self.passed.append((test_name, duration))
        print(f"  {GREEN}✓ PASS{RESET} {test_name} {CYAN}({duration:.3f}s){RESET}")

    def record_fail(self, test_name: str, error_msg: str, duration: float):
        self.failed.append((test_name, error_msg, duration))
        print(f"  {RED}✗ FAIL{RESET} {test_name} {CYAN}({duration:.3f}s){RESET}")
        print(f"    {RED}Error: {error_msg}{RESET}")

    def record_skip(self, test_name: str, reason: str):
        self.skipped.append((test_name, reason))
        print(f"  {YELLOW}○ SKIP{RESET} {test_name} {YELLOW}(Reason: {reason}){RESET}")

    def print_summary(self) -> int:
        total_time = time.time() - self.start_time
        total = len(self.passed) + len(self.failed) + len(self.skipped)
        print(f"\n{BOLD}{'=' * 60}{RESET}")
        print(f"{BOLD}Summary: {self.tier_name}{RESET}")
        print(f"{'=' * 60}")
        print(f"Total: {total} | {GREEN}Passed: {len(self.passed)}{RESET} | {RED}Failed: {len(self.failed)}{RESET} | {YELLOW}Skipped: {len(self.skipped)}{RESET}")
        print(f"Duration: {total_time:.3f}s")
        if self.failed:
            print(f"\n{RED}{BOLD}Failed Tests:{RESET}")
            for name, err, _ in self.failed:
                print(f"  - {name}: {err}")
            return 1
        print(f"{GREEN}{BOLD}All {self.tier_name} tests passed successfully.{RESET}")
        return 0
