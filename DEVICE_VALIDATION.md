# Native device and live-provider validation

Status: the prior Android debug APK predates the pinned Flutter 3.47.6 toolchain. Rebuild and install from the current toolchain before recording Android validation. Phone, Linux desktop, recognition, offline recovery and live-provider scenarios remain pending. Confirm the phone's current connection with `adb devices -l` before testing. Automated tests and a successful APK build do not establish recognition accuracy or device recovery.

## Android connection

Use a debug build and a disposable backend/database for the review checks. Start the backend separately and confirm `/api/v1/health` responds before launching the app.

For a USB-connected Android device:

```bash
adb devices -l
adb reverse tcp:8080 tcp:8080
cd app
../tools/flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8080/api/v1
```

For an Android emulator, use `http://10.0.2.2:8080/api/v1` instead. `API_BASE_URL` must include `/api/v1`. Local HTTP is enabled in debug builds. Use an HTTPS backend for release builds.

## Digital Ink recognition

1. With connectivity enabled, open an English lesson and tap **Tải mô hình**. Wait for **Mô hình AI: Sẵn sàng (On-device)**. Repeat for Japanese.
2. Draw each target, wait for the debounced result or tap **Đánh giá**, and record the target, strokes, candidates and score. Include correct writing, an incorrect character and an empty canvas in both languages.
3. Disconnect network access after both models are downloaded. Repeat recognition and confirm it still responds without a download or backend request.
4. Close and reopen the app offline. Confirm downloaded models remain available and lessons previously loaded still appear.
5. On a separate fresh app installation, try downloading while offline. Confirm failure returns to the offline indicator and allows a later retry after connectivity returns.

The ready indicator proves model availability only. Capture actual recognition results to assess accuracy. A heuristic score without a native model is not evidence of ML Kit recognition.

## Offline review and recovery

Use one known lesson and record its initial server card. Keep other test clients idle so repetition counts can be compared.

1. Load lessons online, then make the backend unreachable. Submit one **Good** FSRS review. Confirm the app responds immediately and shows local progress.
2. Close and reopen offline. Confirm the lesson and local review state persist.
3. Restore connectivity and resume the app. Confirm the backend receives the queued review and the card advances once. If the app remains foregrounded, allow its 30-second sync interval plus request time.
4. Resume again and leave the app foregrounded through another interval. Confirm the same review does not advance the server card a second time.
5. Begin a new drawing on the same lesson while sync/lesson refresh occurs. Confirm the selected lesson and strokes remain intact.
6. Interrupt a sync by disabling connectivity or closing the app, then restore connectivity and relaunch. Confirm queued work retries and completes without duplicate FSRS advancement.

For a debug SQLite inspection, the application ID is `com.linguacanvas.app` and the database is `lingua_canvas_local.db`. Check `local_sync_queue` for outstanding mutations and `local_review_logs` for the saved review. Inspect a consistent snapshot, including any SQLite WAL file; do not copy only the database while it is being written. Compare local queue cleanup with the persisted backend review/card, rather than relying only on a success message.

USB reverse forwarding still carries HTTP independently of Wi-Fi. To make the backend unreachable during an offline test, remove the forwarding rule with `adb reverse --remove tcp:8080` and restore it for recovery. Check airplane-mode behavior separately on a device using its normal network connection to the backend.

## Linux desktop

From `app/`, launch with the pinned Flutter wrapper and a reachable backend:

```bash
../tools/flutter run -d linux --dart-define=API_BASE_URL=http://127.0.0.1:8080/api/v1
```

Record the Linux distribution, desktop session, Flutter version, and launch result. Exercise navigation, lesson loading, drawing input, SQLite persistence and recovery after restarting the app. Linux uses the injected/headless recognition path; this does not validate native Android ML Kit recognition.

## Real Ollama smoke

Use an already installed Ollama provider and an available `qwen2.5:3b` model. Do not count curated fallback as a provider pass.

```bash
# Provider terminal
ollama serve
# Backend terminal, from the project root
env -u LLAMA_CPP_BASE_URL -u OLLAMA_BASE_URL \
AI_PROVIDER=ollama AI_ENDPOINT=http://127.0.0.1:11434/api/generate \
AI_MODEL=qwen2.5:3b AI_FALLBACK_ENABLED=false \
cargo run --manifest-path server/Cargo.toml
# Request terminal
curl --fail-with-body -sS http://127.0.0.1:8080/api/v1/ai/roleplay \
  -H 'Content-Type: application/json' \
  -d '{"target_language":"en","topic":"hotel check-in","user_level":"beginner","user_message":"I have a reservation"}'
curl --fail-with-body -sS http://127.0.0.1:8080/api/v1/ai/dialogue \
  -H 'Content-Type: application/json' \
  -d '{"target_language":"ja","profession":"hospitality","difficulty_level":"beginner","topic":"hotel check-in","turn_count":2}'
```

Ensure any project `.env` also matches the intended provider; `LLAMA_CPP_BASE_URL` and `OLLAMA_BASE_URL` take precedence over `AI_ENDPOINT`. Record provider/model version, endpoint, response time and both response bodies. Require HTTP 200 with meaningful English roleplay text and Japanese dialogue lines, translations and writing targets. A timeout or HTTP error with fallback disabled is a failed provider check.

For an available OpenAI-compatible Llama.cpp deployment, use `AI_PROVIDER=llama_cpp`, `LLAMA_CPP_BASE_URL=http://127.0.0.1:8080`, the actual served model ID in `AI_MODEL`, and `AI_FALLBACK_ENABLED=false`. That example uses port 8080 for the provider; run the backend on a different port (for example `PORT=18080`) and direct the same smoke requests to port 18080.

## Result record

| Scenario | Device/provider and version | Evidence | Result |
| --- | --- | --- | --- |
| Android debug APK build | Historical isolated SDK 36 build; minimum Android SDK 24 | Artifact checksum in `TEST_READY.md`; rebuild with pinned Flutter 3.47.6 before current verification | Historical pass |
| Android device installation | Pending | Device/install log | Pending |
| English and Japanese native recognition | Pending | Targets, candidates, scores | Pending |
| Cached recognition offline | Pending | Device log/recording | Pending |
| Offline review survives restart | Pending | Local review/queue and UI | Pending |
| Reconnect/interrupted sync is idempotent | Pending | Local queue and server card/log | Pending |
| Drawing survives foreground refresh | Pending | Device recording | Pending |
| Linux desktop launch and persistence | Pending | Distribution, Flutter version, and launch record | Pending |
| Real provider with fallback disabled | Pending | Provider version and HTTP responses | Pending |
