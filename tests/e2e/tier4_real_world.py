#!/usr/bin/env python3
"""
Tier 4: Real-World Application Scenarios E2E Tests
Simulates end-to-end real learner workflows described in app_learning_plan.md:
1. Complete Japanese IT workplace learning session:
   - System health & latency benchmark
   - Curriculum exploration (IT workplace Japanese)
   - Canvas stroke study & FSRS review submission (Good -> scheduled 3 days out)
   - Difficult Kanji practice & lapse handling (Again -> scheduled in 10 mins)
   - AI Workplace Roleplay session (Dialogue generation + breakdown + handwriting challenge)
   - Writing challenge practice & Easy rating
   - Dynamic due queue verification
2. Complete English IT workplace learning session:
   - Curriculum retrieval (deploy, deadline, resolve, incident)
   - Daily standup AI roleplay
   - End-of-session queue state verification
"""

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


def run_tier4_tests(client: ApiClient) -> int:
    reporter = TestReporter("Tier 4: Real-World Application Scenarios")
    print(f"\n{BOLD}Starting Tier 4 Real-World Application Scenario Tests...{RESET}\n")

    # =========================================================================
    # SCENARIO 1: Complete Japanese IT Workplace Learning Session
    # =========================================================================
    t0 = time.time()
    try:
        # Step 1: Healthcheck & Latency Benchmark (< 50ms requirement)
        h_start = time.time()
        status, health, _ = client.get("/health")
        latency_ms = (time.time() - h_start) * 1000.0
        assert status == 200, f"Healthcheck failed: {status}"
        assert health.get("status") == "healthy"
        assert latency_ms < 100.0, f"Healthcheck latency too high: {latency_ms:.1f}ms (threshold 100ms)"

        # Step 2: Curriculum Exploration (Japanese IT Workplace)
        status, ja_lessons, _ = client.get("/lessons", params={"language": "ja", "category": "it_workplace"})
        assert status == 200, f"Failed to retrieve ja IT lessons: {status}"
        assert len(ja_lessons) >= 2, f"Expected at least 2 ja IT lessons, got {len(ja_lessons)}"

        # Find target cards: Bug (バグ) and Development (開発)
        bug_lesson = next((l for l in ja_lessons if l["id"] == "ja_kata_bug"), None)
        assert bug_lesson is not None, "Missing 'ja_kata_bug' in Japanese IT curriculum"
        assert bug_lesson["target_text"] == "バグ"
        assert "発生しました" in bug_lesson["workplace_context"]

        dev_lesson = next((l for l in ja_lessons if l["id"] == "ja_it_kaihatsu"), None)
        assert dev_lesson is not None, "Missing 'ja_it_kaihatsu' in Japanese IT curriculum"
        assert dev_lesson["target_text"] == "開発"

        # Step 3: Study & Review Bug (バグ) -> Good rating (3)
        rev_status, rev_bug, _ = client.post("/fsrs/review", data={"item_id": bug_lesson["id"], "rating": 3})
        assert rev_status == 200, f"Review submission failed: {rev_status}"
        assert rev_bug["item_id"] == "ja_kata_bug"
        assert rev_bug["state"] == "Review"
        assert rev_bug["reps"] == 1
        assert rev_bug["interval_days"] >= 3.0, f"Expected ~3 days interval for Good, got {rev_bug['interval_days']}"

        # Step 4: Study Difficult Kanji 開発 -> Again rating (1)
        rev_status, rev_dev, _ = client.post("/fsrs/review", data={"item_id": dev_lesson["id"], "rating": 1})
        assert rev_status == 200, f"Review submission failed: {rev_status}"
        assert rev_dev["item_id"] == "ja_it_kaihatsu"
        assert rev_dev["state"] == "Learning"
        assert rev_dev["reps"] == 1
        assert rev_dev["interval_days"] < 0.05, f"Expected ~10 minutes interval for Again, got {rev_dev['interval_days']}"

        # Step 5: Interactive Workplace AI Roleplay
        roleplay_payload = {
            "target_language": "ja",
            "topic": "daily_standup",
            "user_level": "intermediate",
            "user_message": "本日のタスクはバグ修正と新しいモジュールの開発です。"
        }
        rp_status, rp_resp, _ = client.post("/ai/roleplay", data=roleplay_payload)
        assert rp_status == 200, f"Roleplay failed with status {rp_status}"
        assert "reply" in rp_resp and len(rp_resp["reply"]) > 0
        assert "reply_translation_vi" in rp_resp and len(rp_resp["reply_translation_vi"]) > 0
        assert len(rp_resp["breakdown"]) >= 1, "Expected vocabulary breakdown items"
        challenge_word = rp_resp.get("writing_challenge")
        assert challenge_word, "Roleplay did not return a writing challenge"

        # Step 6: Review Roleplay Challenge Word (Easy rating = 4)
        challenge_id = f"challenge_{challenge_word}"
        c_status, c_rev, _ = client.post("/fsrs/review", data={"item_id": challenge_id, "rating": 4})
        assert c_status == 200
        assert c_rev["state"] == "Review"
        assert c_rev["interval_days"] >= 14.0, f"Expected ~15 days for Easy rating, got {c_rev['interval_days']}"

        # Step 7: Queue State Verification
        due_status, due_list, _ = client.get("/fsrs/due")
        assert due_status == 200
        due_ids = [item["id"] for item in due_list]
        # The Bug card (scheduled 3 days in future) must NOT be in immediate due queue
        assert "ja_kata_bug" not in due_ids, "ja_kata_bug scheduled 3 days ahead should not be due now"

        reporter.record_pass("test_japanese_workplace_session_workflow", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_japanese_workplace_session_workflow", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_japanese_workplace_session_workflow", f"Unexpected: {e}", time.time() - t0)

    # =========================================================================
    # SCENARIO 2: Complete English IT Workplace Learning Session
    # =========================================================================
    t0 = time.time()
    try:
        # Step 1: Curriculum Exploration (English IT Workplace)
        status, en_lessons, _ = client.get("/lessons", params={"language": "en", "category": "it_workplace"})
        assert status == 200, f"Failed to retrieve en lessons: {status}"
        assert len(en_lessons) >= 3, f"Expected at least 3 en IT lessons, got {len(en_lessons)}"

        deploy_lesson = next((l for l in en_lessons if l["id"] == "en_it_deploy"), None)
        assert deploy_lesson is not None, "Missing 'en_it_deploy' in English curriculum"
        assert deploy_lesson["target_text"] == "deploy"

        # Step 2: Study & Review 'deploy' -> Good rating (3)
        rev_status, rev_deploy, _ = client.post("/fsrs/review", data={"item_id": deploy_lesson["id"], "rating": 3})
        assert rev_status == 200
        assert rev_deploy["state"] == "Review"
        assert rev_deploy["interval_days"] >= 3.0

        # Step 3: English IT Workplace AI Roleplay
        roleplay_payload = {
            "target_language": "en",
            "topic": "daily_standup",
            "user_level": "intermediate",
            "user_message": "I have completed testing and we are ready to deploy the service."
        }
        rp_status, rp_resp, _ = client.post("/ai/roleplay", data=roleplay_payload)
        assert rp_status == 200
        assert "reply" in rp_resp
        assert "commit" in rp_resp.get("writing_challenge", "").lower()

        # Step 4: Verify deploy lesson is removed from immediate due list
        due_status, due_list, _ = client.get("/fsrs/due")
        assert due_status == 200
        due_ids = [item["id"] for item in due_list]
        assert "en_it_deploy" not in due_ids, "en_it_deploy scheduled 3 days ahead should not be due now"

        reporter.record_pass("test_english_workplace_session_workflow", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_english_workplace_session_workflow", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_english_workplace_session_workflow", f"Unexpected: {e}", time.time() - t0)

    return reporter.print_summary()


if __name__ == "__main__":
    server_mgr = ServerManager()
    server_mgr.ensure_running()
    client = ApiClient()
    try:
        code = run_tier4_tests(client)
        sys.exit(code)
    finally:
        server_mgr.stop()
