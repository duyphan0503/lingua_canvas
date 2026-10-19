use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::Path;
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

    let database_url = match database_url_from_config(
        std::env::var("DATABASE_URL").ok(),
        std::env::var("DATABASE_URL_FILE").ok(),
    ) {
        Ok(value) => value,
        Err(error) => {
            tracing::error!("Unable to read DATABASE_URL_FILE: {error}");
            std::process::exit(2);
        }
    };
    let pool = init_pool(database_url.as_deref()).await;

    let seed_lessons = get_seed_lessons();

    if let Some(ref p) = pool {
        if let Err(e) = seed_lessons_if_empty(p, &seed_lessons).await {
            tracing::warn!("Failed to seed initial lessons in PostgreSQL: {}", e);
        }
    }

    let state = AppState {
        cache: Arc::new(server::redis_cache::RedisCache::default()),
        accounts: Default::default(),
        auth_sessions: Default::default(),
        memory: Default::default(),
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

    if let Err(e) = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    {
        tracing::error!("Server error: {}", e);
    }
}

fn database_url_from_config(
    inline: Option<String>,
    file: Option<String>,
) -> std::io::Result<Option<String>> {
    if inline.is_some() {
        return Ok(inline);
    }
    file.map(|path| std::fs::read_to_string(Path::new(&path)).map(|value| value.trim().to_owned()))
        .transpose()
}

#[cfg(test)]
mod config_tests {
    use super::database_url_from_config;
    use std::fs;

    #[test]
    fn database_url_file_is_trimmed_and_inline_value_takes_precedence() {
        let path = std::env::temp_dir().join(format!(
            "lingua-database-url-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        fs::write(&path, "  postgres://secret@db/lingua\n").unwrap();
        let path = path.to_string_lossy().into_owned();
        assert_eq!(
            database_url_from_config(None, Some(path.clone())).unwrap(),
            Some("postgres://secret@db/lingua".to_owned())
        );
        assert_eq!(
            database_url_from_config(Some("postgres://inline/db".to_owned()), Some(path.clone()))
                .unwrap(),
            Some("postgres://inline/db".to_owned())
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn missing_configured_database_secret_is_an_error() {
        assert!(
            database_url_from_config(None, Some("/missing/lingua-database-url".into())).is_err()
        );
    }
}
