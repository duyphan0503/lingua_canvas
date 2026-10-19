use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use tower::ServiceExt;

use server::{ai::AIService, create_app, data::get_seed_lessons, fsrs::FSRS, routes::AppState};

fn app() -> axum::Router {
    create_app(AppState {
        cache: Arc::new(server::redis_cache::RedisCache::default()),
        accounts: Default::default(),
        auth_sessions: Default::default(),
        memory: Default::default(),
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool: None,
    })
}

async fn get(app: axum::Router, uri: &str) -> (StatusCode, String, String) {
    let response = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        content_type,
        String::from_utf8_lossy(&body).into_owned(),
    )
}

#[tokio::test]
async fn prometheus_metrics_are_bounded_and_never_include_request_paths_or_values() {
    let app = app();
    let cache = server::redis_cache::RedisCache::new(None);
    assert!(!cache.ping().await);
    server::metrics::record_ai_outcome(server::metrics::AiOutcome::CuratedFallback);
    assert_eq!(get(app.clone(), "/api/v1/health").await.0, StatusCode::OK);
    assert_eq!(
        get(
            app.clone(),
            "/api/v1/lessons/private-word-should-not-leak?token=secret"
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (status, content_type, metrics) = get(app, "/metrics").await;
    assert_eq!(status, StatusCode::OK);
    assert!(content_type.starts_with("text/plain; version=0.0.4"));
    assert!(metrics.contains("lingua_http_requests_total{route=\"health\",status_class=\"2xx\"}"));
    assert!(
        metrics.contains("lingua_http_requests_total{route=\"curriculum\",status_class=\"4xx\"}")
    );
    assert!(metrics.contains("lingua_http_request_duration_seconds_bucket"));
    assert!(metrics.contains("lingua_cache_operations_total{outcome=\"memory_fallback\"}"));
    assert!(metrics.contains("lingua_ai_completions_total{outcome=\"curated_fallback\"}"));
    assert!(!metrics.contains("private-word-should-not-leak"));
    assert!(!metrics.contains("token=secret"));
}
