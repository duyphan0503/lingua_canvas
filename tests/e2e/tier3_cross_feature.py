#!/usr/bin/env python3
"""
Tier 3: Cross-Feature Combinations E2E Tests
Validates:
- Cross-feature state transition: Lesson retrieval -> FSRS review -> Next due calculation
- Full FSRS card lifecycle: New -> Review -> Consecutive Review -> Lapse to Relearning
- Mathematical stability & difficulty bounds under consecutive reviews
- Multi-environment template consistency across dev/staging/prod
- Concurrency & thread safety under parallel review requests
- Docker service startup dependency contracts (Progressive Testability aware)
"""

import concurrent.futures
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Add tests/e2e directory to python path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (  # noqa: E402
    ApiClient,
    PROJECT_ROOT,
    ServerManager,
    TestReporter,
    BOLD,
    RESET,
)


def run_tier3_tests(client: ApiClient) -> int:
    reporter = TestReporter("Tier 3: Cross-Feature Combinations")
    print(f"\n{BOLD}Starting Tier 3 Cross-Feature Combination Tests...{RESET}\n")

    # -------------------------------------------------------------------------
    # 1. Lesson Retrieval -> FSRS Review -> Due Queue Dynamic Transition
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Step 1: Get initial due queue
        status, initial_due, _ = client.get("/fsrs/due")
        assert status == 200, f"Failed to fetch initial due list: {status}"
        assert len(initial_due) > 0, "Initial due list is empty"
        first_item = initial_due[0]
        first_id = first_item["id"]

        # Step 2: Submit a Good (3) review for this first item
        review_payload = {"item_id": first_id, "rating": 3}
        rev_status, rev_body, _ = client.post("/fsrs/review", data=review_payload)
        assert rev_status == 200, f"Review failed with status {rev_status}"
        assert rev_body.get("state") == "Review", f"Expected state 'Review', got {rev_body.get('state')}"
        assert rev_body.get("interval_days", 0) >= 1.0, f"Expected interval >= 1 day, got {rev_body.get('interval_days')}"

        # Step 3: Fetch updated due queue
        updated_status, updated_due, _ = client.get("/fsrs/due")
        assert updated_status == 200, f"Failed to fetch updated due list: {updated_status}"
        updated_ids = [item["id"] for item in updated_due]

        # Verify the reviewed card was evicted from the due queue (since next_review is 3 days in future)
        assert first_id not in updated_ids, (
            f"Card '{first_id}' was reviewed with Good (due in 3 days) but still appears in immediate due list!"
        )

        reporter.record_pass("test_fsrs_review_to_due_queue_state_transition", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_fsrs_review_to_due_queue_state_transition", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_fsrs_review_to_due_queue_state_transition", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 2. Complete FSRS Lifecycle: New -> Review -> Progression -> Lapse
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        card_id = f"lifecycle_card_{int(time.time())}"

        # Phase 1: New -> Good
        s1, b1, _ = client.post("/fsrs/review", data={"item_id": card_id, "rating": 3})
        assert s1 == 200
        assert b1["state"] == "Review"
        assert b1["reps"] == 1
        initial_stability = b1["stability"]
        assert initial_stability > 0.0

        # Phase 2: Consecutive Good review
        s2, b2, _ = client.post("/fsrs/review", data={"item_id": card_id, "rating": 3})
        assert s2 == 200
        assert b2["state"] == "Review"
        assert b2["reps"] == 2
        assert b2["interval_days"] >= b1["interval_days"], "Interval should not decrease on consecutive Good ratings"

        # Phase 3: Lapse (rating 1 - Again)
        s3, b3, _ = client.post("/fsrs/review", data={"item_id": card_id, "rating": 1})
        assert s3 == 200
        assert b3["state"] == "Relearning", f"Expected state 'Relearning' after lapse, got {b3['state']}"
        assert b3["reps"] == 3
        # Should be scheduled ~10 minutes out (interval < 0.05 days)
        assert b3["interval_days"] < 0.05, f"Lapsed card should be scheduled in ~10 mins, got {b3['interval_days']} days"

        reporter.record_pass("test_fsrs_full_lifecycle_and_lapse_transition", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_fsrs_full_lifecycle_and_lapse_transition", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_fsrs_full_lifecycle_and_lapse_transition", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 3. FSRS Mathematical Bounds (Difficulty clamped in [1.0, 10.0])
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Test extreme ratings sequence to verify clamping
        easy_card = f"bound_easy_{int(time.time())}"
        for _ in range(5):
            s, b, _ = client.post("/fsrs/review", data={"item_id": easy_card, "rating": 4})
            assert s == 200
            diff = b["difficulty"]
            assert 1.0 <= diff <= 10.0, f"Difficulty {diff} out of bounds [1.0, 10.0]"

        hard_card = f"bound_hard_{int(time.time())}"
        for _ in range(5):
            s, b, _ = client.post("/fsrs/review", data={"item_id": hard_card, "rating": 1})
            assert s == 200
            diff = b["difficulty"]
            assert 1.0 <= diff <= 10.0, f"Difficulty {diff} out of bounds [1.0, 10.0]"

        reporter.record_pass("test_fsrs_mathematical_bounds_clamping", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_fsrs_mathematical_bounds_clamping", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_fsrs_mathematical_bounds_clamping", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 4. Multi-Environment Template Consistency
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        env_files = [
            ".env.example",
            ".env.development.example",
            ".env.staging.example",
            ".env.production.example",
        ]
        parsed_keys = {}
        for fname in env_files:
            fpath = PROJECT_ROOT / fname
            assert fpath.is_file(), f"Missing file: {fname}"
            keys = set()
            for line in fpath.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k = line.split("=", 1)[0].strip()
                    keys.add(k)
            parsed_keys[fname] = keys

        # Verify essential keys are in all 4 environments
        required_keys = {"PORT", "DATABASE_URL", "AI_ENDPOINT", "AI_MODEL", "RUST_LOG"}
        for fname, keys in parsed_keys.items():
            missing = required_keys - keys
            assert not missing, f"File {fname} is missing required environment variables: {missing}"

        reporter.record_pass("test_multi_environment_configuration_consistency", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_multi_environment_configuration_consistency", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_multi_environment_configuration_consistency", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 5. Concurrent Review Requests (Thread Safety of AppState RwLock)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        def submit_single(idx: int):
            item_id = f"concurrent_card_{idx}_{int(time.time())}"
            rating = (idx % 4) + 1  # 1, 2, 3, 4
            status, body, _ = client.post("/fsrs/review", data={"item_id": item_id, "rating": rating})
            return status, body

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            futures = [executor.submit(submit_single, i) for i in range(16)]
            results = [f.result() for f in futures]

        for s, b in results:
            assert s == 200, f"Concurrent review returned status {s}: {b}"
            assert "state" in b and "reps" in b

        reporter.record_pass("test_concurrent_review_requests_thread_safety", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_concurrent_review_requests_thread_safety", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_concurrent_review_requests_thread_safety", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 6. Docker Service Dependencies (Progressive Testability)
    # -------------------------------------------------------------------------
    t0 = time.time()
    compose_path = PROJECT_ROOT / "docker-compose.yml"
    if compose_path.is_file():
        try:
            content = compose_path.read_text()
            assert "server" in content, "docker-compose.yml missing 'server' service"
            assert "postgres" in content, "docker-compose.yml missing 'postgres' service"
            reporter.record_pass("test_docker_service_dependencies", time.time() - t0)
        except AssertionError as e:
            reporter.record_fail("test_docker_service_dependencies", str(e), time.time() - t0)
        except Exception as e:
            reporter.record_fail("test_docker_service_dependencies", f"Unexpected: {e}", time.time() - t0)
    else:
        reporter.record_skip(
            "test_docker_service_dependencies",
            "docker-compose.yml service hierarchy scheduled for Milestone 4 (Enterprise DevOps)"
        )

    return reporter.print_summary()


if __name__ == "__main__":
    server_mgr = ServerManager()
    server_mgr.ensure_running()
    client = ApiClient()
    try:
        code = run_tier3_tests(client)
        sys.exit(code)
    finally:
        server_mgr.stop()
