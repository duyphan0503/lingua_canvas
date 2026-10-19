pub mod ai;
pub mod data;
pub mod db;
pub mod fsrs;
pub mod metrics;
pub mod models;
pub mod pin;
pub mod redis_cache;
pub mod routes;

use axum::{
    middleware,
    routing::{delete, get, post},
    Router,
};
use tower_http::cors::{AllowHeaders, Any, CorsLayer};
use tower_http::trace::TraceLayer;

use routes::AppState;

pub fn create_app(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(AllowHeaders::mirror_request())
        .expose_headers([axum::http::HeaderName::from_static("x-cache")]);

    Router::new()
        .route("/api/v1/auth/register", post(routes::auth::register))
        .route("/api/v1/auth/login", post(routes::auth::login))
        .route("/api/v1/auth/devices", get(routes::auth::list_devices))
        .route(
            "/api/v1/auth/devices/:id",
            delete(routes::auth::revoke_device),
        )
        .route(
            "/api/v1/auth/token/rotate",
            post(routes::auth::rotate_token),
        )
        .route("/api/v1/auth/pin/change", post(routes::auth::change_pin))
        .route("/api/v1/health", get(routes::health_check))
        .route("/metrics", get(metrics::prometheus))
        .route("/api/v1/lessons", get(routes::list_lessons))
        .route("/api/v1/lessons/:id", get(routes::get_lesson))
        .route("/api/v1/fsrs/review", post(routes::submit_review))
        .route("/api/v1/fsrs/due", get(routes::get_due_reviews))
        .route("/api/v1/ai/roleplay", post(routes::roleplay_chat))
        .route("/api/v1/ai/dialogue", post(routes::generate_dialogue))
        .route("/api/v1/sync", post(routes::push_sync))
        .route("/api/v1/sync/pull", get(routes::pull_sync))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .layer(middleware::from_fn(metrics::record_request))
        .with_state(state)
}
