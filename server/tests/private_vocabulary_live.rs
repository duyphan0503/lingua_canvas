use axum::{body::Body, http::Request, Router};
use chrono::{Duration, Utc};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use server::{ai::AIService, fsrs::FSRS, routes::AppState};
use std::sync::Arc;
use tower::ServiceExt;

fn app(pool: sqlx::PgPool) -> Router {
    server::create_app(AppState {
        cache: Arc::new(server::redis_cache::RedisCache::new(None)),
        accounts: Default::default(),
        auth_sessions: Default::default(),
        memory: Default::default(),
        lessons: server::data::get_seed_lessons(),
        cards: Default::default(),
        seen_review_ids: Default::default(),
        card_updated_at: Default::default(),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: Some(pool),
    })
}

async fn request(
    app: &Router,
    path: &str,
    body: Option<Value>,
    token: Option<&str>,
) -> (u16, Value) {
    let mut builder = Request::builder()
        .uri(path)
        .method(if body.is_some() { "POST" } else { "GET" })
        .header("content-type", "application/json");
    if let Some(token) = token {
        builder = builder.header("X-Sync-Token", token);
    }
    let response = app
        .clone()
        .oneshot(
            builder
                .body(Body::from(body.map(|v| v.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status().as_u16();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn register(app: &Router, username: &str, pin: &str) -> String {
    let (status, body) = request(
        app,
        "/api/v1/auth/register",
        Some(json!({"username":username,"pin":pin})),
        None,
    )
    .await;
    assert_eq!(status, 201, "{body}");
    body["sync_token"].as_str().unwrap().to_owned()
}

fn lesson(id: &str, word: &str, meaning: &str) -> Value {
    json!({
        "id": id,
        "language": "ja",
        "category": "custom",
        "target_text": word,
        "phonetic_or_kana": "よやく",
        "meaning_vi": meaning,
        "workplace_context": "明日の予約を確認します。",
        "workplace_context_vi": "Tôi sẽ xác nhận lịch hẹn ngày mai.",
        "stroke_order_hints": ["Đọc câu", "Xác nhận thông tin"],
        "difficulty_level": 3
    })
}

#[tokio::test]
#[ignore = "requires the explicit disposable PostgreSQL live-test runner"]
async fn live_private_http_contract_requires_a_disposable_postgres_database() {
    let database_url = std::env::var("TEST_DATABASE_URL")
        .expect("run through tests/private_vocabulary/run_live_tests.sh");
    let (scheme, remainder) = database_url
        .split_once("://")
        .expect("TEST_DATABASE_URL must be a PostgreSQL URL");
    assert!(scheme == "postgres" || scheme == "postgresql");
    let (authority, _) = remainder
        .split_once('/')
        .expect("TEST_DATABASE_URL must name a database");
    let host_port = authority.rsplit('@').next().unwrap_or_default();
    let host = host_port
        .strip_prefix('[')
        .and_then(|value| value.split(']').next())
        .unwrap_or_else(|| host_port.split(':').next().unwrap_or_default());
    assert!(
        host == "localhost" || host == "127.0.0.1" || host == "::1",
        "refusing non-loopback PostgreSQL host"
    );
    let database_name = database_url
        .split_once("://")
        .and_then(|(_, remainder)| remainder.split_once('/'))
        .map(|(_, path)| path.split('?').next().unwrap_or_default())
        .unwrap_or_default();
    assert!(
        database_name.starts_with("lingua_private_test_"),
        "refusing database outside the lingua_private_test_ disposable prefix"
    );

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(8)
        .connect(&database_url)
        .await
        .expect("connect to disposable PostgreSQL");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("run all server migrations");
    server::db::seed_lessons_if_empty(&pool, &server::data::get_seed_lessons())
        .await
        .expect("seed the public curriculum");
    let app = app(pool.clone());
    let suffix = Utc::now().timestamp_micros().to_string();
    let owner = register(&app, &format!("owner{suffix}"), "123456").await;
    let other = register(&app, &format!("other{suffix}"), "654321").await;
    let word_id = format!("custom_live_{suffix}");
    let first = lesson(&word_id, "予約確認", "Riêng tư");
    let created = request(
        &app,
        "/api/v1/sync",
        Some(json!({"custom_lesson_mutations":[{
            "mutation_id":"create",
            "base_revision":0,
            "lesson":first,
            "deleted":false
        }]})),
        Some(&owner),
    )
    .await;
    assert_eq!(created.0, 200, "{}", created.1);
    assert_eq!(created.1["custom_lesson_acks"][0]["state"]["revision"], 1);

    let owner_pull = request(&app, "/api/v1/sync/pull?since_seq=0", None, Some(&owner)).await;
    assert_eq!(owner_pull.0, 200);
    assert_eq!(
        owner_pull.1["private_lessons"][0]["lesson"]["meaning_vi"],
        "Riêng tư"
    );
    let other_pull = request(&app, "/api/v1/sync/pull?since_seq=0", None, Some(&other)).await;
    assert_eq!(other_pull.1["private_lessons"], json!([]));

    let public = request(&app, "/api/v1/lessons", None, None).await;
    assert_eq!(public.1.as_array().unwrap().len(), 355);
    assert!(!public
        .1
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["id"] == word_id));
    assert_eq!(
        request(&app, &format!("/api/v1/lessons/{word_id}"), None, None)
            .await
            .0,
        404
    );

    let stale = request(
        &app,
        "/api/v1/sync",
        Some(json!({"custom_lesson_mutations":[{
            "mutation_id":"stale",
            "base_revision":0,
            "lesson":lesson(&word_id,"予約変更","Bản cũ"),
            "deleted":false
        }]})),
        Some(&owner),
    )
    .await;
    assert_eq!(
        stale.1["custom_lesson_conflicts"][0]["server"]["revision"],
        1
    );
    let resolved = request(
        &app,
        "/api/v1/sync",
        Some(json!({"custom_lesson_mutations":[{
            "mutation_id":"keep-local",
            "base_revision":1,
            "lesson":lesson(&word_id,"予約変更","Bản mới"),
            "deleted":false
        }]})),
        Some(&owner),
    )
    .await;
    assert_eq!(resolved.1["custom_lesson_acks"][0]["state"]["revision"], 2);

    let snapshot_time = Utc::now() - Duration::hours(1);
    let import = json!({"progress_imports":[{
        "mutation_id":"backup-import",
        "cards":[{
            "item_id":word_id,
            "state":"Review",
            "stability":12.5,
            "difficulty":4.5,
            "reps":7,
            "lapses":1,
            "last_review":snapshot_time,
            "next_review":snapshot_time+Duration::days(12),
            "updated_at":snapshot_time
        }],
        "completed_lessons":[{
            "lesson_id":word_id,
            "completed_at":snapshot_time,
            "score":0.9
        }]
    }]});
    for _ in 0..2 {
        let response = request(&app, "/api/v1/sync", Some(import.clone()), Some(&owner)).await;
        assert_eq!(response.0, 200, "{}", response.1);
        assert_eq!(response.1["progress_import_acks"], json!(["backup-import"]));
    }
    let card: (i32,) = sqlx::query_as(
        "SELECT reps FROM fsrs_cards WHERE user_id=(SELECT user_id FROM auth_sessions WHERE token_hash=encode(sha256(convert_to($1,'UTF8')),'hex')) AND item_id=$2",
    )
    .bind(&owner)
    .bind(&word_id)
    .fetch_one(&pool)
    .await
    .expect("read imported card");
    assert_eq!(card.0, 7, "reimport must not replay or increment FSRS");

    let deleted = request(
        &app,
        "/api/v1/sync",
        Some(json!({"custom_lesson_mutations":[{
            "mutation_id":"delete",
            "base_revision":2,
            "lesson":lesson(&word_id,"予約変更","Bản mới"),
            "deleted":true
        }]})),
        Some(&owner),
    )
    .await;
    assert_eq!(deleted.1["custom_lesson_acks"][0]["state"]["deleted"], true);
    let tombstone = request(&app, "/api/v1/sync/pull?since_seq=0", None, Some(&owner)).await;
    assert_eq!(
        tombstone.1["private_lessons"]
            .as_array()
            .unwrap()
            .iter()
            .find(|state| state["lesson"]["id"] == word_id)
            .unwrap()["deleted"],
        true
    );
}
