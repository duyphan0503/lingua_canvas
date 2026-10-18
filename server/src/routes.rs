use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use serde::Deserialize;
use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::ai::AIService;
use crate::db;
use crate::fsrs::{FSRSCard, Rating, FSRS};
use crate::models::{DialogueRequest, LessonItem, ReviewRequest, ReviewResponse, RoleplayRequest};

pub mod auth;
pub mod sync;
pub use sync::{pull_sync, push_sync};

#[derive(Clone)]
pub struct AppState {
    pub lessons: Vec<LessonItem>,
    pub cards: Arc<RwLock<HashMap<String, FSRSCard>>>,
    pub seen_review_ids: Arc<RwLock<HashMap<String, String>>>,
    pub card_updated_at: Arc<RwLock<HashMap<String, chrono::DateTime<Utc>>>>,
    pub fsrs: Arc<FSRS>,
    pub ai: Arc<AIService>,
    pub pool: Option<PgPool>,
    pub cache: Arc<crate::redis_cache::RedisCache>,
    pub accounts: auth::Accounts,
    pub memory: Arc<sync::MemorySync>,
}

#[derive(Debug, Deserialize)]
pub struct LessonQuery {
    pub language: Option<String>,
    pub category: Option<String>,
}

pub async fn health_check() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "status": "healthy",
            "service": "lingua_canvas_server",
            "version": "0.1.0"
        })),
    )
}

pub async fn list_lessons(
    State(state): State<AppState>,
    Query(query): Query<LessonQuery>,
) -> impl IntoResponse {
    if let Some(ref pool) = state.pool {
        if let Ok(db_lessons) =
            db::fetch_lessons(pool, query.language.as_deref(), query.category.as_deref()).await
        {
            return (StatusCode::OK, Json(db_lessons));
        }
    }

    let filtered: Vec<LessonItem> = state
        .lessons
        .iter()
        .filter(|item| {
            if item.category == "custom" {
                return false;
            }
            if let Some(ref lang) = query.language {
                if item.language != *lang {
                    return false;
                }
            }
            if let Some(ref cat) = query.category {
                if item.category != *cat {
                    return false;
                }
            }
            true
        })
        .cloned()
        .collect();

    (StatusCode::OK, Json(filtered))
}

pub async fn get_lesson(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<LessonItem>, StatusCode> {
    if let Some(ref pool) = state.pool {
        match db::fetch_lesson_by_id(pool, &id).await {
            Ok(Some(item)) => return Ok(Json(item)),
            Ok(None) => {}
            Err(e) => {
                tracing::warn!("Database error in get_lesson: {}. Falling back.", e);
            }
        }
    }

    if let Some(item) = state
        .lessons
        .iter()
        .find(|l| l.id == id && l.category != "custom")
    {
        Ok(Json(item.clone()))
    } else {
        Err(StatusCode::NOT_FOUND)
    }
}

pub async fn submit_review(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(identity): Query<auth::Identity>,
    Json(req): Json<ReviewRequest>,
) -> Result<Json<ReviewResponse>, StatusCode> {
    let user = auth::resolve(
        &state,
        &headers,
        &auth::Identity {
            user_id: req.user_id,
            sync_token: req.sync_token,
        }
        .merge(identity)?,
    )
    .await?;
    if req.item_id.contains('\0') {
        return Err(StatusCode::BAD_REQUEST);
    }
    let rating = match req.rating {
        1 => Rating::Again,
        2 => Rating::Hard,
        3 => Rating::Good,
        4 => Rating::Easy,
        _ => return Err(StatusCode::BAD_REQUEST),
    };
    let lock = state.memory.user_lock(&user).await;
    let _guard = if state.pool.is_none() {
        Some(lock.lock().await)
    } else {
        None
    };
    let mut tx = if let Some(p) = &state.pool {
        let mut tx = p
            .begin()
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        sync::writer_lock(&mut tx, &user).await?;
        sync::card_lock(&mut tx, &user, &req.item_id).await?;
        Some(tx)
    } else {
        None
    };
    let card = if let Some(tx) = &mut tx {
        db::fetch_card_by_id(tx, &req.item_id, &user)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    } else {
        state
            .cards
            .read()
            .await
            .get(&sync::key(&user, &req.item_id))
            .cloned()
    }
    .unwrap_or_else(|| FSRSCard::new(req.item_id.clone()));
    let now = Utc::now();
    let updated = state.fsrs.review(&card, rating, now);
    if let Some(tx) = &mut tx {
        db::upsert_card(tx, &updated, &user)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }
    if let Some(tx) = tx {
        tx.commit()
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    } else {
        sync::record_memory_card(&state, &user, updated.clone()).await;
    }
    Ok(Json(ReviewResponse {
        item_id: updated.item_id,
        state: format!("{:?}", updated.state),
        reps: updated.reps,
        stability: updated.stability,
        difficulty: updated.difficulty,
        next_review: updated.next_review,
        interval_days: (updated.next_review - now).num_seconds() as f64 / 86400.0,
    }))
}
pub async fn get_due_reviews(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(identity): Query<auth::Identity>,
) -> Result<Json<Vec<LessonItem>>, StatusCode> {
    let user = auth::resolve(&state, &headers, &identity).await?;
    let now = Utc::now();
    let mut due = Vec::new();
    let mut reviewed = Vec::new();
    if let Some(p) = &state.pool {
        due = db::fetch_due_cards(p, now, &user)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .into_iter()
            .map(|c| c.item_id)
            .collect();
        reviewed = db::fetch_all_reviewed_card_ids(p, &user)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    } else {
        for (k, card) in state.cards.read().await.iter() {
            if *k == sync::key(&user, &card.item_id) {
                reviewed.push(card.item_id.clone());
                if card.next_review <= now {
                    due.push(card.item_id.clone());
                }
            }
        }
    }
    let all = if let Some(p) = &state.pool {
        db::fetch_lessons(p, None, None)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    } else {
        state
            .lessons
            .iter()
            .filter(|l| l.category != "custom")
            .cloned()
            .collect()
    };
    for item in &all {
        if !reviewed.contains(&item.id) && due.len() < 10 {
            due.push(item.id.clone());
        }
    }
    Ok(Json(
        all.into_iter()
            .filter(|item| due.contains(&item.id))
            .collect(),
    ))
}
async fn cached_ai(
    state: &AppState,
    user: &str,
    key: &str,
) -> Result<Option<serde_json::Value>, StatusCode> {
    // Count cached requests too. Each account has an independent budget, shared across both AI routes.
    if !state
        .cache
        .check_rate_limit(&format!("ai:{user}"), 120, 60)
        .await
    {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    Ok(state
        .cache
        .get(key)
        .await
        .and_then(|s| serde_json::from_str(&s).ok()))
}
pub async fn roleplay_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(identity): Query<auth::Identity>,
    Json(req): Json<RoleplayRequest>,
) -> axum::response::Response {
    let user = match auth::resolve(&state, &headers, &identity).await {
        Ok(u) => u,
        Err(e) => return e.into_response(),
    };
    let key = format!(
        "ai:roleplay:{}",
        serde_json::json!([
            user,
            req.target_language,
            req.profession,
            req.user_level,
            req.topic,
            req.user_message
        ])
    );
    match cached_ai(&state, &user, &key).await {
        Ok(Some(v)) => return ([("X-Cache", "HIT")], Json(v)).into_response(),
        Err(e) => return e.into_response(),
        _ => {}
    }
    match state.ai.generate_roleplay(&req).await {
        Ok(response) => {
            let value = serde_json::to_value(response).unwrap();
            state.cache.set_ex(&key, &value.to_string(), 3600).await;
            ([("X-Cache", "MISS")], Json(value)).into_response()
        }
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({"error":e.to_string(),"code":"AI_SERVICE_UNAVAILABLE"})),
        )
            .into_response(),
    }
}
pub async fn generate_dialogue(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(identity): Query<auth::Identity>,
    Json(req): Json<DialogueRequest>,
) -> axum::response::Response {
    let user = match auth::resolve(&state, &headers, &identity).await {
        Ok(u) => u,
        Err(e) => return e.into_response(),
    };
    let key = format!(
        "ai:dialogue:{}",
        serde_json::json!([
            user,
            req.target_language,
            req.profession,
            req.difficulty_level,
            req.topic,
            req.clamped_turns()
        ])
    );
    match cached_ai(&state, &user, &key).await {
        Ok(Some(v)) => return ([("X-Cache", "HIT")], Json(v)).into_response(),
        Err(e) => return e.into_response(),
        _ => {}
    }
    match state.ai.generate_dialogue(&req).await {
        Ok(response) => {
            let value = serde_json::to_value(response).unwrap();
            state.cache.set_ex(&key, &value.to_string(), 3600).await;
            ([("X-Cache", "MISS")], Json(value)).into_response()
        }
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({"error":e.to_string(),"code":"AI_SERVICE_UNAVAILABLE"})),
        )
            .into_response(),
    }
}
