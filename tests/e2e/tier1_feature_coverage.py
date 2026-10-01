#!/usr/bin/env python3
"""
Tier 1: Feature Coverage E2E Tests
Validates:
- Git baseline cleanliness and security configurations
- Multi-environment templates
- Flutter analyze and test execution
- Docker configuration syntax (Progressive Testability aware)
- Axum REST API endpoints (/health, /lessons, /lessons/:id, /fsrs/review, /fsrs/due, /ai/roleplay)
"""

import os
import subprocess
import sys
import time
from datetime import datetime
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


def run_tier1_tests(client: ApiClient) -> int:
    reporter = TestReporter("Tier 1: Feature Coverage")
    print(f"\n{BOLD}Starting Tier 1 Feature Coverage Tests...{RESET}\n")

    # -------------------------------------------------------------------------
    # 1. Git Baseline & Cleanliness
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        git_dir = PROJECT_ROOT / ".git"
        assert git_dir.is_dir(), "Monorepo root .git directory does not exist"

        gitignore_file = PROJECT_ROOT / ".gitignore"
        assert gitignore_file.is_file(), "Root .gitignore does not exist"
        gitignore_content = gitignore_file.read_text()
        required_patterns = ["target/", ".dart_tool/", "build/", ".env"]
        for pat in required_patterns:
            assert pat in gitignore_content, f".gitignore missing pattern '{pat}'"

        # Check git remote
        res = subprocess.run(
            ["git", "remote", "-v"],
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
        )
        assert res.returncode == 0, f"git remote -v failed: {res.stderr}"
        assert "duyphan0503/lingua_canvas" in res.stdout, (
            f"Remote origin does not contain duyphan0503/lingua_canvas:\n{res.stdout}"
        )

        reporter.record_pass("test_git_repository_cleanliness", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_git_repository_cleanliness", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_git_repository_cleanliness", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 2. Multi-Environment Templates
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        expected_templates = [
            ".env.example",
            ".env.development.example",
            ".env.staging.example",
            ".env.production.example",
        ]
        for tmpl in expected_templates:
            tmpl_path = PROJECT_ROOT / tmpl
            assert tmpl_path.is_file(), f"Missing environment template: {tmpl}"
            content = tmpl_path.read_text()
            assert len(content.strip()) > 0, f"Template {tmpl} is empty"

        reporter.record_pass("test_multi_environment_templates_exist", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_multi_environment_templates_exist", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_multi_environment_templates_exist", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 3. Flutter Code Analysis
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        app_dir = PROJECT_ROOT / "app"
        res = subprocess.run(
            ["flutter", "analyze"],
            cwd=str(app_dir),
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert res.returncode == 0, f"flutter analyze failed with code {res.returncode}:\n{res.stdout}\n{res.stderr}"
        reporter.record_pass("test_flutter_analyze_clean", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_flutter_analyze_clean", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_flutter_analyze_clean", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 4. Flutter Unit & Widget Tests
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        app_dir = PROJECT_ROOT / "app"
        res = subprocess.run(
            ["flutter", "test"],
            cwd=str(app_dir),
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert res.returncode == 0, f"flutter test failed with code {res.returncode}:\n{res.stdout}\n{res.stderr}"
        assert "All tests passed" in res.stdout, f"Expected 'All tests passed' in output:\n{res.stdout}"
        reporter.record_pass("test_flutter_unit_and_widget_tests_pass", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_flutter_unit_and_widget_tests_pass", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_flutter_unit_and_widget_tests_pass", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 5. Docker Configuration Coverage (Progressive Testability)
    # -------------------------------------------------------------------------
    t0 = time.time()
    compose_path = PROJECT_ROOT / "docker-compose.yml"
    dockerfile_path = PROJECT_ROOT / "server" / "Dockerfile"
    if compose_path.is_file() or dockerfile_path.is_file():
        try:
            if compose_path.is_file():
                res = subprocess.run(
                    ["docker", "compose", "-f", str(compose_path), "config"],
                    capture_output=True,
                    text=True,
                )
                assert res.returncode == 0, f"docker compose config syntax error: {res.stderr}"
            reporter.record_pass("test_docker_configurations_valid", time.time() - t0)
        except AssertionError as e:
            reporter.record_fail("test_docker_configurations_valid", str(e), time.time() - t0)
        except Exception as e:
            reporter.record_fail("test_docker_configurations_valid", f"Unexpected: {e}", time.time() - t0)
    else:
        reporter.record_skip(
            "test_docker_configurations_valid",
            "docker-compose.yml / Dockerfile scheduled for Milestone 4 (Enterprise DevOps)"
        )

    # -------------------------------------------------------------------------
    # 6. REST API: /health
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        status, body, _ = client.get("/health")
        assert status == 200, f"Expected status 200, got {status}"
        assert isinstance(body, dict), f"Expected dict body, got {type(body)}"
        assert body.get("status") == "healthy", f"Expected status=='healthy', got {body.get('status')}"
        assert body.get("service") == "lingua_canvas_server", f"Expected service=='lingua_canvas_server', got {body.get('service')}"
        assert body.get("version") == "0.1.0", f"Expected version=='0.1.0', got {body.get('version')}"
        reporter.record_pass("test_api_health_endpoint", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_health_endpoint", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_health_endpoint", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 7. REST API: /lessons (List all)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        status, body, _ = client.get("/lessons")
        assert status == 200, f"Expected status 200, got {status}"
        assert isinstance(body, list), f"Expected list of lessons, got {type(body)}"
        assert len(body) >= 5, f"Expected at least 5 lessons in seed data, got {len(body)}"

        # Validate schema of first lesson
        lesson = body[0]
        required_fields = [
            "id", "language", "category", "target_text",
            "phonetic_or_kana", "meaning_vi", "workplace_context",
            "workplace_context_vi", "stroke_order_hints", "difficulty_level"
        ]
        for field in required_fields:
            assert field in lesson, f"Missing field '{field}' in lesson item: {lesson}"
        assert isinstance(lesson["stroke_order_hints"], list), "stroke_order_hints must be list"
        assert isinstance(lesson["difficulty_level"], int), "difficulty_level must be int"

        reporter.record_pass("test_api_list_lessons_schema", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_list_lessons_schema", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_list_lessons_schema", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 8. REST API: /lessons with query filtering (language & category)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        # Filter Japanese
        status_ja, body_ja, _ = client.get("/lessons", params={"language": "ja"})
        assert status_ja == 200, f"Expected 200 for ja query, got {status_ja}"
        assert len(body_ja) > 0, "Expected non-empty ja lessons"
        for item in body_ja:
            assert item["language"] == "ja", f"Expected language ja, got {item['language']}"

        # Filter English
        status_en, body_en, _ = client.get("/lessons", params={"language": "en"})
        assert status_en == 200, f"Expected 200 for en query, got {status_en}"
        assert len(body_en) > 0, "Expected non-empty en lessons"
        for item in body_en:
            assert item["language"] == "en", f"Expected language en, got {item['language']}"

        # Filter Category
        status_cat, body_cat, _ = client.get("/lessons", params={"category": "it_workplace"})
        assert status_cat == 200, f"Expected 200 for it_workplace category, got {status_cat}"
        assert len(body_cat) > 0, "Expected non-empty it_workplace lessons"
        for item in body_cat:
            assert item["category"] == "it_workplace", f"Expected it_workplace, got {item['category']}"

        reporter.record_pass("test_api_lessons_filtering", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_lessons_filtering", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_lessons_filtering", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 9. REST API: /lessons/:id (Single lesson)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        status, body, _ = client.get("/lessons/ja_hira_a")
        assert status == 200, f"Expected status 200, got {status}"
        assert body.get("id") == "ja_hira_a", f"Expected id ja_hira_a, got {body.get('id')}"
        assert body.get("target_text") == "あ", f"Expected target_text 'あ', got {body.get('target_text')}"
        assert body.get("language") == "ja", f"Expected language 'ja', got {body.get('language')}"
        reporter.record_pass("test_api_get_single_lesson", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_get_single_lesson", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_get_single_lesson", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 10. REST API: /fsrs/review (Submit review)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        payload = {"item_id": "ja_hira_a", "rating": 3}
        status, body, _ = client.post("/fsrs/review", data=payload)
        assert status == 200, f"Expected status 200, got {status}: {body}"
        assert isinstance(body, dict), f"Expected dict body, got {type(body)}"
        assert body.get("item_id") == "ja_hira_a", f"item_id mismatch: {body.get('item_id')}"
        assert body.get("state") == "Review", f"Expected state 'Review', got {body.get('state')}"
        assert body.get("reps") >= 1, f"Expected reps >= 1, got {body.get('reps')}"
        assert body.get("stability") > 0.0, f"Expected stability > 0, got {body.get('stability')}"
        assert body.get("difficulty") >= 1.0, f"Expected difficulty >= 1, got {body.get('difficulty')}"
        assert "next_review" in body, f"next_review missing from response: {body}"
        # Validate next_review is valid ISO timestamp
        next_dt = datetime.fromisoformat(body["next_review"].replace("Z", "+00:00"))
        assert next_dt is not None, "Failed to parse next_review timestamp"
        assert body.get("interval_days") > 0.0, f"Expected interval_days > 0, got {body.get('interval_days')}"

        reporter.record_pass("test_api_fsrs_review_submission", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_fsrs_review_submission", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_fsrs_review_submission", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 11. REST API: /fsrs/due (Due reviews queue)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        status, body, _ = client.get("/fsrs/due")
        assert status == 200, f"Expected status 200, got {status}"
        assert isinstance(body, list), f"Expected list of due lessons, got {type(body)}"
        assert len(body) > 0, "Due list should not be empty initially"
        reporter.record_pass("test_api_fsrs_due_queue", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_fsrs_due_queue", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_fsrs_due_queue", f"Unexpected: {e}", time.time() - t0)

    # -------------------------------------------------------------------------
    # 12. REST API: /ai/roleplay (Workplace dialogue)
    # -------------------------------------------------------------------------
    t0 = time.time()
    try:
        payload = {
            "target_language": "ja",
            "topic": "daily_standup",
            "user_level": "beginner",
            "user_message": "本日の進捗を報告します。"
        }
        status, body, _ = client.post("/ai/roleplay", data=payload)
        assert status == 200, f"Expected status 200, got {status}: {body}"
        assert isinstance(body, dict), f"Expected dict body, got {type(body)}"
        assert "reply" in body and len(body["reply"]) > 0, "Missing or empty 'reply'"
        assert "reply_translation_vi" in body and len(body["reply_translation_vi"]) > 0, "Missing 'reply_translation_vi'"
        assert "breakdown" in body and isinstance(body["breakdown"], list), "Missing or invalid 'breakdown'"
        assert len(body["breakdown"]) > 0, "Breakdown should have at least 1 keyword item"
        item0 = body["breakdown"][0]
        assert "word" in item0 and "meaning_vi" in item0, f"Breakdown item missing fields: {item0}"
        assert "writing_challenge" in body and len(body["writing_challenge"]) > 0, "Missing 'writing_challenge'"

        reporter.record_pass("test_api_ai_roleplay", time.time() - t0)
    except AssertionError as e:
        reporter.record_fail("test_api_ai_roleplay", str(e), time.time() - t0)
    except Exception as e:
        reporter.record_fail("test_api_ai_roleplay", f"Unexpected: {e}", time.time() - t0)

    return reporter.print_summary()


if __name__ == "__main__":
    server_mgr = ServerManager()
    server_mgr.ensure_running()
    client = ApiClient()
    try:
        code = run_tier1_tests(client)
        sys.exit(code)
    finally:
        server_mgr.stop()
