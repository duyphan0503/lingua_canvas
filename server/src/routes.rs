use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::ai::AIService;
use crate::fsrs::{FSRSCard, Rating, FSRS};
use crate::models::{LessonItem, ReviewRequest, ReviewResponse, RoleplayRequest};

#[derive(Clone)]
pub struct AppState {
    pub lessons: Vec<LessonItem>,
    pub cards: Arc<RwLock<HashMap<String, FSRSCard>>>,
    pub fsrs: Arc<FSRS>,
    pub ai: Arc<AIService>,
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

    let mut cards = state.cards.write().await;
    let card = cards
        .entry(req.item_id.clone())
        .or_insert_with(|| FSRSCard::new(req.item_id.clone()));

    let now = Utc::now();
    let updated = state.fsrs.review(card, rating, now);
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

    *card = updated;

    Ok(Json(response))
}

pub async fn get_due_reviews(State(state): State<AppState>) -> impl IntoResponse {
    let cards = state.cards.read().await;
    let now = Utc::now();

    let mut due_item_ids = Vec::new();
    for card in cards.values() {
        if card.next_review <= now {
            due_item_ids.push(card.item_id.clone());
        }
    }

    // Also include new items that haven't been reviewed yet
    for lesson in &state.lessons {
        if !cards.contains_key(&lesson.id) && due_item_ids.len() < 10 {
            due_item_ids.push(lesson.id.clone());
        }
    }

    let due_lessons: Vec<LessonItem> = state
        .lessons
        .iter()
        .filter(|l| due_item_ids.contains(&l.id))
        .cloned()
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
