use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
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
use crate::models::{LessonItem, ReviewRequest, ReviewResponse, RoleplayRequest};

#[derive(Clone)]
pub struct AppState {
    pub lessons: Vec<LessonItem>,
    pub cards: Arc<RwLock<HashMap<String, FSRSCard>>>,
    pub fsrs: Arc<FSRS>,
    pub ai: Arc<AIService>,
    pub pool: Option<PgPool>,
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

    if let Some(item) = state.lessons.iter().find(|l| l.id == id) {
        Ok(Json(item.clone()))
    } else {
        Err(StatusCode::NOT_FOUND)
    }
}

pub async fn submit_review(
    State(state): State<AppState>,
    Json(req): Json<ReviewRequest>,
) -> Result<Json<ReviewResponse>, StatusCode> {
    let rating = match req.rating {
        1 => Rating::Again,
        2 => Rating::Hard,
        3 => Rating::Good,
        4 => Rating::Easy,
        _ => return Err(StatusCode::BAD_REQUEST),
    };

    let mut existing_card = None;

    if let Some(ref pool) = state.pool {
        match db::fetch_card_by_id(pool, &req.item_id).await {
            Ok(card_opt) => existing_card = card_opt,
            Err(e) => tracing::warn!(
                "DB error in fetch_card_by_id: {}. Falling back to in-memory.",
                e
            ),
        }
    }

    let mut cards = state.cards.write().await;
    let card = match existing_card {
        Some(c) => c,
        None => cards
            .get(&req.item_id)
            .cloned()
            .unwrap_or_else(|| FSRSCard::new(req.item_id.clone())),
    };

    let now = Utc::now();
    let updated = state.fsrs.review(&card, rating, now);
    let interval_days = (updated.next_review - now).num_seconds() as f64 / 86400.0;

    let response = ReviewResponse {
        item_id: updated.item_id.clone(),
        state: format!("{:?}", updated.state),
        reps: updated.reps,
        stability: updated.stability,
        difficulty: updated.difficulty,
        next_review: updated.next_review,
        interval_days,
    };

    if let Some(ref pool) = state.pool {
        if let Err(e) = db::upsert_card(pool, &updated).await {
            tracing::warn!("Failed to persist FSRS card in DB: {}", e);
        }
    }

    cards.insert(req.item_id, updated);

    Ok(Json(response))
}

pub async fn get_due_reviews(State(state): State<AppState>) -> impl IntoResponse {
    let now = Utc::now();
    let mut due_item_ids = Vec::new();
    let mut reviewed_ids = Vec::new();

    if let Some(ref pool) = state.pool {
        if let Ok(due_cards) = db::fetch_due_cards(pool, now).await {
            for card in due_cards {
                due_item_ids.push(card.item_id);
            }
        }
        if let Ok(all_reviewed) = db::fetch_all_reviewed_card_ids(pool).await {
            reviewed_ids = all_reviewed;
        }
    }

    // Synchronize with in-memory store
    {
        let mem_cards = state.cards.read().await;
        for card in mem_cards.values() {
            if !reviewed_ids.contains(&card.item_id) {
                reviewed_ids.push(card.item_id.clone());
            }
            if card.next_review <= now && !due_item_ids.contains(&card.item_id) {
                due_item_ids.push(card.item_id.clone());
            }
        }
    }

    let all_lessons = if let Some(ref pool) = state.pool {
        db::fetch_lessons(pool, None, None)
            .await
            .unwrap_or_else(|_| state.lessons.clone())
    } else {
        state.lessons.clone()
    };

    // Also include new items that haven't been reviewed yet (up to 10 total)
    for lesson in &all_lessons {
        if !reviewed_ids.contains(&lesson.id) && due_item_ids.len() < 10 {
            due_item_ids.push(lesson.id.clone());
        }
    }

    let due_lessons: Vec<LessonItem> = all_lessons
        .into_iter()
        .filter(|l| due_item_ids.contains(&l.id))
        .collect();

    (StatusCode::OK, Json(due_lessons))
}

pub async fn roleplay_chat(
    State(state): State<AppState>,
    Json(req): Json<RoleplayRequest>,
) -> impl IntoResponse {
    let response = state.ai.generate_roleplay(&req).await;
    (StatusCode::OK, Json(response))
}
