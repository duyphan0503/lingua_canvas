use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use server::{
    ai::AIService,
    create_app,
    data::get_seed_lessons,
    db::{init_pool, seed_lessons_if_empty},
    fsrs::FSRS,
    routes::AppState,
};

#[tokio::main]
async fn main() {
    // Load .env if present
    dotenvy::dotenv().ok();

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    tracing::info!("Starting LinguaCanvas Server with FSRS & Local AI support...");

    let database_url = std::env::var("DATABASE_URL").ok();
    let pool = init_pool(database_url.as_deref()).await;

    let seed_lessons = get_seed_lessons();

    if let Some(ref p) = pool {
        if let Err(e) = seed_lessons_if_empty(p, &seed_lessons).await {
            tracing::warn!("Failed to seed initial lessons in PostgreSQL: {}", e);
        }
    }

    let state = AppState {
        lessons: seed_lessons,
        cards: Arc::new(RwLock::new(HashMap::new())),
        seen_review_ids: Arc::new(RwLock::new(HashMap::new())),
        card_updated_at: Arc::new(RwLock::new(HashMap::new())),
        fsrs: Arc::new(FSRS::default()),
        ai: Arc::new(AIService::new()),
        pool,
    };

    let app = create_app(state);

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
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
