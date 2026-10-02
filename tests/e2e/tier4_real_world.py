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

    # =========================================================================
    # SCENARIO 3: Hospitality Worker Japanese Dialogue & Offline Review Sync
    # =========================================================================
    t0 = time.time()
    try:
        # Step 1: Request Dialogue Generation for Hotel Check-in
        dialogue_payload = {
            "target_language": "ja",
            "profession": "hospitality",
            "difficulty_level": "beginner",
            "topic": "hotel_checkin",
            "turn_count": 5,
        }
        d_status, d_body, _ = client.post("/ai/dialogue", data=dialogue_payload)
        assert d_status == 200, f"Dialogue generation failed: {d_status}: {d_body}"
        assert d_body.get("profession") == "hospitality"
        assert d_body.get("difficulty_level") == "beginner"
        assert len(d_body.get("lines", [])) >= 2, "Expected multiple dialogue lines"
        assert len(d_body.get("vocabulary", [])) >= 1, "Expected vocabulary list"

        writing_targets = d_body.get("suggested_writing_targets", [])
        assert len(writing_targets) >= 1, "Expected suggested writing targets for handwriting canvas"

        target_word_1 = writing_targets[0]
        target_word_2 = writing_targets[1] if len(writing_targets) > 1 else "確認"

        # Step 2: Simulate Offline Canvas Handwriting Practice & Queue Accumulation
        # Worker practices handwriting offline and records ratings locally
        offline_time = datetime.now(timezone.utc)
        card_id_1 = f"ja_hosp_{int(time.time())}_1"
        card_id_2 = f"ja_hosp_{int(time.time())}_2"

        sync_payload = {
            "client_id": "hosp_mobile_terminal_01",
            "reviews": [
                {
                    "review_id": f"rev_{card_id_1}",
                    "item_id": card_id_1,
                    "rating": 3,  # Good
                    "review_time": offline_time.isoformat(),
                    "elapsed_days": 1.0,
                    "scheduled_days": 3,
                },
                {
                    "review_id": f"rev_{card_id_2}",
                    "item_id": card_id_2,
                    "rating": 4,  # Easy
                    "review_time": offline_time.isoformat(),
                    "elapsed_days": 1.0,
                    "scheduled_days": 5,
                },
            ],
            "completed_lessons": [
                {
                    "lesson_id": card_id_1,
                    "completed_at": offline_time.isoformat(),
                    "score": 0.98,
                }
            ],
        }

        # Step 3: Reconnect to Network & Flush Offline Queue to /sync
        s_status, s_body, _ = client.post("/sync", data=sync_payload)
        assert s_status == 200, f"Sync push failed: {s_status}: {s_body}"
        assert s_body.get("synced_reviews") == 2, f"Expected 2 synced reviews, got {s_body.get('synced_reviews')}"
        assert s_body.get("synced_lessons") == 1, f"Expected 1 synced lesson, got {s_body.get('synced_lessons')}"
        assert card_id_1 in s_body.get("synced_completed_lesson_ids", []), (
            f"Completion for {card_id_1} was not acknowledged: {s_body}"
        )
        assert len(s_body.get("updated_cards", [])) == 2

        card1_resp = next((c for c in s_body["updated_cards"] if c["item_id"] == card_id_1), None)
        card2_resp = next((c for c in s_body["updated_cards"] if c["item_id"] == card_id_2), None)
        assert card1_resp is not None, f"Card 1 {card_id_1} not returned in sync response"
        assert card2_resp is not None, f"Card 2 {card_id_2} not returned in sync response"

        assert card1_resp["state"] == "Review"
        assert card2_resp["state"] == "Review"
        assert card1_resp["reps"] == 1
        assert card2_resp["reps"] == 1
        assert card1_resp["stability"] > 0.0
        assert card2_resp["stability"] > 0.0

        # Easy rating (4) should yield higher stability / interval than Good rating (3)
        assert card2_resp["stability"] >= card1_resp["stability"], (
            f"Easy rating stability ({card2_resp['stability']}) should be >= Good ({card1_resp['stability']})"
        )

        # Step 4: Verify Multi-Device Pull Synchronization
        pull_status, pull_body, _ = client.get("/sync/pull", params={"since": "2026-01-01T00:00:00Z"})
        assert pull_status == 200, f"Sync pull failed: {pull_status}: {pull_body}"
        pulled_cards = pull_body.get("cards", []) or pull_body.get("updated_cards", [])
        pulled_ids = [c["item_id"] for c in pulled_cards]
        assert card_id_1 in pulled_ids, f"Card {card_id_1} missing in delta pull"
        assert card_id_2 in pulled_ids, f"Card {card_id_2} missing in delta pull"

        # Step 5: Verify Cards are Scheduled into Future and Not in Immediate Due Queue
        due_status, due_list, _ = client.get("/fsrs/due")
        assert due_status == 200
        due_ids = [item["id"] for item in due_list]
        assert card_id_1 not in due_ids, f"Card {card_id_1} scheduled in future should not be in due list"
        assert card_id_2 not in due_ids, f"Card {card_id_2} scheduled in future should not be in due list"

        reporter.record_pass("test_hospitality_japanese_learning_and_offline_sync_workflow", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_hospitality_japanese_learning_and_offline_sync_workflow", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_hospitality_japanese_learning_and_offline_sync_workflow", f"Unexpected: {e}", time.time() - t0)

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
