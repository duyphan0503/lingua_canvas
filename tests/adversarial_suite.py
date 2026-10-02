#!/usr/bin/env python3
"""
Adversarial Verification Suite for Milestone 1: Local AI Engine Integration.
Empirically tests:
1. Connect Timeout (2s) on non-routable IP and Request Timeout (8s) on hanging server.
   Also tests configurable timeouts (AI_CONNECT_TIMEOUT_SECS / AI_TIMEOUT_SECS).
2. Markdown code fence stripping:
   - Plain JSON
   - Code fence with tag (```json ... ```)
   - Code fence without tag (``` ... ```)
   - Code fence surrounded by preamble and postscript commentary
   - Embedded JSON within conversation prose without code fences
   - Corrupted JSON inside fence (verifying fallback instead of crash/500)
3. Fallback matrix coverage:
   - All 24 permutations (ja/en x it/hospitality/business/general x beginner/intermediate/advanced)
   - Validates dialogue structure (lines >= 4, vocab >= 2, grammar hints, writing targets)
   - Validates roleplay structure (reply, translation_vi, breakdown, challenge, hints, replies)
   - Verifies kanji presence ([\u4e00-\u9faf]) in Japanese writing targets and challenges
"""

import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SERVER_BIN = PROJECT_ROOT / "server" / "target" / "debug" / "server"
KANJI_REGEX = re.compile(r"[\u4e00-\u9faf]")
PORT_OFFSET = int(os.environ.get("ADVERSARIAL_PORT_OFFSET", "0"))


def _port(base: int) -> int:
    return base + PORT_OFFSET

# Colors for terminal output
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"


class MockLLMHandler(http.server.BaseHTTPRequestHandler):
    mode = "openai"  # "openai" or "ollama"
    custom_content = None
    hang_seconds = 0
    request_count = 0
    last_received_payload = None

    def log_message(self, format, *args):
        pass  # Quiet logging

    def do_POST(self):
        MockLLMHandler.request_count += 1
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8", errors="replace")
        try:
            MockLLMHandler.last_received_payload = json.loads(body)
        except Exception:
            MockLLMHandler.last_received_payload = body

        if MockLLMHandler.hang_seconds > 0:
            time.sleep(MockLLMHandler.hang_seconds)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        content = MockLLMHandler.custom_content or "{}"
        if MockLLMHandler.mode == "openai":
            response_obj = {
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": "test-mock-model",
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": content,
                        },
                        "finish_reason": "stop",
                    }
                ],
            }
        else:
            response_obj = {
                "model": "test-mock-model",
                "response": content,
                "done": True,
            }

        try:
            self.wfile.write(json.dumps(response_obj).encode("utf-8"))
        except BrokenPipeError:
            # The Axum client may time out while this mock intentionally hangs.
            pass


class MockServerThread:
    def __init__(self, port: int = 18888):
        self.port = _port(port)
        self.server: Optional[socketserver.TCPServer] = None
        self.thread: Optional[threading.Thread] = None

    def start(self):
        socketserver.TCPServer.allow_reuse_address = True
        self.server = socketserver.TCPServer(("127.0.0.1", self.port), MockLLMHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()


class AxumServerInstance:
    def __init__(self, env_overrides: Dict[str, str], port: int = 8080):
        self.port = _port(port)
        self.env = os.environ.copy()
        self.env.update(env_overrides)
        self.env["PORT"] = str(self.port)
        self.process: Optional[subprocess.Popen] = None

    def start(self, timeout_sec: float = 15.0):
        self.process = subprocess.Popen(
            [str(SERVER_BIN)],
            cwd=str(PROJECT_ROOT / "server"),
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        start_time = time.time()
        while time.time() - start_time < timeout_sec:
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{self.port}/api/v1/health")
                with urllib.request.urlopen(req, timeout=1.0) as resp:
                    if resp.status == 200:
                        return True
            except Exception:
                pass
            if self.process.poll() is not None:
                _, err = self.process.communicate()
                raise RuntimeError(f"Axum server exited with error: {err}")
            time.sleep(0.2)
        raise TimeoutError("Axum server did not become healthy in time")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def http_post_json(url: str, payload: Dict[str, Any], timeout: float = 30.0) -> Tuple[int, Any, float]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            elapsed = time.time() - t0
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw), elapsed
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        raw = e.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = raw
        return e.code, parsed, elapsed


def run_tests():
    total_passed = 0
    total_failed = 0
    test_results = []

    def record_result(name: str, passed: bool, msg: str, duration: float):
        nonlocal total_passed, total_failed
        if passed:
            total_passed += 1
            print(f"  {GREEN}✓ PASS{RESET} {name} ({duration:.3f}s)")
        else:
            total_failed += 1
            print(f"  {RED}✗ FAIL{RESET} {name} ({duration:.3f}s)")
            print(f"    {RED}Error: {msg}{RESET}")
        test_results.append((name, passed, msg, duration))

    print(f"\n{BOLD}{CYAN}======================================================================{RESET}")
    print(f"{BOLD}{CYAN} Lingua Canvas - Adversarial Verification Suite (Milestone 1){RESET}")
    print(f"{BOLD}{CYAN}======================================================================{RESET}\n")

    # =========================================================================
    # PART 1: TIMEOUT AND ERROR RESILIENCE
    # =========================================================================
    print(f"{BOLD}1. EMPIRICAL VERIFICATION: TIMEOUT & FALLBACK BEHAVIOR{RESET}")

    # Test 1.1: Connect Timeout (2 seconds) with non-routable IP
    print("  --> Testing Connect Timeout on non-routable endpoint (10.255.255.1:81)...")
    srv_connect = AxumServerInstance({
        "AI_ENDPOINT": "http://10.255.255.1:81/v1/chat/completions",
        "AI_CONNECT_TIMEOUT_SECS": "2",
        "AI_TIMEOUT_SECS": "8",
    }, port=8081)
    srv_connect.start()
    try:
        # Test Roleplay
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8081)}/api/v1/ai/roleplay", {
            "target_language": "ja",
            "profession": "it",
            "user_level": "beginner",
            "topic": "daily_standup",
            "user_message": "おはようございます"
        })
        passed = (code == 200) and (1.8 <= dur <= 3.8) and ("reply" in body) and ("お疲れ様です" in body.get("reply", ""))
        msg = f"Status: {code}, Duration: {dur:.2f}s (expected ~2s connect timeout), reply: {body.get('reply')}"
        record_result("test_connect_timeout_roleplay_fallback", passed, msg, dur)

        # Test Dialogue
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8081)}/api/v1/ai/dialogue", {
            "target_language": "ja",
            "profession": "hospitality",
            "difficulty_level": "intermediate",
            "topic": "concierge"
        })
        passed = (code == 200) and (1.8 <= dur <= 3.8) and ("lines" in body) and (len(body.get("lines", [])) >= 4)
        msg = f"Status: {code}, Duration: {dur:.2f}s (expected ~2s connect timeout), lines: {len(body.get('lines', []))}"
        record_result("test_connect_timeout_dialogue_fallback", passed, msg, dur)
    finally:
        srv_connect.stop()

    # Test 1.2: Request Timeout (8 seconds) with hanging mock server
    print("  --> Testing Request Timeout on hanging mock server...")
    mock_hang = MockServerThread(port=18881)
    MockLLMHandler.hang_seconds = 20  # Hang longer than 8s timeout
    MockLLMHandler.custom_content = '{"reply": "Will never be received"}'
    mock_hang.start()

    srv_req_timeout = AxumServerInstance({
        "AI_ENDPOINT": f"http://127.0.0.1:{_port(18881)}/v1/chat/completions",
        "AI_CONNECT_TIMEOUT_SECS": "2",
        "AI_TIMEOUT_SECS": "8",
    }, port=8082)
    srv_req_timeout.start()
    try:
        # Test Roleplay request timeout
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8082)}/api/v1/ai/roleplay", {
            "target_language": "en",
            "profession": "it",
            "user_level": "beginner",
            "topic": "daily_standup",
            "user_message": "Good morning team"
        })
        passed = (code == 200) and (7.8 <= dur <= 10.0) and ("reply" in body) and ("commit" in body.get("reply", "").lower() or "standup" in body.get("reply", "").lower())
        msg = f"Status: {code}, Duration: {dur:.2f}s (expected ~8s request timeout), reply: {body.get('reply')}"
        record_result("test_request_timeout_roleplay_fallback", passed, msg, dur)

        # Test Dialogue request timeout
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8082)}/api/v1/ai/dialogue", {
            "target_language": "en",
            "profession": "business",
            "difficulty_level": "intermediate",
            "topic": "negotiation"
        })
        passed = (code == 200) and (7.8 <= dur <= 10.0) and ("lines" in body) and (len(body.get("lines", [])) >= 4)
        msg = f"Status: {code}, Duration: {dur:.2f}s (expected ~8s request timeout), lines: {len(body.get('lines', []))}"
        record_result("test_request_timeout_dialogue_fallback", passed, msg, dur)
    finally:
        srv_req_timeout.stop()
        mock_hang.stop()

    # Test 1.3: Custom Timeout Configuration via Environment Variables
    print("  --> Testing Custom Configured Timeouts (connect=1s, request=3s)...")
    mock_hang_custom = MockServerThread(port=18882)
    MockLLMHandler.hang_seconds = 10
    mock_hang_custom.start()

    srv_custom = AxumServerInstance({
        "AI_ENDPOINT": f"http://127.0.0.1:{_port(18882)}/v1/chat/completions",
        "AI_CONNECT_TIMEOUT_SECS": "1",
        "AI_TIMEOUT_SECS": "3",
    }, port=8083)
    srv_custom.start()
    try:
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8083)}/api/v1/ai/roleplay", {
            "target_language": "ja",
            "profession": "general",
            "user_level": "intermediate",
            "topic": "meeting",
            "user_message": "会議を始めましょう"
        })
        passed = (code == 200) and (2.8 <= dur <= 4.8) and ("reply" in body)
        msg = f"Status: {code}, Duration: {dur:.2f}s (expected ~3s custom timeout)"
        record_result("test_custom_request_timeout_3s", passed, msg, dur)
    finally:
        srv_custom.stop()
        mock_hang_custom.stop()

    print()

    # =========================================================================
    # PART 2: MARKDOWN CODE FENCE STRIPPING
    # =========================================================================
    print(f"{BOLD}2. EMPIRICAL VERIFICATION: MARKDOWN CODE FENCE STRIPPING & PARSING{RESET}")

    mock_llm = MockServerThread(port=18883)
    MockLLMHandler.hang_seconds = 0
    mock_llm.start()

    srv_llm = AxumServerInstance({
        "AI_ENDPOINT": f"http://127.0.0.1:{_port(18883)}/v1/chat/completions",
        "AI_PROVIDER": "openai_compatible",
        "AI_CONNECT_TIMEOUT_SECS": "2",
        "AI_TIMEOUT_SECS": "5",
    }, port=8084)
    srv_llm.start()

    try:
        # Dialogue target mock payload
        mock_dialogue_json = {
            "topic": "adversarial_testing",
            "profession": "it",
            "difficulty_level": "advanced",
            "title": "Adversarial Code Inspection",
            "title_vi": "Kiểm thử mã nguồn đối kháng",
            "lines": [
                {"speaker": "Alice", "text": "Test line 1", "translation_vi": "Dòng 1", "phonetic_or_romaji": "Line 1"},
                {"speaker": "Bob", "text": "Test line 2", "translation_vi": "Dòng 2", "phonetic_or_romaji": "Line 2"},
                {"speaker": "Alice", "text": "Test line 3", "translation_vi": "Dòng 3", "phonetic_or_romaji": "Line 3"},
                {"speaker": "Bob", "text": "Test line 4", "translation_vi": "Dòng 4", "phonetic_or_romaji": "Line 4"}
            ],
            "vocabulary": [
                {"word": "inspect", "meaning_vi": "thanh tra", "kana_or_phonetic": "/ɪnˈspekt/"},
                {"word": "verify", "meaning_vi": "xác minh", "kana_or_phonetic": "/ˈver.ə.faɪ/"}
            ],
            "grammar_hints": [
                {"pattern": "must + verb", "explanation_vi": "phải làm gì", "example": "You must verify."}
            ],
            "suggested_writing_targets": ["inspect", "verify"]
        }

        # Variation 2.1: Plain JSON
        MockLLMHandler.custom_content = json.dumps(mock_dialogue_json)
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8084)}/api/v1/ai/dialogue", {
            "target_language": "en", "profession": "it", "difficulty_level": "advanced"
        })
        passed = (code == 200) and (body.get("title") == "Adversarial Code Inspection")
        msg = f"Status: {code}, Title: {body.get('title')}"
        record_result("test_fence_stripping_plain_json", passed, msg, dur)

        # Variation 2.2: Markdown code fence with ```json
        MockLLMHandler.custom_content = f"```json\n{json.dumps(mock_dialogue_json, indent=2)}\n```"
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8084)}/api/v1/ai/dialogue", {
            "target_language": "en", "profession": "it", "difficulty_level": "advanced"
        })
        passed = (code == 200) and (body.get("title") == "Adversarial Code Inspection")
        msg = f"Status: {code}, Title: {body.get('title')}"
        record_result("test_fence_stripping_with_json_tag", passed, msg, dur)

        # Variation 2.3: Markdown code fence without language tag (```)
        MockLLMHandler.custom_content = f"```\n{json.dumps(mock_dialogue_json)}\n```"
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8084)}/api/v1/ai/dialogue", {
            "target_language": "en", "profession": "it", "difficulty_level": "advanced"
        })
        passed = (code == 200) and (body.get("title") == "Adversarial Code Inspection")
        msg = f"Status: {code}, Title: {body.get('title')}"
        record_result("test_fence_stripping_without_language_tag", passed, msg, dur)

        # Variation 2.4: Code fence with conversational preamble and postscript
        MockLLMHandler.custom_content = (
            "Here is the dialogue scenario you requested for IT professionals:\n\n"
            f"```json\n{json.dumps(mock_dialogue_json, indent=2)}\n```\n\n"
            "I hope this helps your language learning! Let me know if you need more scenarios."
        )
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8084)}/api/v1/ai/dialogue", {
            "target_language": "en", "profession": "it", "difficulty_level": "advanced"
        })
        passed = (code == 200) and (body.get("title") == "Adversarial Code Inspection")
        msg = f"Status: {code}, Title: {body.get('title')}"
        record_result("test_fence_stripping_with_preamble_and_postscript", passed, msg, dur)

        # Variation 2.5: Raw JSON embedded in prose without code fences
        MockLLMHandler.custom_content = (
            f"Certainly! Here is your requested JSON object: {json.dumps(mock_dialogue_json)} "
            "Please parse it accordingly."
        )
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8084)}/api/v1/ai/dialogue", {
            "target_language": "en", "profession": "it", "difficulty_level": "advanced"
        })
        passed = (code == 200) and (body.get("title") == "Adversarial Code Inspection")
        msg = f"Status: {code}, Title: {body.get('title')}"
        record_result("test_fence_stripping_embedded_in_prose_no_fences", passed, msg, dur)

        # Variation 2.6: Malformed / Unparseable JSON inside fences -> Graceful fallback
        MockLLMHandler.custom_content = "```json\n{invalid json syntax, missing keys:\n```"
        code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8084)}/api/v1/ai/dialogue", {
            "target_language": "ja", "profession": "it", "difficulty_level": "intermediate"
        })
        # Axum must NOT return HTTP 500! It must gracefully fall back to curated Japanese IT intermediate dialogue
        passed = (code == 200) and ("lines" in body) and (body.get("profession") == "it") and (len(body.get("lines", [])) >= 4)
        msg = f"Status: {code}, Handled malformed LLM response with fallback (lines: {len(body.get('lines', []))})"
        record_result("test_malformed_llm_json_graceful_fallback", passed, msg, dur)

    finally:
        srv_llm.stop()
        mock_llm.stop()

    print()

    # =========================================================================
    # PART 3: FALLBACK MATRICES ACROSS ALL 24 PERMUTATIONS
    # =========================================================================
    print(f"{BOLD}3. EMPIRICAL VERIFICATION: 24 PERMUTATIONS FALLBACK MATRICES{RESET}")

    # Launch server with unreachable endpoint to force fallback matrix evaluation
    srv_fallback = AxumServerInstance({
        "AI_ENDPOINT": f"http://127.0.0.1:{_port(18884)}/v1/chat/completions",
        "AI_CONNECT_TIMEOUT_SECS": "1",
        "AI_TIMEOUT_SECS": "1",
    }, port=8085)
    srv_fallback.start()

    languages = ["ja", "en"]
    professions = ["it", "hospitality", "business", "general"]
    levels = ["beginner", "intermediate", "advanced"]

    try:
        # 3.1 Test all 24 Dialogue Permutations
        print("  --> Testing 24 Dialogue Fallback Permutations...")
        dialogue_permutations_tested = 0
        dialogue_kanji_verified = 0

        for lang in languages:
            for prof in professions:
                for lvl in levels:
                    dialogue_permutations_tested += 1
                    t_start = time.time()
                    code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8085)}/api/v1/ai/dialogue", {
                        "target_language": lang,
                        "profession": prof,
                        "difficulty_level": lvl,
                        "topic": f"test_{lang}_{prof}_{lvl}",
                        "turn_count": 4,
                    })

                    reasons = []
                    if code != 200:
                        reasons.append(f"HTTP {code}")
                    if body.get("profession") != prof:
                        reasons.append(f"profession mismatch ({body.get('profession')} != {prof})")
                    if body.get("difficulty_level") != lvl:
                        reasons.append(f"level mismatch ({body.get('difficulty_level')} != {lvl})")
                    if not body.get("title") or not body.get("title_vi"):
                        reasons.append("empty title or title_vi")

                    lines = body.get("lines", [])
                    if len(lines) < 4:
                        reasons.append(f"insufficient lines ({len(lines)} < 4)")
                    for i, line in enumerate(lines):
                        for field in ["speaker", "text", "translation_vi", "phonetic_or_romaji"]:
                            if not line.get(field):
                                reasons.append(f"line[{i}] missing {field}")

                    vocab = body.get("vocabulary", [])
                    if len(vocab) < 2:
                        reasons.append(f"insufficient vocabulary ({len(vocab)} < 2)")
                    for i, item in enumerate(vocab):
                        for field in ["word", "meaning_vi", "kana_or_phonetic"]:
                            if not item.get(field):
                                reasons.append(f"vocab[{i}] missing {field}")

                    hints = body.get("grammar_hints", [])
                    if len(hints) < 1:
                        reasons.append(f"missing grammar hints")

                    targets = body.get("suggested_writing_targets", [])
                    if len(targets) < 1:
                        reasons.append(f"missing suggested_writing_targets")

                    # Kanji check for Japanese dialogues
                    if lang == "ja":
                        has_kanji = any(KANJI_REGEX.search(t) for t in targets)
                        if has_kanji:
                            dialogue_kanji_verified += 1
                        else:
                            reasons.append(f"no Kanji found in Japanese writing targets: {targets}")

                    passed = (len(reasons) == 0)
                    msg = "; ".join(reasons) if reasons else f"targets: {targets}"
                    record_result(f"test_dialogue_fallback_{lang}_{prof}_{lvl}", passed, msg, dur)

        # 3.2 Test all 24 Roleplay Permutations
        print("\n  --> Testing 24 Roleplay Fallback Permutations...")
        roleplay_permutations_tested = 0
        roleplay_kanji_verified = 0

        for lang in languages:
            for prof in professions:
                for lvl in levels:
                    roleplay_permutations_tested += 1
                    t_start = time.time()
                    code, body, dur = http_post_json(f"http://127.0.0.1:{_port(8085)}/api/v1/ai/roleplay", {
                        "target_language": lang,
                        "profession": prof,
                        "user_level": lvl,
                        "topic": f"test_{lang}_{prof}_{lvl}",
                        "user_message": "Hello test message"
                    })

                    reasons = []
                    if code != 200:
                        reasons.append(f"HTTP {code}")
                    if not body.get("reply"):
                        reasons.append("empty reply")
                    if not body.get("reply_translation_vi"):
                        reasons.append("empty reply_translation_vi")

                    breakdown = body.get("breakdown", [])
                    if len(breakdown) < 2:
                        reasons.append(f"insufficient breakdown ({len(breakdown)} < 2)")
                    for i, item in enumerate(breakdown):
                        for field in ["word", "meaning_vi", "kana_or_phonetic"]:
                            if not item.get(field):
                                reasons.append(f"breakdown[{i}] missing {field}")

                    challenge = body.get("writing_challenge", "")
                    if not challenge:
                        reasons.append("missing writing_challenge")

                    hints = body.get("grammar_hints", [])
                    if not hints or len(hints) < 1:
                        reasons.append("missing grammar_hints")

                    replies = body.get("suggested_replies", [])
                    if not replies or len(replies) < 2:
                        reasons.append("insufficient suggested_replies (< 2)")

                    if lang == "ja":
                        has_kanji = bool(KANJI_REGEX.search(challenge))
                        if has_kanji:
                            roleplay_kanji_verified += 1
                        else:
                            reasons.append(f"no Kanji found in Japanese writing_challenge: '{challenge}'")

                    passed = (len(reasons) == 0)
                    msg = "; ".join(reasons) if reasons else f"challenge: '{challenge}'"
                    record_result(f"test_roleplay_fallback_{lang}_{prof}_{lvl}", passed, msg, dur)

    finally:
        srv_fallback.stop()

    # =========================================================================
    # SUMMARY REPORT
    # =========================================================================
    print(f"\n{BOLD}{CYAN}======================================================================{RESET}")
    print(f"{BOLD} FINAL ADVERSARIAL VERIFICATION SUMMARY{RESET}")
    print(f"{BOLD}{CYAN}======================================================================{RESET}")
    print(f"Total Tests Executed: {len(test_results)}")
    print(f"Passed: {GREEN}{BOLD}{total_passed}{RESET}")
    print(f"Failed: {RED}{BOLD}{total_failed}{RESET}")
    print(f"Dialogue Fallback Permutations: {dialogue_permutations_tested}/24 (Japanese with Kanji: {dialogue_kanji_verified}/12)")
    print(f"Roleplay Fallback Permutations: {roleplay_permutations_tested}/24 (Japanese with Kanji: {roleplay_kanji_verified}/12)")
    print(f"{BOLD}{CYAN}======================================================================{RESET}\n")

    if total_failed == 0:
        print(f"{GREEN}{BOLD}✔ ALL ADVERSARIAL STRESS TESTS PASSED - SYSTEM ROBUST & COMPLIANT{RESET}\n")
        return 0
    else:
        print(f"{RED}{BOLD}✖ SOME ADVERSARIAL TESTS FAILED - REVIEW LOGS ABOVE{RESET}\n")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
