use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tower::ServiceExt;

use server::{ai::AIService, create_app, data::get_seed_lessons, fsrs::FSRS, routes::AppState};

fn setup_test_app() -> axum::Router {
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    };
    create_app(state)
}

#[tokio::test]
async fn test_health_check_endpoint() {
    let app = setup_test_app();

    let request = Request::builder()
        .uri("/api/v1/health")
        .method("GET")
        .body(Body::empty())
        .unwrap();

    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let body_bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body_bytes).unwrap();

    assert_eq!(body["status"], "healthy");
    assert_eq!(body["service"], "lingua_canvas_server");
    assert_eq!(body["version"], "0.1.0");
}

#[tokio::test]
async fn test_list_lessons_and_filtering() {
    let app = setup_test_app();

    // 1. Fetch all lessons
    let req = Request::builder()
        .uri("/api/v1/lessons")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let all: Vec<Value> = serde_json::from_slice(&bytes).unwrap();
    assert!(
        all.len() >= 10,
        "Expected at least 10 seed lessons, found {}",
        all.len()
    );

    // 2. Filter Japanese lessons
    let req_ja = Request::builder()
        .uri("/api/v1/lessons?language=ja")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_ja = app.clone().oneshot(req_ja).await.unwrap();
    assert_eq!(resp_ja.status(), StatusCode::OK);
    let bytes_ja = resp_ja.into_body().collect().await.unwrap().to_bytes();
    let ja_list: Vec<Value> = serde_json::from_slice(&bytes_ja).unwrap();
    assert!(!ja_list.is_empty());
    for item in ja_list {
        assert_eq!(item["language"], "ja");
    }

    // 3. Filter English lessons
    let req_en = Request::builder()
        .uri("/api/v1/lessons?language=en")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_en = app.clone().oneshot(req_en).await.unwrap();
    assert_eq!(resp_en.status(), StatusCode::OK);
    let bytes_en = resp_en.into_body().collect().await.unwrap().to_bytes();
    let en_list: Vec<Value> = serde_json::from_slice(&bytes_en).unwrap();
    assert!(!en_list.is_empty());
    for item in en_list {
        assert_eq!(item["language"], "en");
    }

    // 4. Non-existent filter returns empty list
    let req_none = Request::builder()
        .uri("/api/v1/lessons?language=nonexistent")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_none = app.oneshot(req_none).await.unwrap();
    assert_eq!(resp_none.status(), StatusCode::OK);
    let bytes_none = resp_none.into_body().collect().await.unwrap().to_bytes();
    let none_list: Vec<Value> = serde_json::from_slice(&bytes_none).unwrap();
    assert!(none_list.is_empty());
}

#[tokio::test]
async fn test_get_single_lesson_by_id() {
    let app = setup_test_app();

    // 1. Existing lesson
    let req = Request::builder()
        .uri("/api/v1/lessons/ja_hira_a")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let lesson: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(lesson["id"], "ja_hira_a");
    assert_eq!(lesson["target_text"], "あ");
    assert_eq!(lesson["language"], "ja");

    // 2. Non-existent lesson returns 404
    let req_404 = Request::builder()
        .uri("/api/v1/lessons/unknown_id_9999")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_404 = app.oneshot(req_404).await.unwrap();
    assert_eq!(resp_404.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_fsrs_review_submission_and_lifecycle() {
    let app = setup_test_app();

    // 1. Valid review (Rating Good = 3)
    let payload = serde_json::json!({
        "item_id": "ja_hira_a",
        "rating": 3
    });
    let req = Request::builder()
        .uri("/api/v1/fsrs/review")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let review: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(review["item_id"], "ja_hira_a");
    assert_eq!(review["state"], "Review");
    assert_eq!(review["reps"], 1);
    assert!(review["stability"].as_f64().unwrap() > 0.0);
    assert!(review["interval_days"].as_f64().unwrap() >= 1.0);

    // 2. Invalid rating (e.g. 5) returns 400
    let invalid_payload = serde_json::json!({
        "item_id": "ja_hira_a",
        "rating": 5
    });
    let req_inv = Request::builder()
        .uri("/api/v1/fsrs/review")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&invalid_payload).unwrap()))
        .unwrap();
    let resp_inv = app.clone().oneshot(req_inv).await.unwrap();
    assert_eq!(resp_inv.status(), StatusCode::BAD_REQUEST);

    // 3. Dynamic card creation for unlisted item
    let dyn_payload = serde_json::json!({
        "item_id": "dynamic_vocab_xyz",
        "rating": 4
    });
    let req_dyn = Request::builder()
        .uri("/api/v1/fsrs/review")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&dyn_payload).unwrap()))
        .unwrap();
    let resp_dyn = app.oneshot(req_dyn).await.unwrap();
    assert_eq!(resp_dyn.status(), StatusCode::OK);
    let dyn_bytes = resp_dyn.into_body().collect().await.unwrap().to_bytes();
    let dyn_review: Value = serde_json::from_slice(&dyn_bytes).unwrap();
    assert_eq!(dyn_review["item_id"], "dynamic_vocab_xyz");
    assert_eq!(dyn_review["state"], "Review");
    assert!(dyn_review["interval_days"].as_f64().unwrap() >= 14.0);
}

#[tokio::test]
async fn test_fsrs_due_queue_and_eviction() {
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    };
    let app = create_app(state);

    // Initial due queue
    let req_due = Request::builder()
        .uri("/api/v1/fsrs/due")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_due = app.clone().oneshot(req_due).await.unwrap();
    assert_eq!(resp_due.status(), StatusCode::OK);
    let bytes_due = resp_due.into_body().collect().await.unwrap().to_bytes();
    let due_list: Vec<Value> = serde_json::from_slice(&bytes_due).unwrap();
    assert!(
        !due_list.is_empty(),
        "Initial due list should contain unreviewed lessons"
    );

    let first_id = due_list[0]["id"].as_str().unwrap().to_string();

    // Review first_id with Good
    let rev_req = Request::builder()
        .uri("/api/v1/fsrs/review")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(
            serde_json::to_vec(&serde_json::json!({
                "item_id": first_id,
                "rating": 3
            }))
            .unwrap(),
        ))
        .unwrap();
    let rev_resp = app.clone().oneshot(rev_req).await.unwrap();
    assert_eq!(rev_resp.status(), StatusCode::OK);

    // Re-check due queue; first_id must be evicted
    let req_due2 = Request::builder()
        .uri("/api/v1/fsrs/due")
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_due2 = app.oneshot(req_due2).await.unwrap();
    assert_eq!(resp_due2.status(), StatusCode::OK);
    let bytes_due2 = resp_due2.into_body().collect().await.unwrap().to_bytes();
    let due_list2: Vec<Value> = serde_json::from_slice(&bytes_due2).unwrap();
    let remaining_ids: Vec<&str> = due_list2
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert!(
        !remaining_ids.contains(&first_id.as_str()),
        "Card {} should be evicted from due queue",
        first_id
    );
}

#[tokio::test]
async fn test_ai_roleplay_endpoint() {
    let app = setup_test_app();

    // 1. Japanese Roleplay Prompt
    let payload_ja = serde_json::json!({
        "target_language": "ja",
        "topic": "daily_standup",
        "user_level": "beginner",
        "user_message": "おはようございます。今日のタスクは単体テストの作成です。"
    });
    let req_ja = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_ja).unwrap()))
        .unwrap();
    let resp_ja = app.clone().oneshot(req_ja).await.unwrap();
    assert_eq!(resp_ja.status(), StatusCode::OK);
    let bytes_ja = resp_ja.into_body().collect().await.unwrap().to_bytes();
    let body_ja: Value = serde_json::from_slice(&bytes_ja).unwrap();
    assert!(!body_ja["reply"].as_str().unwrap().is_empty());
    assert!(!body_ja["reply_translation_vi"].as_str().unwrap().is_empty());
    assert!(!body_ja["breakdown"].as_array().unwrap().is_empty());
    assert!(!body_ja["writing_challenge"].as_str().unwrap().is_empty());

    // 2. English Roleplay Prompt
    let payload_en = serde_json::json!({
        "target_language": "en",
        "topic": "daily_standup",
        "user_level": "beginner",
        "user_message": "Good morning team, I will deploy the hotfix today."
    });
    let req_en = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_en).unwrap()))
        .unwrap();
    let resp_en = app.oneshot(req_en).await.unwrap();
    assert_eq!(resp_en.status(), StatusCode::OK);
    let bytes_en = resp_en.into_body().collect().await.unwrap().to_bytes();
    let body_en: Value = serde_json::from_slice(&bytes_en).unwrap();
    assert!(!body_en["reply"].as_str().unwrap().is_empty());
    assert_eq!(body_en["writing_challenge"], "commit");
}

#[tokio::test]
async fn test_ai_roleplay_with_profession_and_level() {
    let app = setup_test_app();

    // 1. Hospitality Beginner (Japanese)
    let payload_hosp = serde_json::json!({
        "target_language": "ja",
        "profession": "hospitality",
        "user_level": "beginner",
        "topic": "hotel_checkin",
        "user_message": "チェックインをお願いします。"
    });
    let req_hosp = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_hosp).unwrap()))
        .unwrap();
    let resp_hosp = app.clone().oneshot(req_hosp).await.unwrap();
    assert_eq!(resp_hosp.status(), StatusCode::OK);
    let bytes_hosp = resp_hosp.into_body().collect().await.unwrap().to_bytes();
    let body_hosp: Value = serde_json::from_slice(&bytes_hosp).unwrap();
    assert_eq!(body_hosp["writing_challenge"], "予約");
    assert!(!body_hosp["grammar_hints"].as_array().unwrap().is_empty());
    assert!(body_hosp["suggested_replies"].as_array().unwrap().len() >= 2);

    // 2. Business Intermediate (English)
    let payload_biz = serde_json::json!({
        "target_language": "en",
        "profession": "business",
        "user_level": "intermediate",
        "topic": "contract_negotiation",
        "user_message": "Can we negotiate a volume discount?"
    });
    let req_biz = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_biz).unwrap()))
        .unwrap();
    let resp_biz = app.clone().oneshot(req_biz).await.unwrap();
    assert_eq!(resp_biz.status(), StatusCode::OK);
    let bytes_biz = resp_biz.into_body().collect().await.unwrap().to_bytes();
    let body_biz: Value = serde_json::from_slice(&bytes_biz).unwrap();
    assert_eq!(body_biz["writing_challenge"], "agreement");

    // 3. General Intermediate (Japanese)
    let payload_gen = serde_json::json!({
        "target_language": "ja",
        "profession": "general",
        "user_level": "intermediate",
        "topic": "sync_meeting",
        "user_message": "進捗を共有しましょう。"
    });
    let req_gen = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_gen).unwrap()))
        .unwrap();
    let resp_gen = app.oneshot(req_gen).await.unwrap();
    assert_eq!(resp_gen.status(), StatusCode::OK);
    let bytes_gen = resp_gen.into_body().collect().await.unwrap().to_bytes();
    let body_gen: Value = serde_json::from_slice(&bytes_gen).unwrap();
    assert_eq!(body_gen["writing_challenge"], "共有");
}

#[tokio::test]
async fn test_ai_dialogue_endpoint_hospitality() {
    let app = setup_test_app();

    let payload = serde_json::json!({
        "target_language": "ja",
        "profession": "hospitality",
        "difficulty_level": "beginner",
        "topic": "hotel_checkin",
        "turn_count": 4
    });

    let req = Request::builder()
        .uri("/api/v1/ai/dialogue")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["profession"], "hospitality");
    assert_eq!(body["difficulty_level"], "beginner");
    assert!(!body["title"].as_str().unwrap().is_empty());
    assert!(!body["title_vi"].as_str().unwrap().is_empty());

    let lines = body["lines"].as_array().expect("Expected lines array");
    assert!(lines.len() >= 4);
    for line in lines {
        assert!(!line["speaker"].as_str().unwrap().is_empty());
        assert!(!line["text"].as_str().unwrap().is_empty());
        assert!(!line["translation_vi"].as_str().unwrap().is_empty());
        assert!(!line["phonetic_or_romaji"].as_str().unwrap().is_empty());
    }

    let vocab = body["vocabulary"]
        .as_array()
        .expect("Expected vocabulary array");
    assert!(vocab.len() >= 2);
    for item in vocab {
        assert!(!item["word"].as_str().unwrap().is_empty());
        assert!(!item["meaning_vi"].as_str().unwrap().is_empty());
        assert!(!item["kana_or_phonetic"].as_str().unwrap().is_empty());
    }

    let hints = body["grammar_hints"]
        .as_array()
        .expect("Expected grammar_hints");
    assert!(!hints.is_empty());

    let targets = body["suggested_writing_targets"]
        .as_array()
        .expect("Expected suggested_writing_targets");
    assert!(!targets.is_empty());
}

#[tokio::test]
async fn test_ai_dialogue_endpoint_it_and_business() {
    let app = setup_test_app();

    // 1. Japanese IT Intermediate
    let payload_it = serde_json::json!({
        "target_language": "ja",
        "profession": "it",
        "difficulty_level": "intermediate",
        "topic": "code_review"
    });
    let req_it = Request::builder()
        .uri("/api/v1/ai/dialogue")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_it).unwrap()))
        .unwrap();
    let resp_it = app.clone().oneshot(req_it).await.unwrap();
    assert_eq!(resp_it.status(), StatusCode::OK);
    let bytes_it = resp_it.into_body().collect().await.unwrap().to_bytes();
    let body_it: Value = serde_json::from_slice(&bytes_it).unwrap();
    assert_eq!(body_it["profession"], "it");
    assert_eq!(body_it["difficulty_level"], "intermediate");
    let targets_it = body_it["suggested_writing_targets"].as_array().unwrap();
    assert!(targets_it.iter().any(|t| t == "接続"));

    // 2. English Business Advanced
    let payload_biz = serde_json::json!({
        "target_language": "en",
        "profession": "business",
        "difficulty_level": "advanced",
        "topic": "merger_acquisition"
    });
    let req_biz = Request::builder()
        .uri("/api/v1/ai/dialogue")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_biz).unwrap()))
        .unwrap();
    let resp_biz = app.clone().oneshot(req_biz).await.unwrap();
    assert_eq!(resp_biz.status(), StatusCode::OK);
    let bytes_biz = resp_biz.into_body().collect().await.unwrap().to_bytes();
    let body_biz: Value = serde_json::from_slice(&bytes_biz).unwrap();
    assert_eq!(body_biz["profession"], "business");
    assert_eq!(body_biz["difficulty_level"], "advanced");
    let targets_biz = body_biz["suggested_writing_targets"].as_array().unwrap();
    assert!(targets_biz
        .iter()
        .any(|t| t == "merger" || t == "compliance"));

    // 3. Fallback defaults and field aliases
    let payload_alias = serde_json::json!({
        "language": "ja",
        "context": "standup"
    });
    let req_alias = Request::builder()
        .uri("/api/v1/ai/dialogue")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload_alias).unwrap()))
        .unwrap();
    let resp_alias = app.oneshot(req_alias).await.unwrap();
    assert_eq!(resp_alias.status(), StatusCode::OK);
    let bytes_alias = resp_alias.into_body().collect().await.unwrap().to_bytes();
    let body_alias: Value = serde_json::from_slice(&bytes_alias).unwrap();
    assert_eq!(body_alias["profession"], "it");
    assert_eq!(body_alias["difficulty_level"], "beginner");
}

#[tokio::test]
async fn test_ai_roleplay_exact_project_md_payload() {
    let app = setup_test_app();

    // Exact payload from PROJECT.md:
    // { "language": "ja", "topic": "hotel_checkin", "difficulty": "beginner", "profession": "hospitality" }
    let payload = serde_json::json!({
        "language": "ja",
        "topic": "hotel_checkin",
        "difficulty": "beginner",
        "profession": "hospitality"
    });

    let req = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();

    // Verify both opening_line and reply are present and non-empty
    let reply = body["reply"].as_str().expect("reply must be string");
    let opening_line = body["opening_line"]
        .as_str()
        .expect("opening_line must be string");
    assert!(!reply.is_empty(), "reply must not be empty");
    assert!(!opening_line.is_empty(), "opening_line must not be empty");
    assert_eq!(
        reply, opening_line,
        "opening_line should match reply for initial greeting"
    );

    // Verify suggested_responses and suggested_replies
    let suggested_responses = body["suggested_responses"]
        .as_array()
        .expect("suggested_responses must exist");
    let suggested_replies = body["suggested_replies"]
        .as_array()
        .expect("suggested_replies must exist");
    assert_eq!(suggested_responses, suggested_replies);
    assert!(!suggested_responses.is_empty());
}

#[test]
fn test_dialogue_line_serialization_compatibility() {
    use server::models::DialogueLine;

    let line = DialogueLine {
        speaker: "フロント係".to_string(),
        text: "いらっしゃいませ。".to_string(),
        translation_vi: "Kính chào quý khách.".to_string(),
        phonetic_or_romaji: "Irasshaimase.".to_string(),
    };

    let serialized = serde_json::to_value(&line).unwrap();
    assert_eq!(serialized["speaker"], "フロント係");
    assert_eq!(serialized["text"], "いらっしゃいませ。");
    assert_eq!(serialized["translation_vi"], "Kính chào quý khách.");
    assert_eq!(serialized["translation"], "Kính chào quý khách.");
    assert_eq!(serialized["phonetic_or_romaji"], "Irasshaimase.");
    assert_eq!(serialized["romaji"], "Irasshaimase.");

    // Verify deserialization from PROJECT.md format (translation & romaji)
    let json_data = serde_json::json!({
        "speaker": "Staff",
        "text": "Welcome to hotel",
        "translation": "Chào mừng đến khách sạn",
        "romaji": "Welcome to hotel"
    });
    let deserialized: DialogueLine = serde_json::from_value(json_data).unwrap();
    assert_eq!(deserialized.translation_vi, "Chào mừng đến khách sạn");
    assert_eq!(deserialized.phonetic_or_romaji, "Welcome to hotel");
    assert_eq!(deserialized.translation(), "Chào mừng đến khách sạn");
    assert_eq!(deserialized.romaji(), "Welcome to hotel");
}

#[tokio::test]
async fn test_ai_dialogue_endpoint_serializes_translation_and_romaji() {
    let app = setup_test_app();

    let payload = serde_json::json!({
        "language": "ja",
        "profession": "hospitality",
        "difficulty": "beginner",
        "context": "hotel_checkin"
    });

    let req = Request::builder()
        .uri("/api/v1/ai/dialogue")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    let lines = body["lines"].as_array().expect("Expected lines array");
    assert!(!lines.is_empty());

    for line in lines {
        assert!(
            line.get("translation").is_some(),
            "Line must serialize 'translation'"
        );
        assert!(
            line.get("translation_vi").is_some(),
            "Line must serialize 'translation_vi'"
        );
        assert_eq!(line["translation"], line["translation_vi"]);

        assert!(line.get("romaji").is_some(), "Line must serialize 'romaji'");
        assert!(
            line.get("phonetic_or_romaji").is_some(),
            "Line must serialize 'phonetic_or_romaji'"
        );
        assert_eq!(line["romaji"], line["phonetic_or_romaji"]);
    }
}

#[test]
fn test_dialogue_request_turn_count_clamped() {
    use server::models::DialogueRequest;

    let req_high: DialogueRequest = serde_json::from_value(serde_json::json!({
        "language": "ja",
        "turns": 255
    }))
    .unwrap();
    assert_eq!(req_high.turn_count, Some(10));
    assert_eq!(req_high.clamped_turns(), 10);

    let req_low: DialogueRequest = serde_json::from_value(serde_json::json!({
        "language": "ja",
        "turns": 1
    }))
    .unwrap();
    assert_eq!(req_low.turn_count, Some(2));
    assert_eq!(req_low.clamped_turns(), 2);

    let req_normal: DialogueRequest = serde_json::from_value(serde_json::json!({
        "language": "ja",
        "turns": 6
    }))
    .unwrap();
    assert_eq!(req_normal.turn_count, Some(6));
    assert_eq!(req_normal.clamped_turns(), 6);
}

#[tokio::test]
async fn test_ai_roleplay_fallback_disabled_returns_503() {
    let state = AppState {
        lessons: server::data::get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::with_config(server::ai::AIConfig {
            endpoint: "http://127.0.0.1:54321/v1/chat/completions".to_string(),
            provider: server::ai::AIProvider::OpenAICompatible,
            model: "test_model".to_string(),
            timeout_secs: 1,
            connect_timeout_secs: 1,
            fallback_enabled: false,
        })),
        pool: None,
    };
    let app = create_app(state);

    let payload = serde_json::json!({
        "language": "ja",
        "topic": "hotel_checkin",
        "difficulty": "beginner",
        "profession": "hospitality"
    });

    let req = Request::builder()
        .uri("/api/v1/ai/roleplay")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["code"], "AI_SERVICE_UNAVAILABLE");
}

#[tokio::test]
async fn test_sync_push_batch_reviews_and_completed_lessons() {
    let app = setup_test_app();
    let now = chrono::Utc::now();
    let t1 = (now - chrono::Duration::hours(2)).to_rfc3339();
    let t2 = (now - chrono::Duration::hours(1)).to_rfc3339();

    let payload = serde_json::json!({
        "client_id": "test_device_e2e",
        "reviews": [
            {
                "id": "rev_t1_ja_hira_a",
                "item_id": "ja_hira_a",
                "rating": 3,
                "review_time": t1
            },
            {
                "id": "rev_t2_ja_kata_bug",
                "item_id": "ja_kata_bug",
                "rating": 4,
                "review_time": t2
            }
        ],
        "completed_lessons": [
            {
                "lesson_id": "ja_hira_a",
                "completed_at": t1,
                "score": 0.98
            }
        ]
    });

    let req = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(body["synced_reviews"], 2);
    assert_eq!(body["synced_lessons"], 1);

    let synced_ids = body["synced_review_ids"].as_array().unwrap();
    assert_eq!(synced_ids.len(), 2);
    assert!(synced_ids.iter().any(|v| v == "rev_t1_ja_hira_a"));
    assert!(synced_ids.iter().any(|v| v == "rev_t2_ja_kata_bug"));

    let updated_cards = body["updated_cards"].as_array().unwrap();
    assert_eq!(updated_cards.len(), 2);
    assert!(body["timestamp"].is_string());
    assert!(body["server_time"].is_string());
}

#[tokio::test]
async fn test_sync_push_idempotency() {
    let app = setup_test_app();
    let now = chrono::Utc::now().to_rfc3339();

    let payload = serde_json::json!({
        "client_id": "test_device_idempotent",
        "reviews": [
            {
                "review_id": "rev_repeat_1",
                "item_id": "ja_hira_i",
                "rating": 3,
                "review_time": now
            }
        ]
    });

    // First attempt
    let req1 = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();
    let resp1 = app.clone().oneshot(req1).await.unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);

    // Second attempt with exact same payload
    let req2 = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();
    let resp2 = app.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::OK);
}

#[tokio::test]
async fn test_sync_duplicate_review_id_does_not_advance_card() {
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    };
    let app = create_app(state.clone());
    let now = chrono::Utc::now();
    for (rating, review_time) in [(3, now), (1, now + chrono::Duration::seconds(1))] {
        let payload = serde_json::json!({"client_id":"device", "reviews":[{
            "review_id":"same-review", "item_id":"ja_hira_a", "rating":rating,
            "review_time":review_time
        }]});
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/sync")
                    .method("POST")
                    .header("Content-Type", "application/json")
                    .body(Body::from(payload.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }
    let card = state.cards.read().await.get("ja_hira_a").cloned().unwrap();
    assert_eq!(card.reps, 1);
    assert_eq!(card.last_review, now);
}

#[tokio::test]
async fn test_sync_rejects_review_id_reused_for_different_item() {
    let app = setup_test_app();
    for (item_id, expected) in [
        ("ja_hira_a", StatusCode::OK),
        ("ja_hira_i", StatusCode::BAD_REQUEST),
    ] {
        let payload = serde_json::json!({"reviews":[{
            "review_id":"shared-id", "item_id":item_id, "rating":3,
            "review_time":chrono::Utc::now()
        }]});
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/sync")
                    .method("POST")
                    .header("Content-Type", "application/json")
                    .body(Body::from(payload.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
    }
}

#[tokio::test]
async fn test_sync_future_clock_retry_without_id_is_idempotent() {
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    };
    let app = create_app(state.clone());
    let payload = serde_json::json!({"reviews":[{
        "item_id":"ja_hira_a", "rating":3,
        "review_time":chrono::Utc::now() + chrono::Duration::days(1)
    }]});
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/sync")
                    .method("POST")
                    .header("Content-Type", "application/json")
                    .body(Body::from(payload.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert_eq!(state.cards.read().await["ja_hira_a"].reps, 1);
}

#[tokio::test]
async fn test_sync_does_not_ack_failed_postgres_lesson_write() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: Some(pool),
    };
    let payload = serde_json::json!({"client_id":"db_test", "reviews":[],
        "completed_lessons":[{"lesson_id":"missing_lesson_for_sync_test",
        "completed_at":chrono::Utc::now()}]});
    let response = create_app(state)
        .oneshot(
            Request::builder()
                .uri("/api/v1/sync")
                .method("POST")
                .header("Content-Type", "application/json")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
}

#[tokio::test]
async fn test_sync_review_and_log_are_atomic_in_postgres() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let item_id = format!("atomic_{}", chrono::Utc::now().timestamp_micros());
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: Some(pool.clone()),
    };
    let payload = serde_json::json!({"client_id":"atomic_test", "reviews":[{
        "review_id":"x".repeat(65), "item_id":item_id, "rating":3,
        "review_time":chrono::Utc::now()}]});
    let response = create_app(state)
        .oneshot(
            Request::builder()
                .uri("/api/v1/sync")
                .method("POST")
                .header("Content-Type", "application/json")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM fsrs_cards WHERE item_id = $1")
        .bind(&item_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn test_direct_review_does_not_ack_failed_postgres_write() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: Some(pool),
    };
    let payload = serde_json::json!({"item_id":"x".repeat(65),"rating":3});
    let response = create_app(state)
        .oneshot(
            Request::builder()
                .uri("/api/v1/fsrs/review")
                .method("POST")
                .header("Content-Type", "application/json")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
}

#[tokio::test]
async fn test_pull_waits_for_inflight_postgres_review_before_advancing_cursor() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: Some(pool.clone()),
    };
    let item_id = format!("cursor_{}", chrono::Utc::now().timestamp_micros());
    let since = chrono::Utc::now();
    let mut writer = pool.begin().await.unwrap();
    sqlx::query("SELECT pg_advisory_xact_lock(0, 1)")
        .execute(&mut *writer)
        .await
        .unwrap();
    sqlx::query("INSERT INTO lessons (id,language,category,target_text,phonetic_or_kana,meaning_vi,workplace_context,workplace_context_vi) VALUES ($1,'custom','custom',$1,'','','','')")
        .bind(&item_id).execute(&mut *writer).await.unwrap();
    sqlx::query("INSERT INTO fsrs_cards (item_id,state,stability,difficulty,reps,lapses,last_review,next_review,updated_at) VALUES ($1,2,1,5,1,0,clock_timestamp(),clock_timestamp(),clock_timestamp())")
        .bind(&item_id).execute(&mut *writer).await.unwrap();

    let app = create_app(state);
    let request = Request::builder()
        .uri(format!("/api/v1/sync/pull?since={}", since.to_rfc3339()))
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let pull = tokio::spawn(async move { app.oneshot(request).await.unwrap() });
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert!(
        !pull.is_finished(),
        "pull must wait for an in-flight writer"
    );
    writer.commit().await.unwrap();
    let response = pull.await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body: Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body["cards"]
        .as_array()
        .unwrap()
        .iter()
        .any(|card| card["item_id"] == item_id));
}

#[tokio::test]
async fn test_postgres_sync_persists_lww_and_idempotency_across_app_restart() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    let item_id = format!("persist_{}", chrono::Utc::now().timestamp_micros());
    let review_id = format!("review_{}", chrono::Utc::now().timestamp_micros());
    let review_time = chrono::Utc::now() - chrono::Duration::minutes(5);
    let make_app = || {
        create_app(AppState {
            lessons: get_seed_lessons(),
            cards: Arc::new(RwLock::new(HashMap::new())),
            seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
            card_updated_at: Arc::new(RwLock::new(HashMap::new())),
            fsrs: Arc::new(FSRS::default()),
            ai: Arc::new(AIService::new()),
            pool: Some(pool.clone()),
        })
    };
    let send_review = |app: axum::Router, id: String, rating: u8, time| {
        let payload = serde_json::json!({"client_id":"persistence_test", "reviews":[{
            "review_id":id, "item_id":item_id, "rating":rating, "review_time":time
        }]});
        async move {
            let response = app
                .oneshot(
                    Request::builder()
                        .uri("/api/v1/sync")
                        .method("POST")
                        .header("Content-Type", "application/json")
                        .body(Body::from(payload.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
        }
    };
    send_review(make_app(), review_id.clone(), 3, review_time).await;
    send_review(
        make_app(),
        review_id.clone(),
        1,
        review_time + chrono::Duration::seconds(1),
    )
    .await;
    let card: (i32, chrono::DateTime<chrono::Utc>) =
        sqlx::query_as("SELECT reps, last_review FROM fsrs_cards WHERE item_id = $1")
            .bind(&item_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(card.0, 1);
    assert_eq!(card.1.timestamp_micros(), review_time.timestamp_micros());

    send_review(
        make_app(),
        format!("{review_id}_older"),
        1,
        review_time - chrono::Duration::minutes(1),
    )
    .await;
    let card_after: (i32, chrono::DateTime<chrono::Utc>) =
        sqlx::query_as("SELECT reps, last_review FROM fsrs_cards WHERE item_id = $1")
            .bind(&item_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(card_after, card);
}

#[tokio::test]
async fn test_sync_push_last_write_wins_conflict_resolution() {
    let state = AppState {
        lessons: server::data::get_seed_lessons(),
        cards: std::sync::Arc::new(tokio::sync::RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: std::sync::Arc::new(server::fsrs::FSRS::default()),
        ai: std::sync::Arc::new(server::ai::AIService::new()),
        pool: None,
    };
    let app = server::create_app(state.clone());

    let now = chrono::Utc::now();
    let t_late = now.to_rfc3339();
    let t_early = (now - chrono::Duration::hours(3)).to_rfc3339();

    // 1. Submit review with late timestamp (Good = 3)
    let late_payload = serde_json::json!({
        "client_id": "device_b",
        "reviews": [
            {
                "review_id": "rev_late",
                "item_id": "ja_kata_bug",
                "rating": 3,
                "review_time": t_late
            }
        ]
    });
    let req_late = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&late_payload).unwrap()))
        .unwrap();
    let resp_late = app.clone().oneshot(req_late).await.unwrap();
    assert_eq!(resp_late.status(), StatusCode::OK);
    let bytes_late = resp_late.into_body().collect().await.unwrap().to_bytes();
    let body_late: Value = serde_json::from_slice(&bytes_late).unwrap();
    let late_card = &body_late["updated_cards"][0];
    let late_stability = late_card["stability"].as_f64().unwrap();

    // 2. Submit older review (Again = 1 at t_early)
    let early_payload = serde_json::json!({
        "client_id": "device_a",
        "reviews": [
            {
                "review_id": "rev_early",
                "item_id": "ja_kata_bug",
                "rating": 1,
                "review_time": t_early
            }
        ]
    });
    let req_early = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&early_payload).unwrap()))
        .unwrap();
    let resp_early = app.oneshot(req_early).await.unwrap();
    assert_eq!(resp_early.status(), StatusCode::OK);
    let bytes_early = resp_early.into_body().collect().await.unwrap().to_bytes();
    let body_early: Value = serde_json::from_slice(&bytes_early).unwrap();

    // The card returned should still retain late_stability, not regressed to rating 1 (Again)
    let card_after = &body_early["updated_cards"][0];
    assert_eq!(card_after["item_id"], "ja_kata_bug");
    assert_eq!(card_after["stability"].as_f64().unwrap(), late_stability);
}

#[tokio::test]
async fn test_sync_pull_delta_high_water_mark() {
    let state = AppState {
        lessons: server::data::get_seed_lessons(),
        cards: std::sync::Arc::new(tokio::sync::RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: std::sync::Arc::new(server::fsrs::FSRS::default()),
        ai: std::sync::Arc::new(server::ai::AIService::new()),
        pool: None,
    };
    let app = server::create_app(state.clone());

    let now = chrono::Utc::now();
    let t_review = now.to_rfc3339();

    // Push a review
    let push_payload = serde_json::json!({
        "client_id": "device_pull_test",
        "reviews": [
            {
                "id": "rev_pull_test",
                "item_id": "ja_hira_a",
                "rating": 3,
                "review_time": t_review
            }
        ]
    });
    let req_push = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&push_payload).unwrap()))
        .unwrap();
    let resp_push = app.clone().oneshot(req_push).await.unwrap();
    assert_eq!(resp_push.status(), StatusCode::OK);

    // 1. Pull with since in the past
    let since_past = (now - chrono::Duration::hours(1)).to_rfc3339();
    let req_pull_past = Request::builder()
        .uri(format!("/api/v1/sync/pull?since={}", since_past))
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_pull_past = app.clone().oneshot(req_pull_past).await.unwrap();
    assert_eq!(resp_pull_past.status(), StatusCode::OK);
    let bytes_past = resp_pull_past
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let body_past: Value = serde_json::from_slice(&bytes_past).unwrap();
    let cards_past = body_past["cards"].as_array().unwrap();
    assert_eq!(cards_past.len(), 1);
    assert_eq!(cards_past[0]["item_id"], "ja_hira_a");

    // 2. Pull with since in the future
    let since_future = (now + chrono::Duration::hours(1)).to_rfc3339();
    let req_pull_future = Request::builder()
        .uri(format!("/api/v1/sync/pull?since={}", since_future))
        .method("GET")
        .body(Body::empty())
        .unwrap();
    let resp_pull_future = app.oneshot(req_pull_future).await.unwrap();
    assert_eq!(resp_pull_future.status(), StatusCode::OK);
    let bytes_future = resp_pull_future
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let body_future: Value = serde_json::from_slice(&bytes_future).unwrap();
    let cards_future = body_future["cards"].as_array().unwrap();
    assert!(cards_future.is_empty());
}

#[tokio::test]
async fn test_sync_pull_in_memory_includes_late_arriving_old_review() {
    let app = setup_test_app();
    let since = chrono::Utc::now();
    let payload = serde_json::json!({"client_id":"offline_device", "reviews":[{
        "review_id":"late-arrival", "item_id":"ja_hira_a", "rating":3,
        "review_time":since - chrono::Duration::days(1)
    }]});
    let push = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/sync")
                .method("POST")
                .header("Content-Type", "application/json")
                .body(Body::from(payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(push.status(), StatusCode::OK);
    let pull = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/sync/pull?since={}", since.to_rfc3339()))
                .method("GET")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(pull.status(), StatusCode::OK);
    let body: Value =
        serde_json::from_slice(&pull.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["cards"][0]["item_id"], "ja_hira_a");
}

#[tokio::test]
async fn test_sync_push_invalid_rating_returns_bad_request() {
    let app = setup_test_app();
    let now = chrono::Utc::now().to_rfc3339();

    let payload = serde_json::json!({
        "reviews": [
            {
                "item_id": "ja_hira_a",
                "rating": 0,
                "review_time": now
            }
        ]
    });

    let req = Request::builder()
        .uri("/api/v1/sync")
        .method("POST")
        .header("Content-Type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
