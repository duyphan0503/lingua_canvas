pub mod ai;
pub mod data;
pub mod db;
pub mod fsrs;
pub mod models;
pub mod routes;

use axum::{
    routing::{get, post},
    Router,
};
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

use routes::AppState;

pub fn create_app(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/api/v1/health", get(routes::health_check))
        .route("/api/v1/lessons", get(routes::list_lessons))
        .route("/api/v1/lessons/:id", get(routes::get_lesson))
        .route("/api/v1/fsrs/review", post(routes::submit_review))
        .route("/api/v1/fsrs/due", get(routes::get_due_reviews))
        .route("/api/v1/ai/roleplay", post(routes::roleplay_chat))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
