use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use chrono::{Duration, Utc};
use std::collections::HashMap;

use crate::db::{DbFsrsCard, DbLessonItem};
use crate::fsrs::{FSRSCard, Rating};
use crate::models::{
    FsrsCardDto, LessonItem, SyncPullQuery, SyncPullResponse, SyncPushRequest, SyncPushResponse,
};
use crate::routes::AppState;

/// POST /api/v1/sync
/// Handles offline batch review synchronization and completed lesson ingestion.
/// Evaluates client review timestamps, executes FSRS interval updates using
/// Last-Write-Wins (LWW) conflict resolution, and records review logs idempotently.
pub async fn push_sync(
    State(state): State<AppState>,
    Json(req): Json<SyncPushRequest>,
) -> Result<Json<SyncPushResponse>, StatusCode> {
    let now = Utc::now();
    let max_future = now + Duration::minutes(5);
    let client_id = req
        .client_id
        .unwrap_or_else(|| "default_device".to_string());

    let mut synced_review_ids = Vec::new();
    let mut updated_cards_map: HashMap<String, FsrsCardDto> = HashMap::new();

    // Reject the whole batch before applying any review.
    if req.reviews.iter().any(|rev| !(1..=4).contains(&rev.rating)) {
        return Err(StatusCode::BAD_REQUEST);
    }

    // 1. Process batch reviews
    for rev in req.reviews {
        let rating = match rev.rating {
            1 => Rating::Again,
            2 => Rating::Hard,
            3 => Rating::Good,
            4 => Rating::Easy,
            _ => return Err(StatusCode::BAD_REQUEST),
        };

        // Clamp clock skew: if client timestamp is > 5 minutes in future, clamp to now
        let review_time = if rev.review_time > max_future {
            now
        } else {
            rev.review_time
        };

        let review_id = rev.review_id.unwrap_or_else(|| {
            format!("rev_{}_{}", rev.review_time.timestamp_millis(), rev.item_id)
        });

        let mut seen_review_ids = state.seen_review_ids.write().await;
        let mut transaction = if let Some(ref pool) = state.pool {
            let mut tx = pool
                .begin()
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            sqlx::query("SELECT pg_advisory_xact_lock(0, 1)")
                .execute(&mut *tx)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            sqlx::query("SELECT pg_advisory_xact_lock(1, hashtext($1))")
                .bind(&review_id)
                .execute(&mut *tx)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            sqlx::query("SELECT pg_advisory_xact_lock(2, hashtext($1))")
                .bind(&rev.item_id)
                .execute(&mut *tx)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            Some(tx)
        } else {
            None
        };
        let already_seen = if let Some(ref mut tx) = transaction {
            sqlx::query_scalar::<_, String>("SELECT item_id FROM review_logs WHERE id = $1")
                .bind(&review_id)
                .fetch_optional(&mut **tx)
                .await
                .map_err(|e| {
                    tracing::warn!("Failed to check review id: {}", e);
                    StatusCode::INTERNAL_SERVER_ERROR
                })?
                .map(|item_id| {
                    if item_id != rev.item_id {
                        Err(StatusCode::BAD_REQUEST)
                    } else {
                        Ok(true)
                    }
                })
                .transpose()?
                .unwrap_or(false)
        } else {
            match seen_review_ids.get(&review_id) {
                Some(item_id) if item_id != &rev.item_id => return Err(StatusCode::BAD_REQUEST),
                Some(_) => true,
                None => false,
            }
        };

        if already_seen {
            let card = if let Some(ref mut tx) = transaction {
                let row = sqlx::query_as::<_, DbFsrsCard>(
                    "SELECT item_id, state, stability, difficulty, reps, lapses, last_review, next_review, updated_at FROM fsrs_cards WHERE item_id = $1",
                )
                .bind(&rev.item_id)
                .fetch_optional(&mut **tx)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
                row.map(FSRSCard::from)
            } else {
                state.cards.read().await.get(&rev.item_id).cloned()
            };
            if let Some(card) = card {
                updated_cards_map.insert(
                    rev.item_id.clone(),
                    FsrsCardDto::from_card(&card, Some(now)),
                );
            }
            synced_review_ids.push(review_id);
            continue;
        }

        // Fetch existing card from PostgreSQL or in-memory map
        let mut existing_card = None;
        if let Some(ref mut tx) = transaction {
            let row = sqlx::query_as::<_, DbFsrsCard>(
                "SELECT item_id, state, stability, difficulty, reps, lapses, last_review, next_review, updated_at FROM fsrs_cards WHERE item_id = $1",
            )
            .bind(&rev.item_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(|e| {
                tracing::warn!("DB error in fetch_card_by_id: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;

            if let Some(db_card) = row {
                existing_card = Some(FSRSCard::from(db_card));
            }
        }

        let mut cards = state.cards.write().await;
        let card = match existing_card {
            Some(c) => c,
            None => cards
                .get(&rev.item_id)
                .cloned()
                .unwrap_or_else(|| FSRSCard::new(rev.item_id.clone())),
        };

        // Last-Write-Wins (LWW):
        // Only advance card state if review_time > card.last_review, or if it's an initial unreviewed card (reps == 0)
        let is_newer = card.reps == 0 || review_time > card.last_review;

        let resulting_card = if is_newer {
            let updated = state.fsrs.review(&card, rating, review_time);

            if let Some(ref mut tx) = transaction {
                // Ensure lesson row exists for FK integrity
                let hints = sqlx::types::Json(Vec::<String>::new());
                sqlx::query(
                    r#"
                    INSERT INTO lessons (
                        id, language, category, target_text, phonetic_or_kana,
                        meaning_vi, workplace_context, workplace_context_vi,
                        stroke_order_hints, difficulty_level, created_at
                    ) VALUES ($1, 'custom', 'custom', $1, '', 'Custom card', '', '', $2, 1, clock_timestamp())
                    ON CONFLICT (id) DO NOTHING
                    "#,
                )
                .bind(&updated.item_id)
                .bind(hints)
                .execute(&mut **tx)
                .await
                .map_err(|e| {
                    tracing::warn!("Failed to ensure sync lesson: {}", e);
                    StatusCode::INTERNAL_SERVER_ERROR
                })?;

                let state_i16 = updated.state as i16;
                sqlx::query(
                    r#"
                    INSERT INTO fsrs_cards (
                        item_id, state, stability, difficulty, reps, lapses,
                        last_review, next_review, updated_at
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, clock_timestamp())
                    ON CONFLICT (item_id) DO UPDATE SET
                        state = EXCLUDED.state,
                        stability = EXCLUDED.stability,
                        difficulty = EXCLUDED.difficulty,
                        reps = EXCLUDED.reps,
                        lapses = EXCLUDED.lapses,
                        last_review = EXCLUDED.last_review,
                        next_review = EXCLUDED.next_review,
                        updated_at = clock_timestamp()
                    "#,
                )
                .bind(&updated.item_id)
                .bind(state_i16)
                .bind(updated.stability)
                .bind(updated.difficulty)
                .bind(updated.reps as i32)
                .bind(updated.lapses as i32)
                .bind(updated.last_review)
                .bind(updated.next_review)
                .execute(&mut **tx)
                .await
                .map_err(|e| {
                    tracing::warn!("Failed to persist FSRS card in DB during sync: {}", e);
                    StatusCode::INTERNAL_SERVER_ERROR
                })?;
            }

            updated
        } else {
            // Out-of-order review: do not overwrite newer card state
            card
        };

        // Record review log into DB for audit trail (idempotent ON CONFLICT)
        if let Some(ref mut tx) = transaction {
            let elapsed = rev.elapsed_days.unwrap_or(0.0);
            let sched = rev.scheduled_days.unwrap_or_else(|| {
                ((resulting_card.next_review - review_time).num_seconds() as f64 / 86400.0).round()
                    as i32
            });

            sqlx::query(
                r#"
                INSERT INTO review_logs (
                    id, item_id, client_id, rating, state, review_time,
                    elapsed_days, scheduled_days, server_received_at
                ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, clock_timestamp())
                ON CONFLICT (id) DO NOTHING
                "#,
            )
            .bind(&review_id)
            .bind(&rev.item_id)
            .bind(&client_id)
            .bind(rev.rating as i16)
            .bind(resulting_card.state as i16)
            .bind(review_time)
            .bind(elapsed)
            .bind(sched)
            .execute(&mut **tx)
            .await
            .map_err(|e| {
                tracing::warn!("Failed to persist sync review log: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;
        }

        if let Some(tx) = transaction {
            tx.commit().await.map_err(|e| {
                tracing::warn!("Failed to commit sync review: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;
        }
        if is_newer {
            cards.insert(rev.item_id.clone(), resulting_card.clone());
            state
                .card_updated_at
                .write()
                .await
                .insert(rev.item_id.clone(), Utc::now());
        }

        synced_review_ids.push(review_id);
        if state.pool.is_none() {
            seen_review_ids.insert(
                synced_review_ids.last().unwrap().clone(),
                rev.item_id.clone(),
            );
        }
        updated_cards_map.insert(
            resulting_card.item_id.clone(),
            FsrsCardDto::from_card(&resulting_card, Some(now)),
        );
    }

    // 2. Process Completed Lessons
    let mut synced_completed_lesson_ids = Vec::new();
    if let Some(completed_lessons) = req.completed_lessons {
        for comp in completed_lessons {
            if let Some(ref pool) = state.pool {
                let score = comp.score.unwrap_or(1.0);
                sqlx::query(
                    r#"
                    INSERT INTO completed_lessons (lesson_id, client_id, completed_at, score)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (lesson_id, client_id) DO UPDATE SET
                        completed_at = EXCLUDED.completed_at,
                        score = EXCLUDED.score
                    WHERE completed_lessons.completed_at < EXCLUDED.completed_at
                    "#,
                )
                .bind(&comp.lesson_id)
                .bind(&client_id)
                .bind(comp.completed_at)
                .bind(score)
                .execute(pool)
                .await
                .map_err(|e| {
                    tracing::warn!("Failed to persist completed lesson: {}", e);
                    StatusCode::INTERNAL_SERVER_ERROR
                })?;
            }
            synced_completed_lesson_ids.push(comp.lesson_id);
        }
    }

    let synced_reviews = synced_review_ids.len();
    let synced_lessons = synced_completed_lesson_ids.len();
    let updated_cards: Vec<FsrsCardDto> = updated_cards_map.into_values().collect();

    Ok(Json(SyncPushResponse {
        synced_reviews,
        synced_lessons,
        synced_review_ids,
        synced_completed_lesson_ids,
        updated_cards,
        timestamp: now,
        server_time: now,
    }))
}

/// GET /api/v1/sync/pull?since=ISO-8601
/// Pulls updated cards and curriculum lessons updated since the high-water-mark timestamp.
pub async fn pull_sync(
    State(state): State<AppState>,
    Query(query): Query<SyncPullQuery>,
) -> Result<Json<SyncPullResponse>, StatusCode> {
    let mut now = Utc::now();
    let since = query.since.or(query.last_sync_time);

    let mut cards_dto: Vec<FsrsCardDto> = Vec::new();
    let mut lessons: Vec<LessonItem> = Vec::new();

    if let Some(ref pool) = state.pool {
        let mut tx = pool
            .begin()
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        sqlx::query("SELECT pg_advisory_xact_lock(0, 1)")
            .execute(&mut *tx)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        now = sqlx::query_scalar::<_, chrono::DateTime<Utc>>("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        // Query cards from DB
        let db_cards_res = match since {
            Some(t) => {
                sqlx::query_as::<_, DbFsrsCard>(
                    "SELECT item_id, state, stability, difficulty, reps, lapses, last_review, next_review, updated_at FROM fsrs_cards WHERE updated_at >= $1 ORDER BY updated_at ASC",
                )
                .bind(t)
                .fetch_all(&mut *tx)
                .await
            }
            None => {
                sqlx::query_as::<_, DbFsrsCard>(
                    "SELECT item_id, state, stability, difficulty, reps, lapses, last_review, next_review, updated_at FROM fsrs_cards ORDER BY updated_at ASC",
                )
                .fetch_all(&mut *tx)
                .await
            }
        };

        let db_cards = db_cards_res.map_err(|e| {
            tracing::warn!("Failed to pull cards: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
        for c in db_cards {
            let updated_at = c.updated_at;
            let card = FSRSCard::from(c);
            cards_dto.push(FsrsCardDto::from_card(&card, Some(updated_at)));
        }

        // Query lessons from DB
        let db_lessons_res = match since {
            Some(t) => {
                sqlx::query_as::<_, DbLessonItem>(
                    "SELECT id, language, category, target_text, phonetic_or_kana, meaning_vi, workplace_context, workplace_context_vi, stroke_order_hints, difficulty_level, created_at FROM lessons WHERE created_at >= $1 ORDER BY id ASC",
                )
                .bind(t)
                .fetch_all(&mut *tx)
                .await
            }
            None => {
                sqlx::query_as::<_, DbLessonItem>(
                    "SELECT id, language, category, target_text, phonetic_or_kana, meaning_vi, workplace_context, workplace_context_vi, stroke_order_hints, difficulty_level, created_at FROM lessons ORDER BY id ASC",
                )
                .fetch_all(&mut *tx)
                .await
            }
        };

        let db_lessons = db_lessons_res.map_err(|e| {
            tracing::warn!("Failed to pull lessons: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
        lessons = db_lessons.into_iter().map(LessonItem::from).collect();
        tx.commit()
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    } else {
        // In-memory fallback
        let mem_cards = state.cards.read().await;
        let updated_at = state.card_updated_at.read().await;
        for card in mem_cards.values() {
            let receipt_time = updated_at
                .get(&card.item_id)
                .copied()
                .unwrap_or(card.last_review);
            if let Some(since_time) = since {
                if receipt_time >= since_time {
                    cards_dto.push(FsrsCardDto::from_card(card, Some(receipt_time)));
                }
            } else {
                cards_dto.push(FsrsCardDto::from_card(card, Some(receipt_time)));
            }
        }

        if since.is_none() {
            lessons = state.lessons.clone();
        }
    }

    Ok(Json(SyncPullResponse {
        cards: cards_dto.clone(),
        updated_cards: cards_dto,
        lessons: lessons.clone(),
        new_lessons: lessons,
        server_time: now,
        timestamp: now,
    }))
}
