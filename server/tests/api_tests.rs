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
        "user_level": "intermediate",
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
