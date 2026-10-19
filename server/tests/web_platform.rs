use axum::{body::Body, http::Request, Router};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use server::{ai::AIService, fsrs::FSRS, routes::AppState};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use tower::ServiceExt;
fn state() -> AppState {
    AppState {
        cache: Arc::new(server::redis_cache::RedisCache::default()),
        accounts: Default::default(),
        auth_sessions: Default::default(),
        memory: Default::default(),
        lessons: server::data::get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    }
}
fn app() -> Router {
    server::create_app(state())
}
async fn request(
    app: &Router,
    path: &str,
    body: Option<Value>,
    token: Option<&str>,
) -> (u16, Value, Option<String>) {
    let mut r = Request::builder()
        .uri(path)
        .method(if body.is_some() { "POST" } else { "GET" })
        .header("content-type", "application/json");
    if let Some(t) = token {
        r = r.header("X-Sync-Token", t)
    }
    let res = app
        .clone()
        .oneshot(
            r.body(Body::from(body.map(|x| x.to_string()).unwrap_or_default()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = res.status().as_u16();
    let cache = res
        .headers()
        .get("x-cache")
        .map(|x| x.to_str().unwrap().to_owned());
    let b = res.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&b).unwrap_or(Value::Null),
        cache,
    )
}
#[tokio::test]
async fn web_device_pulls_android_reviews_and_isolates_accounts() {
    let a = app();
    let (s, one, _) = request(
        &a,
        "/api/v1/auth/register",
        Some(json!({"username":"alice","pin":"123456","device_id":"phone","platform":"android"})),
        None,
    )
    .await;
    assert_eq!(s, 201);
    let token = one["sync_token"].as_str().unwrap();
    let (s, two, _) = request(
        &a,
        "/api/v1/auth/register",
        Some(json!({"username":"bobby","pin":"654321","device_id":"phone","platform":"android"})),
        None,
    )
    .await;
    assert_eq!(s, 201);
    let token2 = two["sync_token"].as_str().unwrap();
    let review = json!({"reviews":[{"review_id":"same","item_id":"ja_hira_a","rating":3,"review_time":chrono::Utc::now()},{"review_id":"second","item_id":"ja_hira_i","rating":4,"review_time":chrono::Utc::now()}],"completed_lessons":[{"lesson_id":"ja_hira_a","completed_at":chrono::Utc::now()}]});
    assert_eq!(
        request(&a, "/api/v1/sync", Some(review.clone()), Some(token))
            .await
            .0,
        200
    );
    let empty = request(&a, "/api/v1/sync/pull?since_seq=0", None, Some(token2)).await;
    assert_eq!(empty.1["cards"].as_array().unwrap().len(), 0);
    assert_eq!(
        request(&a, "/api/v1/sync", Some(review), Some(token2))
            .await
            .0,
        200
    );
    let (s, login, _) = request(
        &a,
        "/api/v1/auth/login",
        Some(json!({"sync_token":token,"device_id":"desktop","platform":"web"})),
        None,
    )
    .await;
    assert_eq!(s, 200);
    assert_eq!(login["devices"].as_array().unwrap().len(), 2);
    let (s, pull, _) = request(&a, "/api/v1/sync/pull?since_seq=0", None, Some(token)).await;
    assert_eq!(s, 200);
    assert_eq!(pull["cards"].as_array().unwrap().len(), 2);
    assert_eq!(pull["cards"][0]["reps"], 1);
    assert_eq!(pull["completed_lessons"].as_array().unwrap().len(), 1);
    let listed = request(&a, "/api/v1/auth/devices", None, Some(token2)).await;
    assert_eq!(listed.0, 200);
    assert_eq!(listed.1["devices"].as_array().unwrap().len(), 1);
    assert_eq!(listed.1["devices"][0]["device_id"], "phone");
    assert_eq!(listed.1["devices"][0]["platform"], "android");
    let (s, good_login, _) = request(
        &a,
        "/api/v1/auth/login",
        Some(json!({"username":"alice","pin":"123456","device_id":"desktop","platform":"web"})),
        None,
    )
    .await;
    assert_eq!(s, 200);
    assert_eq!(good_login["user_id"], one["user_id"]);
    let seq = pull["latest_sync_seq"].as_i64().unwrap();
    assert!(seq > 0);
    assert_eq!(
        request(
            &a,
            &format!("/api/v1/sync/pull?since_seq={seq}"),
            None,
            Some(token)
        )
        .await
        .1["cards"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        request(&a, "/api/v1/sync/pull", None, None).await.1["cards"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        request(
            &a,
            "/api/v1/auth/login",
            Some(json!({"username":"alice","pin":"000000"})),
            None
        )
        .await
        .0,
        401
    );
}

#[tokio::test]
async fn browser_preflight_allows_auth_headers_and_exposes_cache() {
    let response = app()
        .oneshot(
            Request::builder()
                .method("OPTIONS")
                .uri("/api/v1/sync")
                .header("origin", "https://learn.example")
                .header("access-control-request-method", "POST")
                .header(
                    "access-control-request-headers",
                    "x-sync-token,content-type,authorization",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers()["access-control-allow-headers"],
        "x-sync-token,content-type,authorization"
    );
    let response = app()
        .oneshot(
            Request::builder()
                .uri("/api/v1/health")
                .header("origin", "https://learn.example")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        response.headers()["access-control-expose-headers"],
        "x-cache"
    );
}
