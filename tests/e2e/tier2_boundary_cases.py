#!/usr/bin/env python3
"""
Tier 2: Boundary & Corner Cases E2E Tests
Validates:
- Invalid rating values (0, 5, 255, -1, non-integers)
- Non-existent lesson IDs and 404 responses
- Malformed JSON payloads and missing/null fields (400/422 handling)
- Offline AI fallback resilience (guaranteeing no 500 Internal Server Errors)
- Unicode, emoji, and special character robustness
- Query parameter boundary handling
"""

from datetime import datetime, timedelta, timezone
import sys
import time
from pathlib import Path

# Add tests/e2e directory to python path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (  # noqa: E402
    ApiClient,
    ServerManager,
    TestReporter,
    BOLD,
    RESET,
)


def run_tier2_tests(client: ApiClient) -> int:
    reporter = TestReporter("Tier 2: Boundary & Corner Cases")
    print(f"\n{BOLD}Starting Tier 2 Boundary & Corner Case Tests...{RESET}\n")

    # -------------------------------------------------------------------------
    # 1. Invalid Ratings Boundary
    # -------------------------------------------------------------------------
    invalid_ratings = [
        (0, "Rating 0 (below min)"),
        (5, "Rating 5 (above max)"),
        (255, "Rating 255 (u8 max)"),
        (100, "Rating 100"),
    ]
    for rating_val, desc in invalid_ratings:
        t0 = time.time()
        test_name = f"test_invalid_rating_{rating_val}"
        try:
            status, body, _ = client.post("/fsrs/review", data={"item_id": "ja_hira_a", "rating": rating_val})
            assert status == 400, f"Expected HTTP 400 for {desc}, got {status}: {body}"
            reporter.record_pass(test_name, time.time() - t0)
        except AssertionError as e:
            reporter.record_fail(test_name, str(e), time.time() - t0)
        except Exception as e:
            reporter.record_fail(test_name, f"Unexpected: {e}", time.time() - t0)

    # Test non-integer rating type
    t0 = time.time()
    try:
        status, body, _ = client.post("/fsrs/review", data={"item_id": "ja_hira_a", "rating": "invalid_str"})
        assert status in [400, 422], f"Expected HTTP 400/422 for string rating, got {status}: {body}"
        reporter.record_pass("test_invalid_rating_type_string", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_invalid_rating_type_string", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_invalid_rating_type_string", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 2. Non-existent Lesson IDs & 404s
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        status, body, _ = client.get("/lessons/non_existent_lesson_id_9999")
        assert status == 404, f"Expected HTTP 404 for non-existent lesson ID, got {status}: {body}"
        reporter.record_pass("test_nonexistent_lesson_returns_404", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_nonexistent_lesson_returns_404", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_nonexistent_lesson_returns_404", f"Unexpected: {e}", time.time() - t0)

    t0 = time.time()
    try:
        # FSRS dynamic card initialization: reviewing an unregistered ID creates a new card
        status, body, _ = client.post(
            "/fsrs/review",
            data={"item_id": "dynamic_new_card_xyz", "rating": 3}
        )
        assert status == 200, f"Expected HTTP 200 for dynamically created card ID, got {status}: {body}"
        assert body.get("item_id") == "dynamic_new_card_xyz", "Item ID mismatch on dynamic card"
        assert body.get("state") == "Review", "Expected state Review for rating 3"
        reporter.record_pass("test_dynamic_card_creation_on_review", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_dynamic_card_creation_on_review", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_dynamic_card_creation_on_review", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 3. Malformed JSON & Missing/Null Fields
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Truncated raw JSON
        status, body, _ = client.post(
            "/fsrs/review",
            data=b'{"item_id": "ja_hira_a", "rating":',
            headers={"Content-Type": "application/json"}
        )
        assert status in [400, 422], f"Expected HTTP 400/422 for malformed JSON, got {status}"
        reporter.record_pass("test_malformed_json_truncated", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_malformed_json_truncated", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_malformed_json_truncated", f"Unexpected: {e}", time.time() - t0)

    t0 = time.time()
    try:
        # Missing required field 'rating'
        status, body, _ = client.post("/fsrs/review", data={"item_id": "ja_hira_a"})
        assert status in [400, 422], f"Expected HTTP 400/422 for missing rating, got {status}"
        reporter.record_pass("test_missing_required_field_rating", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_missing_required_field_rating", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_missing_required_field_rating", f"Unexpected: {e}", time.time() - t0)

    t0 = time.time()
    try:
        # Missing required field 'item_id'
        status, body, _ = client.post("/fsrs/review", data={"rating": 3})
        assert status in [400, 422], f"Expected HTTP 400/422 for missing item_id, got {status}"
        reporter.record_pass("test_missing_required_field_item_id", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_missing_required_field_item_id", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_missing_required_field_item_id", f"Unexpected: {e}", time.time() - t0)

    t0 = time.time()
    try:
        # Empty JSON object for roleplay
        status, body, _ = client.post("/ai/roleplay", data={})
        assert status in [400, 422], f"Expected HTTP 400/422 for empty roleplay payload, got {status}"
        reporter.record_pass("test_roleplay_empty_payload", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_roleplay_empty_payload", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_roleplay_empty_payload", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 4. Offline AI Resilience & Graceful Fallback
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Japanese roleplay with offline LLM
        payload = {
            "target_language": "ja",
            "topic": "daily_standup",
            "user_level": "beginner",
            "user_message": "おはようございます。今日のタスクは単体テストの作成です。"
        }
        status, body, _ = client.post("/ai/roleplay", data=payload)
        assert status == 200, f"Expected HTTP 200 offline fallback for ja, got {status}: {body}"
        assert isinstance(body, dict), "Response must be dict"
        assert "お疲れ様です" in body.get("reply", ""), (
            f"Expected Japanese workplace greeting in fallback reply, got: {body.get('reply')}"
        )
        assert "進捗" in body.get("writing_challenge", ""), (
            f"Expected writing challenge '進捗', got: {body.get('writing_challenge')}"
        )
        reporter.record_pass("test_offline_ai_fallback_japanese", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_offline_ai_fallback_japanese", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_offline_ai_fallback_japanese", f"Unexpected: {e}", time.time() - t0)

    t0 = time.time()
    try:
        # English roleplay with offline LLM
        payload = {
            "target_language": "en",
            "topic": "daily_standup",
            "user_level": "beginner",
            "user_message": "Good morning team, I will deploy the hotfix today."
        }
        status, body, _ = client.post("/ai/roleplay", data=payload)
        assert status == 200, f"Expected HTTP 200 offline fallback for en, got {status}: {body}"
        assert "commit" in body.get("reply", "").lower() or "standup" in body.get("reply", "").lower(), (
            f"Expected workplace keywords in English reply, got: {body.get('reply')}"
        )
        assert body.get("writing_challenge") == "commit", (
            f"Expected writing challenge 'commit', got: {body.get('writing_challenge')}"
        )
        reporter.record_pass("test_offline_ai_fallback_english", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_offline_ai_fallback_english", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_offline_ai_fallback_english", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 5. Unicode, Emojis, and Special Characters
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        payload = {
            "target_language": "ja",
            "topic": "code_review",
            "user_level": "intermediate",
            "user_message": "🚀 PR #42 をレビューしてください！ 'quotes' & <tags> & 🐛バグ修正✨"
        }
        status, body, _ = client.post("/ai/roleplay", data=payload)
        assert status == 200, f"Expected HTTP 200 with complex unicode/emojis, got {status}: {body}"
        assert "reply" in body and len(body["reply"]) > 0
        reporter.record_pass("test_unicode_and_emojis_in_payload", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_unicode_and_emojis_in_payload", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_unicode_and_emojis_in_payload", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 6. Query Parameters Boundary Handling
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Unknown filter values return empty list, not 500 error
        status, body, _ = client.get("/lessons", params={"language": "nonexistent_lang"})
        assert status == 200, f"Expected 200 for nonexistent language, got {status}"
        assert isinstance(body, list) and len(body) == 0, f"Expected empty list, got {body}"

        status, body, _ = client.get("/lessons", params={"category": "nonexistent_cat"})
        assert status == 200, f"Expected 200 for nonexistent category, got {status}"
        assert isinstance(body, list) and len(body) == 0, f"Expected empty list, got {body}"

        reporter.record_pass("test_unknown_query_filters_return_empty_list", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_unknown_query_filters_return_empty_list", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_unknown_query_filters_return_empty_list", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 7. Malformed Sync Payloads: Invalid Rating in Batch
    # -------------------------------------------------------------------------
    invalid_sync_ratings = [0, 5, 99, 255]
    for bad_rating in invalid_sync_ratings:
        t0 = time.time()
        test_name = f"test_sync_invalid_rating_{bad_rating}"
        try:
            payload = {
                "client_id": "bad_rating_tester",
                "reviews": [
                    {
                        "review_id": f"rev_bad_{bad_rating}",
                        "item_id": "ja_hira_a",
                        "rating": bad_rating,
                        "review_time": datetime.now(timezone.utc).isoformat(),
                    }
                ],
            }
            status, body, _ = client.post("/sync", data=payload)
            assert status == 400, f"Expected HTTP 400 for sync rating {bad_rating}, got {status}: {body}"
            reporter.record_pass(test_name, time.time() - t0)
        except AssertionError as e:
            reporter.record_fail(test_name, str(e), time.time() - t0)
        except Exception as e:
            reporter.record_fail(test_name, f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 8. Malformed Sync Payloads: Missing Fields & Bad Types
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Missing item_id in review item
        payload_missing_item = {
            "client_id": "malformed_tester",
            "reviews": [
                {
                    "rating": 3,
                    "review_time": datetime.now(timezone.utc).isoformat(),
                }
            ],
        }
        status, body, _ = client.post("/sync", data=payload_missing_item)
        assert status in [400, 422], f"Expected HTTP 400/422 for missing item_id in sync review, got {status}: {body}"

        # Malformed datetime string in review_time
        payload_bad_dt = {
            "client_id": "malformed_tester",
            "reviews": [
                {
                    "item_id": "ja_hira_a",
                    "rating": 3,
                    "review_time": "invalid_date_not_iso",
                }
            ],
        }
        status_dt, body_dt, _ = client.post("/sync", data=payload_bad_dt)
        assert status_dt in [400, 422], f"Expected HTTP 400/422 for invalid date, got {status_dt}: {body_dt}"

        # Truncated raw JSON
        status_raw, body_raw, _ = client.post("/sync", data='{"client_id": "trunc", "reviews": [{"ite')
        assert status_raw in [400, 422], f"Expected HTTP 400/422 for truncated JSON, got {status_raw}: {body_raw}"

        reporter.record_pass("test_sync_malformed_payload_and_missing_fields", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_sync_malformed_payload_and_missing_fields", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_sync_malformed_payload_and_missing_fields", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 9. Sync Empty Reviews & Completed Lessons
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        empty_payloads = [
            {"client_id": "empty_client_1", "reviews": [], "completed_lessons": []},
            {"reviews": []},
            {},
        ]
        for idx, payload in enumerate(empty_payloads):
            status, body, _ = client.post("/sync", data=payload)
            assert status == 200, f"Expected 200 for empty payload variation {idx}, got {status}: {body}"
            assert body.get("synced_reviews") == 0, f"Expected 0 synced reviews, got {body.get('synced_reviews')}"
            assert body.get("synced_lessons") == 0, f"Expected 0 synced lessons, got {body.get('synced_lessons')}"
            assert isinstance(body.get("updated_cards"), list) and len(body["updated_cards"]) == 0

        reporter.record_pass("test_sync_empty_reviews_and_lessons", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_sync_empty_reviews_and_lessons", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_sync_empty_reviews_and_lessons", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 10. Sync Clock Skew Clamping
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        now_dt = datetime.now(timezone.utc)
        # Client clock is skewed 2 hours into the future
        future_skew_dt = now_dt + timedelta(hours=2)
        skew_payload = {
            "client_id": "clock_skew_tester",
            "reviews": [
                {
                    "review_id": f"rev_skew_{int(time.time())}",
                    "item_id": f"card_skew_{int(time.time())}",
                    "rating": 3,
                    "review_time": future_skew_dt.isoformat(),
                }
            ],
        }
        status, body, _ = client.post("/sync", data=skew_payload)
        assert status == 200, f"Expected 200 for clock skewed sync request, got {status}: {body}"
        assert body.get("synced_reviews") == 1
        assert len(body.get("updated_cards", [])) == 1

        card = body["updated_cards"][0]
        # Verify card's last_review is clamped to approx now (within 60s of now_dt, NOT 2 hours in the future)
        last_rev = datetime.fromisoformat(card["last_review"].replace("Z", "+00:00"))
        time_diff = abs((last_rev - now_dt).total_seconds())
        assert time_diff < 60.0, (
            f"Clock skew was not clamped! Card last_review is {last_rev}, "
            f"expected close to now ({now_dt}), diff is {time_diff}s"
        )

        reporter.record_pass("test_sync_clock_skew_clamping", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_sync_clock_skew_clamping", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_sync_clock_skew_clamping", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 11. Dialogue Generation: Profession Normalization & Fallbacks
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Test various non-standard, custom, or empty profession values
        test_professions = ["astronaut", "culinary_arts", "doctor", "", "unknown_domain_xyz"]
        for prof in test_professions:
            payload = {
                "target_language": "ja",
                "profession": prof,
                "difficulty_level": "intermediate",
                "topic": "team_meeting",
            }
            status, body, _ = client.post("/ai/dialogue", data=payload)
            assert status == 200, f"Expected 200 for fallback profession '{prof}', got {status}: {body}"
            assert isinstance(body, dict), f"Expected dict for profession '{prof}'"
            assert "lines" in body and len(body["lines"]) >= 2, f"Expected lines in dialogue for '{prof}'"
            assert "title" in body and len(body["title"]) > 0

        # English custom profession fallback
        payload_en = {
            "target_language": "en",
            "profession": "deep_sea_diver",
            "difficulty_level": "advanced",
        }
        status_en, body_en, _ = client.post("/ai/dialogue", data=payload_en)
        assert status_en == 200, f"Expected 200 for en custom profession, got {status_en}: {body_en}"
        assert len(body_en.get("lines", [])) >= 2

        reporter.record_pass("test_dialogue_profession_fallbacks", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_dialogue_profession_fallbacks", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_dialogue_profession_fallbacks", f"Unexpected: {e}", time.time() - t0)

    return reporter.print_summary()


if __name__ == "__main__":
    server_mgr = ServerManager()
    server_mgr.ensure_running()
    client = ApiClient()
    try:
        code = run_tier2_tests(client)
        sys.exit(code)
    finally:
        server_mgr.stop()
