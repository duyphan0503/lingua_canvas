use axum::{
    routing::{get, post},
    Router,
};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod ai;
mod data;
mod fsrs;
mod models;
mod routes;

use ai::AIService;
use data::get_seed_lessons;
use fsrs::FSRS;
use routes::AppState;

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    tracing::info!("Starting LinguaCanvas Server with FSRS & Local AI support...");

    let state = AppState {
        lessons: get_seed_lessons(),
        cards: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
    };

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/api/v1/health", get(routes::health_check))
        .route("/api/v1/lessons", get(routes::list_lessons))
        .route("/api/v1/lessons/:id", get(routes::get_lesson))
        .route("/api/v1/fsrs/review", post(routes::submit_review))
        .route("/api/v1/fsrs/due", get(routes::get_due_reviews))
        .route("/api/v1/ai/roleplay", post(routes::roleplay_chat))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    tracing::info!("LinguaCanvas server listening on http://{}", addr);

    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!("Failed to bind to {}: {}", addr, e);
            return;
        }
    };

    if let Err(e) = axum::serve(listener, app).await {
        tracing::error!("Server error: {}", e);
    }
}
